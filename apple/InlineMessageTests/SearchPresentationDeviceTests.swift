import Auth
import InlineConfig
import InlineKit
import Observation
import RealtimeV2
import SwiftUI
import Testing
import UIKit
@testable import InlineIOS

@Suite("Search tab presentation", .serialized)
@MainActor
struct SearchPresentationDeviceTests {
  @Test("Query edits and root badge updates keep the selected tab and keyboard stable")
  func keyboardDoesNotCycle() async throws {
    let fixture = try await Fixture()
    defer { fixture.close() }
    let field = try await fixture.searchField()
    let tab = try #require(fixture.tabController()?.selectedViewController)
    #expect(field.becomeFirstResponder())
    try await Task.sleep(for: .seconds(2))
    try fixture.requireForeground()
    #expect(field.isFirstResponder)
    #expect(fixture.tabController()?.selectedViewController === tab)
    #expect(try await fixture.searchField() === field)
    #expect(fixture.state.keyboardShows == 1)
    #expect(fixture.state.keyboardHides == 0)

    // Home badges can still invalidate the root during catch-up. They must not
    // replace the editing search controller or start another keyboard session.
    for revision in 0 ..< 10 {
      field.text = "search \(revision)"
      field.sendActions(for: .editingChanged)
      fixture.state.refreshRevision += 1
      try await Task.sleep(for: .milliseconds(100))
      try fixture.requireForeground()
      #expect(fixture.state.presentation.query == "search \(revision)")
    }
    #expect(field.isFirstResponder)
    #expect(fixture.tabController()?.selectedViewController === tab)
    #expect(fixture.state.keyboardShows == 1)
    #expect(fixture.state.keyboardHides == 0)

    #expect(field.resignFirstResponder())
    try await Task.sleep(for: .milliseconds(500))
    #expect(!field.isFirstResponder)
    #expect(field.becomeFirstResponder())
    try await Task.sleep(for: .seconds(1))
    try fixture.requireForeground()
    #expect(field.isFirstResponder)
    #expect(fixture.state.keyboardShows == 2)
    #expect(fixture.state.keyboardHides == 1)
  }

  @Test("An existing focus request is applied on first presentation")
  func initialFocusRequest() async throws {
    let fixture = try await Fixture(focusRequested: true)
    defer { fixture.close() }
    let field = try await fixture.searchField()
    try await Task.sleep(for: .seconds(1))
    try fixture.requireForeground()
    #expect(field.isFirstResponder)
    #expect(fixture.state.keyboardShows == 1)
    #expect(fixture.state.presentation.isFieldFocused)

    fixture.state.presentation.focusRequested = false
    try await Task.sleep(for: .milliseconds(500))
    #expect(!field.isFirstResponder)
    #expect(!fixture.state.presentation.isFieldFocused)

    fixture.state.presentation.focusRequested = true
    try await Task.sleep(for: .seconds(1))
    try fixture.requireForeground()
    #expect(field.isFirstResponder)
    #expect(try await fixture.searchField() === field)
  }

  @Observable
  @MainActor
  final class ProbeState {
    let presentation = ExperimentalSearchPresentation()
    var keyboardShows = 0
    var keyboardHides = 0
    var refreshRevision = 0
  }

  private enum TabID: Hashable { case home, open, search, newThread }

  // Reproduce the production NavigationStack -> TabView placement and its
  // keyboard-driven chrome changes, rather than focusing an isolated field.
  private struct Harness: View {
    let state: ProbeState
    let database: AppDatabase
    let router: Router
    let dataManager: DataManager
    @State private var selectedTab: TabID = .search

    init(state: ProbeState, database: AppDatabase) {
      self.state = state
      self.database = database
      router = Router(initialTab: .search, persistence: .externallyManaged, restoresPersistedState: false)
      dataManager = DataManager(database: database)
    }

