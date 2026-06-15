import AppKit
import Combine
import InlineKit
import Logger
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
  private static let defaultContentSize = MainWindowSceneOptions.defaultContentSize
  static let minSizeWithSidebar = MainWindowSceneOptions.minSizeWithSidebar
  static let minSizeWithoutSidebar = MainWindowSceneOptions.minSizeWithoutSidebar
  private static var controllers: [MainWindowController] = []

  static var all: [MainWindowController] {
    pruneControllers()
    return controllers
  }

  let sceneId: String

  private let dependencies: AppDependencies
  private let appBridge: AppBridge
  private let nav3: Nav3
  private let keyMonitor: KeyMonitor
  private let appliesDefaultFrame: Bool
  private let windowID: UUID
  private let log = Log.scoped("MainWindowController")
  private var rootEscapeUnsubscribe: (() -> Void)?
  private var toolbarStyleCancellable: AnyCancellable?

  @discardableResult
  static func showDefault(dependencies: AppDependencies) -> MainWindowController {
    if let controller = firstVisible {
      controller.showWindow(nil)
      return controller
    }

    return newWindow(
      dependencies: dependencies,
      sceneId: MainWindowSceneStateStore.defaultSceneId
    )
  }

  @discardableResult
  static func newWindow(
    dependencies: AppDependencies,
    sceneId: String = MainWindowSceneStateStore.makeSceneId(),
    destination: MainWindowDestination? = nil,
    sender: Any? = nil
  ) -> MainWindowController {
    let controller = make(
      dependencies: dependencies,
      sceneId: sceneId,
      destination: destination
    )
    controller.showAsStandaloneWindow(sender)
    return controller
  }

  @discardableResult
  static func newTab(
    dependencies: AppDependencies,
    destination: MainWindowDestination? = nil,
    sender: Any? = nil
  ) -> MainWindowController {
    guard let parent = preferredParentWindow else {
      return newWindow(dependencies: dependencies, destination: destination, sender: sender)
    }

    let controller = make(dependencies: dependencies, destination: destination)
    guard let window = controller.window else { return controller }

    if parent.isMiniaturized {
      parent.deminiaturize(sender)
    }

    if let tabGroup = parent.tabGroup,
       tabGroup.windows.contains(window)
    {
      tabGroup.removeWindow(window)
    }

    window.tabbingMode = .preferred
    parent.addTabbedWindow(window, ordered: .above)

    DispatchQueue.main.async { [weak controller, weak window] in
      controller?.showWindow(sender)
      window?.makeKeyAndOrderFront(sender)
      dependencies.appBridge.activate(ignoringOtherApps: true)
    }

    return controller
  }

  @discardableResult
  static func restore(
    dependencies: AppDependencies,
    state: MainWindowRestorationState
  ) -> MainWindowController {
    make(
      dependencies: dependencies,
      sceneId: state.sceneId,
      routeState: state.routeState,
      appliesDefaultFrame: false
    )
  }

  static func resetAllNavigation() {
    all.forEach { $0.resetNavigation() }
  }

  static func closeAll() {
    let controllers = all
    controllers.forEach { $0.close() }
    self.controllers.removeAll()
  }

  private static var firstVisible: MainWindowController? {
    all.first { controller in
      controller.window?.isVisible == true && controller.window?.isMiniaturized == false
    } ?? all.first
  }

  private static var preferredParentWindow: NSWindow? {
    if let keyWindow = NSApp.keyWindow,
       keyWindow.windowController is MainWindowController
    {
      return keyWindow
    }

    if let main = all.first(where: { $0.window?.isMainWindow == true })?.window {
      return main
    }

    return all.last?.window
  }

  private static func make(
    dependencies: AppDependencies,
    sceneId: String = MainWindowSceneStateStore.makeSceneId(),
    destination: MainWindowDestination? = nil,
    routeState: String = "",
    appliesDefaultFrame: Bool = true
  ) -> MainWindowController {
    pruneControllers()

    if let controller = controllers.first(where: { $0.sceneId == sceneId }) {
      if let destination {
        controller.route(destination)
      }
      return controller
    }

    let controller = MainWindowController(
      dependencies: dependencies,
      sceneId: sceneId,
      destination: destination,
      routeState: routeState,
      appliesDefaultFrame: appliesDefaultFrame
    )
    controllers.append(controller)
    return controller
  }

  private static func pruneControllers() {
    controllers.removeAll { $0.window == nil }
  }

  init(
    dependencies: AppDependencies,
    sceneId: String,
    destination: MainWindowDestination? = nil,
    routeState: String = "",
    appliesDefaultFrame: Bool = true
  ) {
    let windowID = UUID()
    self.windowID = windowID
    self.dependencies = dependencies
    appBridge = dependencies.appBridge.bound(to: windowID)
    self.sceneId = sceneId
    self.appliesDefaultFrame = appliesDefaultFrame

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
      styleMask: [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
      ],
      backing: .buffered,
      defer: false
    )

    keyMonitor = KeyMonitor(window: window)
    nav3 = Nav3(routeState: routeState, pendingRoute: destination?.route)

    super.init(window: window)

    appBridge.registerWindow(window)
    installRootEscapeHandler()
    nav3.onRouteChange = { [weak self, weak window] in
      self?.applyWindowAppearance()
      window?.invalidateRestorableState()
    }
    configureWindow(window)
    bindToolbarStyle(window)
    installContent()
    applyWindowAppearance()
    TimezoneManager.shared.mainWindowDidOpen()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    appBridge.activate(ignoringOtherApps: true)
  }

  override func newWindowForTab(_ sender: Any?) {
    let destination = MainWindowOpenCoordinator.shared.consumePendingDestination()
    Self.newTab(dependencies: dependencies, destination: destination, sender: sender)
  }

  func route(_ destination: MainWindowDestination) {
    nav3.open(destination.route)
    showWindow(nil)
  }

  func resetNavigation() {
    nav3.reset()
    window?.invalidateRestorableState()
  }

  func windowWillClose(_ notification: Notification) {
    removeRootEscapeHandler()
    toolbarStyleCancellable?.cancel()
    toolbarStyleCancellable = nil
    keyMonitor.attach(window: nil)
    appBridge.unregisterWindow()
    Self.controllers.removeAll { $0 === self }
  }

  func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    MainWindowRestorationState(sceneId: sceneId, routeState: nav3.encodedRouteState() ?? "")
      .encode(with: state)
  }

  private func configureWindow(_ window: NSWindow) {
    window.title = "Inline"
    window.titleVisibility = .hidden
    window.toolbarStyle = AppSettings.shared.toolbarStyle.nsToolbarStyle
    window.tabbingMode = .preferred
    window.minSize = Self.minSizeWithSidebar
    DispatchQueue.main.async { [weak window] in
      guard window?.tabbingMode == .preferred else { return }
      window?.tabbingMode = .automatic
    }
    window.isRestorable = true
    window.restorationClass = MainWindowRestoration.self
    window.identifier = NSUserInterfaceItemIdentifier(MainWindowRestoration.identifier)
    window.delegate = self
  }

  private func bindToolbarStyle(_ window: NSWindow) {
    toolbarStyleCancellable = AppSettings.shared.$toolbarStyle
      .receive(on: DispatchQueue.main)
      .sink { [weak window] style in
        window?.toolbarStyle = style.nsToolbarStyle
      }
  }

  private func showAsStandaloneWindow(_ sender: Any?) {
    let previousTabbingMode = window?.tabbingMode ?? .preferred
    window?.tabbingMode = .disallowed
    showWindow(sender)
    DispatchQueue.main.async { [weak window] in
      guard window?.tabbingMode == .disallowed else { return }
      window?.tabbingMode = previousTabbingMode == .disallowed ? .automatic : previousTabbingMode
    }
  }

  private func applyWindowAppearance() {
    let appearance = nav3.currentRoute.routeWindowAppearance
    appBridge.applyWindowBackground(appearance.windowBackground)
    appBridge.setWindowTitlebarAppearsTransparent(appearance.titlebarAppearsTransparent)
  }

  private func installRootEscapeHandler() {
    guard rootEscapeUnsubscribe == nil else { return }

    rootEscapeUnsubscribe = keyMonitor.addHandler(for: .escape, key: "swiftui_root_escape_\(windowID)") { [weak self] _ in
      guard let self else { return }
      guard dependencies.viewModel.topLevelRoute == .main else { return }
      guard nav3.currentRoute != .empty else { return }
      guard nav3.goBackToAllChatsOriginIfNeeded() == false else { return }
      nav3.open(.empty)
    }
  }

  private func removeRootEscapeHandler() {
    rootEscapeUnsubscribe?()
    rootEscapeUnsubscribe = nil
  }

  private func installContent() {
    let root = MainWindowRootView(
      nav3: nav3,
      initialTopLevelRoute: dependencies.viewModel.topLevelRoute,
      keyMonitor: keyMonitor,
      windowID: windowID
    )
    .attachWindowKeyMonitor(keyMonitor)
    .environment(dependencies: dependencies.with(appBridge: appBridge))

    let hostingController = NSHostingController(rootView: root)
    hostingController.sizingOptions = []
    window?.contentViewController = hostingController
    if appliesDefaultFrame {
      window?.setContentSize(Self.defaultContentSize)
      window?.center()
    }
    log.debug("Configured SwiftUI main window sceneId=\(sceneId)")
  }
}

private enum MainWindowSceneOptions {
  static let defaultContentSize = NSSize(width: 860, height: 640)
  static let minSizeWithSidebar = NSSize(width: 600, height: 400)
  static let minSizeWithoutSidebar = NSSize(width: 300, height: 300)
}
