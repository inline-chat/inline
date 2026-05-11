import AppKit
import InlineKit
import Logger
import SwiftUI

@MainActor
final class MainWindowSwiftUIWindowController: NSWindowController, NSWindowDelegate {
  private static let defaultContentSize = MainWindowSceneOptions.defaultContentSize
  private static var controllers: [MainWindowSwiftUIWindowController] = []

  static var all: [MainWindowSwiftUIWindowController] {
    pruneControllers()
    return controllers
  }

  let sceneId: String

  private let dependencies: AppDependencies
  private let nav3: Nav3
  private let keyMonitor: KeyMonitor
  private let appliesDefaultFrame: Bool
  private let windowID = UUID()
  private let log = Log.scoped("MainWindowSwiftUIWindowController")
  private var rootEscapeUnsubscribe: (() -> Void)?

  @discardableResult
  static func showDefault(dependencies: AppDependencies) -> MainWindowSwiftUIWindowController {
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
  ) -> MainWindowSwiftUIWindowController {
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
  ) -> MainWindowSwiftUIWindowController {
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
      NSApp.activate(ignoringOtherApps: true)
    }

    return controller
  }

  @discardableResult
  static func restore(
    dependencies: AppDependencies,
    state: MainWindowRestorationState
  ) -> MainWindowSwiftUIWindowController {
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

  private static var firstVisible: MainWindowSwiftUIWindowController? {
    all.first { controller in
      controller.window?.isVisible == true && controller.window?.isMiniaturized == false
    } ?? all.first
  }

  private static var preferredParentWindow: NSWindow? {
    if let keyWindow = NSApp.keyWindow,
       keyWindow.windowController is MainWindowSwiftUIWindowController
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
  ) -> MainWindowSwiftUIWindowController {
    pruneControllers()

    if let controller = controllers.first(where: { $0.sceneId == sceneId }) {
      if let destination {
        controller.route(destination)
      }
      return controller
    }

    let controller = MainWindowSwiftUIWindowController(
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
    self.dependencies = dependencies
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

    installRootEscapeHandler()
    nav3.onRouteChange = { [weak self, weak window] in
      self?.applyWindowAppearance()
      window?.invalidateRestorableState()
    }
    configureWindow(window)
    installContent()
    applyWindowAppearance()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    NSApp.activate(ignoringOtherApps: true)
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
    keyMonitor.attach(window: nil)
    Self.controllers.removeAll { $0 === self }
  }

  func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
    MainWindowRestorationState(sceneId: sceneId, routeState: nav3.encodedRouteState() ?? "")
      .encode(with: state)
  }

  private func configureWindow(_ window: NSWindow) {
    window.title = "Inline"
    window.titleVisibility = .hidden
    window.toolbarStyle = .unified
    window.tabbingMode = .preferred
    DispatchQueue.main.async { [weak window] in
      guard window?.tabbingMode == .preferred else { return }
      window?.tabbingMode = .automatic
    }
    window.isRestorable = true
    window.restorationClass = MainWindowRestoration.self
    window.identifier = NSUserInterfaceItemIdentifier(MainWindowRestoration.identifier)
    window.delegate = self
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
    guard let window else { return }

    if nav3.currentRoute == .empty {
      window.titlebarAppearsTransparent = true
      window.backgroundColor = .clear
      window.isOpaque = false
      return
    }

    window.titlebarAppearsTransparent = false
    window.backgroundColor = Theme.windowContentBackgroundColor
    window.isOpaque = true
  }

  private func installRootEscapeHandler() {
    guard rootEscapeUnsubscribe == nil else { return }

    rootEscapeUnsubscribe = keyMonitor.addHandler(for: .escape, key: "swiftui_root_escape_\(windowID)") { [weak self] _ in
      guard let self else { return }
      guard dependencies.viewModel.topLevelRoute == .main else { return }
      guard nav3.currentRoute != .empty else { return }
      nav3.open(.empty)
    }
  }

  private func removeRootEscapeHandler() {
    rootEscapeUnsubscribe?()
    rootEscapeUnsubscribe = nil
  }

  private func installContent() {
    let root = MainWindowSwiftUI(
      nav3: nav3,
      initialTopLevelRoute: dependencies.viewModel.topLevelRoute,
      keyMonitor: keyMonitor,
      windowID: windowID
    )
    .environment(dependencies: dependencies)
    .attachWindowKeyMonitor(keyMonitor)

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
}
