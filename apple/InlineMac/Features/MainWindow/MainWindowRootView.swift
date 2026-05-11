import AppKit
import Combine
import InlineKit
import SwiftUI

/// Main app window
struct MainWindowRootView: View {
  @Environment(\.dependencies) private var dependencies
  @EnvironmentObject private var viewModel: MainWindowViewModel

  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var chatOpenPreloader = Nav3ChatOpenPreloadBridge()
  @State private var forwardMessages = ForwardMessagesPresenter()
  @State private var overlay = OverlayManager()
  @State private var sidebarViewModel: SidebarViewModel
  @State private var nativeTab = NativeWindowTabModel()
  @State private var nativeTabShortcutUnsubscribe: (() -> Void)?
  @State private var topLevelRoute: TopLevelRoute = .loading
  private let nav3: Nav3
  private let keyMonitor: KeyMonitor
  private let windowID: UUID

  private var windowDependencies: AppDependencies? {
    guard var dependencies else { return nil }
    dependencies.nav3 = nav3
    dependencies.nav3ChatOpenPreloader = chatOpenPreloader
    dependencies.forwardMessages = forwardMessages
    dependencies.keyMonitor = keyMonitor
    dependencies.overlay = overlay
    return dependencies
  }

  init(
    nav3: Nav3,
    initialTopLevelRoute: TopLevelRoute = .loading,
    keyMonitor: KeyMonitor,
    windowID: UUID = UUID()
  ) {
    self.nav3 = nav3
    self.keyMonitor = keyMonitor
    self.windowID = windowID
    _sidebarViewModel = State(initialValue: SidebarViewModel(
      db: AppDatabase.shared,
      startsObserving: initialTopLevelRoute == .main,
      selectedSpaceId: nav3.selectedSpaceId
    ))
    _topLevelRoute = State(initialValue: initialTopLevelRoute)
  }

  var body: some View {
    topLevelContent
    .environment(dependencies: windowDependencies)
    .environment(\.nav, nav3)
    .environment(\.mainWindowID, windowID)
    .environment(sidebarViewModel)
    .registerMainWindow(id: windowID, toastPresenter: overlay) { destination in
      nav3.open(destination.route)
    } openCommandBar: {
      nav3.openCommandBar()
    } toggleSidebar: {
      toggleSidebar()
    }
    .nativeWindowTab(title: nativeTab.title, icon: nativeTab.iconPeer)
    .onAppear {
      nativeTab.update(peer: nav3.currentRoute.selectedPeer)
      installNativeTabShortcuts()
      syncTopLevelRoute(viewModel.topLevelRoute)
    }
    .onReceive(viewModel.$topLevelRoute) { route in
      syncTopLevelRoute(route)
    }
    .onChange(of: nav3.currentRoute) { _, _ in
      guard showsMain else { return }
      nativeTab.update(peer: nav3.currentRoute.selectedPeer)
    }
    .onDisappear {
      chatOpenPreloader.cancelPendingOpen()
      nativeTab.update(peer: nil)
      removeNativeTabShortcuts()
      MainWindowOpenCoordinator.shared.unregisterWindow(id: windowID)
    }
  }

  private func installNativeTabShortcuts() {
    guard nativeTabShortcutUnsubscribe == nil else { return }

    nativeTabShortcutUnsubscribe = keyMonitor.addCommandNumberHandler(key: "native_window_tabs_\(windowID)") { event in
      guard let char = event.charactersIgnoringModifiers?.first,
            let position = Int(String(char)),
            (1 ... 9).contains(position)
      else { return false }

      return MainWindowOpenCoordinator.shared.selectTab(at: position)
    }
  }

  private func removeNativeTabShortcuts() {
    nativeTabShortcutUnsubscribe?()
    nativeTabShortcutUnsubscribe = nil
  }

  private var showsMain: Bool {
    topLevelRoute == .main
  }