    var body: some View {
      NavigationStack {
        TabView(selection: Binding(
          get: { selectedTab },
          set: { tab in
            guard tab != selectedTab else { return }
            selectedTab = tab
            if tab == .search { state.presentation.focusRequested = false }
          }
        )) {
          Tab("All Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .home) { Color.clear }
          Tab("Open", systemImage: "tray", value: .open) { Color.clear }
            .badge(state.refreshRevision)
          Tab("Search", systemImage: "magnifyingglass", value: .search) {
            ExperimentalSearchTab(
              presentation: state.presentation,
              activeSpaceId: nil,
              onFocusChanged: { state.presentation.isFieldFocused = $0 },
              onClose: { state.presentation.focusRequested = false },
              onOpenResult: { _, _ in }
            )
          }
          if #available(iOS 27.0, *) {
            Tab("New Thread", systemImage: "plus", value: .newThread, role: .prominent) { Color.clear }
          }
        }
        .navigationTitle("")
        .modifier(ExperimentalSearchRootChrome(presentation: state.presentation, onOpenGrid: {}))
      }
      .environment(\.appDatabase, database)
      .environment(router)
      .environmentObject(dataManager)
      .environmentObject(ThemeManager.shared)
      .environmentObject(INUserSettings.current.notification)
      .environmentObject(Api.realtime.stateObject)
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
        state.presentation.isKeyboardVisible = true
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
        state.keyboardShows += 1
      }
      .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
        state.presentation.isKeyboardVisible = false
        state.keyboardHides += 1
      }
    }
  }

  @MainActor
  private final class Fixture {
    let state = ProbeState()
    let window: UIWindow
    let previousKeyWindow: UIWindow?
    let previousIdleTimerDisabled: Bool

    init(focusRequested: Bool = false) async throws {
      try #require(TestProcess.isRunning)
      try #require(!Auth.shared.getIsLoggedIn() && Auth.shared.getCurrentUserId() == nil)
      try #require(!AppDatabase.shared.isPersistent)
      let scene = try await Self.activeScene()
      previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
      previousKeyWindow?.endEditing(true)
      try await Task.sleep(for: .milliseconds(500))
      state.presentation.focusRequested = focusRequested
      window = UIWindow(windowScene: scene)
      previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      var ready = false
      defer { if !ready { close() } }
      window.rootViewController = UIHostingController(rootView: Harness(state: state, database: .empty()))
      window.makeKeyAndVisible()
      // The native field can exist before SwiftUI's initial presentation callbacks
      // and UIApplication's scene activation have finished. A user can only
      // edit after that first presentation has settled.
      try await Task.sleep(for: .milliseconds(250))
      try #require(window.isKeyWindow)
      try #require(scene.activationState == .foregroundActive)
      print("Search fixture ready: app=\(UIApplication.shared.applicationState.rawValue) scene=\(scene.activationState.rawValue) key=\(window.isKeyWindow) viewport=\(window.bounds.size)")
      ready = true
    }

    private static func activeScene() async throws -> UIWindowScene {
      for _ in 0 ..< 100 {
        if UIApplication.shared.applicationState == .active,
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
           .first(where: { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) })
        {
          return scene
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      return try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive }), "The test host needs an active foreground scene")
    }

    func searchField() async throws -> UITextField {
      for _ in 0 ..< 40 {
        window.layoutIfNeeded()
        if let field = descendants(window).compactMap({ $0 as? UITextField }).first { return field }
        try await Task.sleep(for: .milliseconds(50))
      }
      return try #require(descendants(window).compactMap { $0 as? UITextField }.first)
    }

    func tabController() -> UITabBarController? {
      func visit(_ controller: UIViewController) -> UITabBarController? {
        if let tab = controller as? UITabBarController { return tab }
        return controller.children.lazy.compactMap(visit).first
      }
      return window.rootViewController.flatMap(visit)
    }

    func requireForeground() throws {
      try #require(UIApplication.shared.applicationState == .active)
      try #require(window.windowScene?.activationState == .foregroundActive)
      try #require(window.isKeyWindow)
    }

    func close() {
      window.endEditing(true)
      window.isHidden = true
      window.rootViewController = nil
      previousKeyWindow?.makeKey()
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }

    private func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
  }
}
