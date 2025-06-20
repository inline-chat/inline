import AppKit
import Auth
import Combine
import InlineKit
import Logger
import SwiftUI

class MainWindowController: NSWindowController {
  private var dependencies: AppDependencies
  private var keyMonitor: KeyMonitor
  private var log = Log.scoped("MainWindowController")

  private var topLevelRoute: TopLevelRoute {
    dependencies.viewModel.topLevelRoute
  }

  private var currentTopLevelRoute: TopLevelRoute? = nil

  private var navBackButton: NSButton?
  private var navForwardButton: NSButton?

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

    keyMonitor = KeyMonitor(window: window)
    self.dependencies.keyMonitor = keyMonitor
    super.init(window: window)

    injectDependencies()
    configureWindow()
    subscribe()
  }

  private lazy var toolbar: NSToolbar = {
    let toolbar = NSToolbar(identifier: "MainToolbar")
    toolbar.delegate = self
    toolbar.allowsUserCustomization = false
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
    window?.delegate = self

    switchTopLevel(topLevelRoute)
  }

  /// Animate or switch to next VC
  private func switchViewController(to viewController: NSViewController) {
    window?.contentViewController = viewController
  }

  private func setupOnboarding() {
    switchViewController(to: OnboardingViewController(dependencies: dependencies))

    // configure window
    window?.titlebarAppearsTransparent = true
    window?.isMovableByWindowBackground = true
    window?.titleVisibility = .hidden
    window?.backgroundColor = .clear
    window?.setContentSize(NSSize(width: 780, height: 500))

    reloadToolbar()
  }

  private var titlebarAppearsTransparent: Bool {
    if #available(macOS 26.0, *) {
      false
    } else {
      // Fallback on earlier versions
      true
    }
  }

  private func setupMainSplitView() {
    log.debug("Setting up main split view")

    // re-add rootData so it has fresh user ID
    dependencies.rootData = RootData(db: dependencies.database, auth: dependencies.auth)

    // set main view
    switchViewController(
      to: MainSplitViewController(dependencies: dependencies)
    )

    ensureToolbarIsSet()

    window?.titleVisibility = .hidden
    window?.isMovableByWindowBackground = false
    window?.titlebarAppearsTransparent = titlebarAppearsTransparent
    // window background is set based on current route

    setupWindowFor(route: nav.currentRoute)

    reloadToolbar()
  }

  private func ensureToolbarIsSet() {
    window?.toolbar = toolbar
    toolbar.isVisible = true
  }

  private func reloadToolbar() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.0
      context.allowsImplicitAnimation = false

      while toolbar.items.count > 0 {
        toolbar.removeItem(at: 0)
      }

      for item in currentToolbarIdentifiers {
        toolbar.insertItem(withItemIdentifier: item, at: toolbar.items.count)
      }

      toolbar.validateVisibleItems()
    }
  }

  private func switchTopLevel(_ route: TopLevelRoute) {
    currentTopLevelRoute = route
    switch route {
      case .onboarding:
        setupOnboarding()
      case .main:
        setupMainSplitView()
    }

    // TODO: fix sizing
    window?.setContentSize(NSSize(width: 740, height: 600))
    window?.setFrameUsingName("MainWindow")
    window?.minSize = NSSize(width: 330, height: 220)
  }

  private var cancellables: Set<AnyCancellable> = []
  private func subscribe() {
    dependencies.viewModel.$topLevelRoute.receive(on: DispatchQueue.main).sink { route in
      self.log.debug("Top level route changed: \(route)")

      // Prevent re-open
      if route == self.currentTopLevelRoute {
        self.log.debug("Skipped top level change")
        return
      }
      DispatchQueue.main.async {
        self.switchTopLevel(route)
      }
    }.store(in: &cancellables)

    dependencies.nav.currentRoutePublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] route in
        guard let self else { return }
        guard topLevelRoute == .main else { return }

        // Make sure this is called with the right route. Probably in sink we don't have latest value yet
        setupWindowFor(route: route)
        reloadToolbar()
      }.store(in: &cancellables)

    dependencies.nav.canGoBackPublisher
      .receive(on: DispatchQueue.main).sink { [weak self] value in
        self?.navBackButton?.isEnabled = value
      }.store(in: &cancellables)

    dependencies.nav.canGoForwardPublisher
      .receive(on: DispatchQueue.main).sink { [weak self] value in
        self?.navForwardButton?.isEnabled = value
      }.store(in: &cancellables)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func injectDependencies() {
    dependencies.rootData = RootData(db: dependencies.database, auth: dependencies.auth)
  }

  private func setupWindowFor(route: NavEntry.Route) {
    switch route {
      case .chat:
        window?.backgroundColor = .controlBackgroundColor

      default:
        window?.backgroundColor = .controlBackgroundColor
        window?.titlebarAppearsTransparent = titlebarAppearsTransparent
        window?.isMovableByWindowBackground = false
    }
  }

  deinit {
    cancellables.removeAll()
    navBackButton = nil
    navForwardButton = nil
  }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // Return current items or empty array for initial state
    currentToolbarIdentifiers
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    // Return all possible items that could be shown
    [
      .toggleSidebar,
      .homePlus,
      .sidebarTrackingSeparator,
      .flexibleSpace,
      .navGroup,
      .navBack,
      .navForward,
      .chatTitle,
      .translate,
    ]
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch itemIdentifier {
      case .toggleSidebar:
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = true
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

//      case .backToHome:
//        return makeBackToHome()

      case .flexibleSpace:
        return NSToolbarItem(itemIdentifier: .flexibleSpace)

      case .navGroup:
        return makeNavigationButtons()

      case .chatTitle:
        guard case let .chat(peer) = nav.currentRoute else { return nil }
        return ChatTitleToolbar(
          peer: peer,
          dependencies: dependencies
        )

      case .translate:
        guard case let .chat(peer) = nav.currentRoute else { return nil }
        return createTranslateButton(peer: peer)

      default:
        return nil
    }
  }

  var nav: Nav {
    dependencies.nav
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

  private func createTranslateButton(peer: Peer) -> NSToolbarItem {
    let item = TranslateToolbar(peer: peer, dependencies: dependencies)
    item.visibilityPriority = .high
    return item
  }

  @objc private func createNewSpace() {
    dependencies.nav.open(.createSpace)
  }

  @objc private func goBack() {
    dependencies.nav.goBack()
  }

  @objc private func goForward() {
    dependencies.nav.goForward()
  }

  @objc private func goBackToHome() {
    dependencies.nav.openHome()
  }
}