  @ViewBuilder private var topLevelContent: some View {
    switch topLevelRoute {
    case .loading:
      MainWindowLoadingView()

    case .onboarding:
      Onboarding(usesWindowContainerBackground: true)

    case .main:
      MainWindowRoot(
        columnVisibility: $columnVisibility,
        nav3: nav3,
        dependencies: windowDependencies,
        toggleSidebar: toggleSidebar
      )
    }
  }

  private func syncTopLevelRoute(_ route: TopLevelRoute) {
    if route == .main {
      sidebarViewModel.start(selectedSpaceId: nav3.selectedSpaceId)
      if let dependencies {
        dependencies.session.fetchInitialDataIfNeeded(dependencies: dependencies)
      }
    }

    guard topLevelRoute != route else { return }

    topLevelRoute = route
    if route == .onboarding {
      chatOpenPreloader.cancelPendingOpen()
      nav3.reset()
    }
  }

  private func toggleSidebar() {
    switch columnVisibility {
      case .detailOnly:
        columnVisibility = .all
      default:
        columnVisibility = .detailOnly
    }
  }
}

@MainActor
@Observable
private final class NativeWindowTabModel {
  var title: String?
  var iconPeer: ChatIcon.PeerType?

  @ObservationIgnored private var peer: Peer?
  @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

  func update(peer: Peer?) {
    guard self.peer != peer else { return }

    self.peer = peer
    cancellables.removeAll()
    title = "Inline"
    iconPeer = nil

    guard let peer else { return }

    switch peer {
    case let .user(id):
      ObjectCache.shared.getUserPublisher(id: id)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.sync()
        }
        .store(in: &cancellables)

    case let .thread(id):
      ObjectCache.shared.getChatPublisher(id: id)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.sync()
        }
        .store(in: &cancellables)
    }

    sync()
  }

  private func sync() {
    switch peer {
    case let .user(id):
      guard let userInfo = ObjectCache.shared.getUser(id: id) else {
        title = "Direct Message"
        iconPeer = nil
        return
      }

      if userInfo.user.isCurrentUser() {
        title = "Saved Messages"
        iconPeer = .savedMessage(userInfo.user)
      } else {
        title = userInfo.user.displayName
        iconPeer = .user(userInfo)
      }

    case let .thread(id):
      guard let chat = ObjectCache.shared.getChat(id: id) else {
        title = "Chat"
        iconPeer = nil
        return
      }

      title = chat.humanReadableTitle ?? "Untitled"
      iconPeer = .chat(chat)

    case .none:
      title = nil
      iconPeer = nil
    }
  }
}

private struct MainWindowLoadingView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }
}

private struct MainWindowRoot: View {
  @Binding var columnVisibility: NavigationSplitViewVisibility

  let nav3: Nav3
  let dependencies: AppDependencies?
  let toggleSidebar: () -> Void

  var body: some View {
    ZStack(alignment: .top) {
      NavigationSplitView(columnVisibility: $columnVisibility) {
        SidebarView(
          isCollapsed: isSidebarCollapsed
        )
        .navigationSplitViewColumnWidth(
          min: Theme.minimumSidebarWidth,
          ideal: Theme.idealSidebarWidth,
          max: 340
        )
      } detail: {
        MainContentView()
      }
      .toolbar {
        MainWindowToolbar(nav: nav3)
      }

      CommandBar()
    }
    .toastOverlayHost(dependencies?.overlay)
    .modifier(ForwardMessagesPresentation(dependencies: dependencies))
  }

  private var isSidebarCollapsed: Bool {
    if case .detailOnly = columnVisibility {
      return true
    }
    return false
  }
}

/// Per window environments
extension EnvironmentValues {
  @Entry var nav = Nav3.default
  @Entry var mainWindowID: UUID?
}

#Preview {
  MainWindowRootView(nav3: Nav3(), keyMonitor: KeyMonitor())
    .environment(dependencies: AppDependencies())
}
