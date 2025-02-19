import AppKit
import Combine
import InlineKit
import SwiftUI

class MainWindowController: NSWindowController {
  private var dependencies: AppDependencies

  private var topLevelRoute: TopLevelRoute {
    dependencies.viewModel.topLevelRoute
  }

  private var currentToolbarItems: [NSToolbarItem.Identifier] = []

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: CGSize(width: 900, height: 600)),
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

    super.init(window: window)

    injectDependencies()
    configureWindow()
    subscribe()
  }

  private lazy var toolbar: NSToolbar = {
    let toolbar = NSToolbar(identifier: "MainToolbar")
    toolbar.delegate = self
    toolbar.allowsUserCustomization = true
    toolbar.autosavesConfiguration = true
    toolbar.displayMode = .iconOnly
    return toolbar
  }()

  private func configureWindow() {
    window?.title = "Inline"
    window?.toolbar = toolbar
    window?.titleVisibility = .hidden
    window?.toolbarStyle = .unified
    window?.setFrameAutosaveName("MainWindow")

    if topLevelRoute == .onboarding {
      setupOnboarding()
    } else {
      setupMainSplitView()
    }
  }

  /// Animate or switch to next VC
  private func switchViewController(to viewController: NSViewController) {
    if let _ = window?.contentViewController {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.1
        context.allowsImplicitAnimation = true

        window?.contentViewController = viewController
      }
    } else {
      window?.contentViewController = viewController
    }
  }

  private func setupOnboarding() {
    switchViewController(to: OnboardingViewController(dependencies: dependencies))

    // configure window
    window?.isMovableByWindowBackground = true
    window?.titlebarAppearsTransparent = true
    window?.titleVisibility = .hidden
    // window?.toolbarStyle = .unified

    // setup toolbar
    currentToolbarItems = []
    
    while toolbar.items.count > 0 {
      toolbar.removeItem(at: 0)
    }
    
    toolbar.validateVisibleItems()
  }

  private func setupMainSplitView() {
    switchViewController(
      to: MainSplitViewController(dependencies: dependencies)
    )

    window?.titleVisibility = .hidden
    window?.isMovableByWindowBackground = false
    window?.titlebarAppearsTransparent = false // depends on inner route as well

    while toolbar.items.count > 0 {
      toolbar.removeItem(at: 0)
    }

    currentToolbarItems = [
      .toggleSidebar,
      .flexibleSpace,
      .homePlus,
      .sidebarTrackingSeparator,
      .flexibleSpace,
    ]

    for item in currentToolbarItems {
      toolbar.insertItem(withItemIdentifier: item, at: toolbar.items.count)
    }

    toolbar.validateVisibleItems()
    window?.toolbar = toolbar
    toolbar.isVisible = true
  }

  private func switchTopLevel(_ route: TopLevelRoute) {
    switch route {
      case .onboarding:
        setupOnboarding()
      case .main:
        setupMainSplitView()
    }
  }

  private var cancellables: Set<AnyCancellable> = []
  private func subscribe() {
    dependencies.viewModel.$topLevelRoute.sink { route in
      self.switchTopLevel(route)
    }.store(in: &cancellables)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func injectDependencies() {
    dependencies.rootData = RootData(db: dependencies.database, auth: dependencies.auth)
    dependencies.logOut = logOut
  }

  private func logOut() async {
    let _ = try? await ApiClient.shared.logout()

    // Clear creds
    Auth.shared.logOut()

    // Stop WebSocket
    dependencies.ws.loggedOut()

    // Clear database
    try? AppDatabase.loggedOut()

    // Navigate outside of the app
    dependencies.viewModel.navigate(.onboarding)

    // Reset internal navigation
    dependencies.navigation.reset()

    // Close Settings
    if let window = NSApplication.shared.keyWindow {
      window.close()
    }
  }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // Return current items or empty array for initial state
    currentToolbarItems
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // Return all possible items that could be shown
    [.toggleSidebar, .homePlus, .sidebarTrackingSeparator, .flexibleSpace]
  }

//  func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
//    switch identifier {
//      case .toggleSidebar:
//        let item = NSToolbarItem(itemIdentifier: identifier)
//        item.label = "Toggle Sidebar"
//        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
//        item.action = #selector(NSSplitViewController.toggleSidebar(_:))
//        return item
//
//      case .homePlus:
//        let item = NSMenuToolbarItem(itemIdentifier: identifier)
//        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
//        item.menu = createAddMenu()
//        return item
//
//      default:
//        return nil
//    }
//  }
  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
      case .toggleSidebar:
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Toggle Sidebar"
        item.image = NSImage(
          systemSymbolName: "sidebar.left",
          accessibilityDescription: nil
        )
        item.action = #selector(NSSplitViewController.toggleSidebar(_:))
        item.target = window?.contentViewController as? NSSplitViewController

        return item

      case .homePlus:
        let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
        item.image = NSImage(
          systemSymbolName: "plus",
          accessibilityDescription: "Add"
        )
        item.menu = createAddMenu()
        return item

      case .sidebarTrackingSeparator:
        return NSTrackingSeparatorToolbarItem(
          identifier: itemIdentifier,
          splitView: (window?.contentViewController as? NSSplitViewController)?.splitView ?? NSSplitView(),
          dividerIndex: 0
        )

      case .flexibleSpace:
        return NSToolbarItem(itemIdentifier: .flexibleSpace)

      default:
        return nil
    }
  }

  private func createAddMenu() -> NSMenu {
    let menu = NSMenu()
    let newSpaceItem = NSMenuItem(
      title: "New Space",
      action: #selector(createNewSpace),
      keyEquivalent: ""
    )
    menu.addItem(newSpaceItem)
    return menu
  }

  @objc private func createNewSpace() {
    // Implement your space creation logic here
  }
}

extension NSToolbarItem.Identifier {
  static let toggleSidebar = Self("ToggleSidebar")
  static let homePlus = Self("HomePlus")
}

// MARK: - Top level router

enum TopLevelRoute {
  case onboarding
  case main
}

class MainWindowViewModel: ObservableObject {
  @Published var topLevelRoute: TopLevelRoute

  init() {
    if Auth.shared.isLoggedIn {
      topLevelRoute = .main
    } else {
      topLevelRoute = .onboarding
    }
  }

  func navigate(_ route: TopLevelRoute) {
    topLevelRoute = route
  }

  public func setUpForInnerRoute(_ route: NavigationRoute) {
//    Log.shared.debug("Setting up window for inner route: \(route)")
//    switch route {
//      case .spaceRoot:
//        setToolbarVisibility(false)
//      case .homeRoot:
//        setToolbarVisibility(false)
//      case .chat:
//        // handled in message list appkit view bc we need to update the bg based on offset
//        // setToolbarVisibility(true)
//        break
//      case .chatInfo:
//        setToolbarVisibility(false)
//      case .profile:
//        setToolbarVisibility(false)
//    }
  }

  public func setToolbarVisibility(_ isVisible: Bool) {
//    guard let window else { return }
//
//    if isVisible {
//      window.titleVisibility = .visible // ensure
//      window.titlebarAppearsTransparent = false
//      window.titlebarSeparatorStyle = .automatic
//    } else {
//      window.titlebarAppearsTransparent = true
//      window.titlebarSeparatorStyle = .none
//    }
//
//    // common
//    window.toolbarStyle = .unified
  }
}