extension NSToolbarItem.Identifier {
  static let toggleSidebar = Self("ToggleSidebar")
  static let homePlus = Self("HomePlus")
  static let spacePlus = Self("SpacePlus")
  static let backToHome = Self("BackToHome")
  static let navGroup = Self("NavGroup")
  static let navBack = Self("NavBack")
  static let navForward = Self("NavForward")
  static let chatTitle = Self("ChatTitle")
  static let translate = Self("Translate")
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

// MARK: - Toolbar Builders

extension MainWindowController {
  private var currentToolbarIdentifiers: [NSToolbarItem.Identifier] {
    let nav = dependencies.nav
    var items: [NSToolbarItem.Identifier] = []

    if topLevelRoute == .onboarding {
      return items
    }

    // Base
    // items.append(.toggleSidebar)

    // Sidebar items
    if nav.history.last?.spaceId != nil {
      items.append(.flexibleSpace)
      // items.append(.spacePlus)
    } else {
      items.append(.flexibleSpace)
      // items.append(.homePlus)
    }

    // Close sidebar
    items.append(.sidebarTrackingSeparator)

    // Nav
    items.append(.navGroup)

    // Route dependant items
    switch nav.currentRoute {
      case .chat:
        items.append(.chatTitle)
        items.append(.flexibleSpace)
        // FIXME: check if we should show this
        items.append(.translate)

      default:
        break
    }

    return items
  }

  private func makeNavigationButtons() -> NSToolbarItem {
    let item = NSToolbarItemGroup(itemIdentifier: .navGroup)
    item.isNavigational = true
    item.visibilityPriority = .low
    item.label = "Navigation"

    // Create a container view for the buttons
    let containerView = NSView()

    // Create buttons
    let backButton = NSButton()
    backButton.bezelStyle = .texturedRounded
    backButton.isBordered = true
    backButton.controlSize = .large
    backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
    backButton.target = self
    backButton.action = #selector(goBack)
    backButton.isEnabled = dependencies.nav.canGoBack

    let forwardButton = NSButton()
    forwardButton.bezelStyle = .texturedRounded
    forwardButton.controlSize = .large
    forwardButton.isBordered = true
    forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
    forwardButton.target = self
    forwardButton.action = #selector(goForward)
    forwardButton.isEnabled = dependencies.nav.canGoForward

    // Add buttons to container
    containerView.addSubview(backButton)
    containerView.addSubview(forwardButton)

    // Layout constraints
    backButton.translatesAutoresizingMaskIntoConstraints = false
    forwardButton.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      backButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      backButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

      forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 0), // No gap
      forwardButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
      forwardButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

      // Make sure the container sizes itself to fit the buttons
      containerView.heightAnchor.constraint(equalTo: backButton.heightAnchor),
    ])

    item.view = containerView

    // Store references for state updates
    navBackButton = backButton
    navForwardButton = forwardButton

    return item
  }

  // Then in your action:
  @objc private func segmentedNavAction(_ sender: NSSegmentedControl) {
    switch sender.selectedSegment {
      case 0:
        goBack()
      case 1:
        goForward()
      default:
        break
    }
  }
}

extension MainWindowController: NSWindowDelegate {
  func windowDidEndLiveResize(_ notification: Notification) {
    window?.saveFrame(usingName: "MainWindow")
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.saveFrame(usingName: "MainWindow")
    return true
  }
}
