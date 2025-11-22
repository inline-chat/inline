import AppKit
import Auth
import Combine
import InlineKit
import Logger
import SwiftUI

class MainWindowController: NSWindowController, NSWindowDelegate {
  private var dependencies: AppDependencies
  private var keyMonitor: KeyMonitor
  private var log = Log.scoped("MainWindowController")

  private var nav2: Nav2 = .init()

  private var defaultSize = NSSize(width: 850, height: 620)
  private var minSize = NSSize(width: 640, height: 320)

  private var topLevelRoute: TopLevelRoute {
    dependencies.viewModel.topLevelRoute
  }

  private var nav: Nav {
    dependencies.nav
  }

  private var currentTopLevelRoute: TopLevelRoute?
  private var windowView: MainWindowView = .init()

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
    self.dependencies.nav2 = nav2
    super.init(window: window)

    injectDependencies()
    configureWindow()
    setupToolbar()
    setupEventMonitor()
    subscribe()
  }

  private func setupToolbar() {
    guard let window else { return }

    let toolbar = NSToolbar(identifier: "MainToolbar")
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.styleMask.insert(.fullSizeContentView)

    // window.toolbarStyle = .unifiedCompact
    window.toolbarStyle = .unified
  }

  private func configureWindow() {
    guard let window else { return }
    window.title = "Inline"
    window.backgroundColor = NSColor.clear
    window.isOpaque = false
    window.setFrameAutosaveName("MainWindow")
    window.contentViewController = windowView
    window.delegate = self
    window.setContentSize(NSSize(width: 780, height: 500))

    switchTopLevel(topLevelRoute)
  }

  /// Animate or switch to next VC
  private func switchViewController(to viewController: NSViewController) {
    windowView.switchTo(viewController: viewController)
  }

  private func setupOnboarding() {
    switchViewController(to: OnboardingViewController(dependencies: dependencies))

    // configure window
    window?.isMovableByWindowBackground = true
    window?.backgroundColor = .clear
    window?.setContentSize(NSSize(width: 780, height: 500))
  }

  private func setupMainSplitView() {
    log.debug("Setting up main split view")

    window?.isMovableByWindowBackground = false

    // re-add rootData so it has fresh user ID
    dependencies.rootData = RootData(db: dependencies.database, auth: dependencies.auth)

    // set main view
    switchViewController(
      to: MainSplitView(dependencies: dependencies)
    )

    setupWindowFor(route: nav.currentRoute)
  }

  private func switchTopLevel(_ route: TopLevelRoute) {
    currentTopLevelRoute = route
    switch route {
      case .onboarding:
        setupOnboarding()
      case .main:
        setupMainSplitView()
    }

    // TODO: fix window sizing
    window?.setContentSize(defaultSize)
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
        // reloadToolbar()
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
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func injectDependencies() {
    dependencies.rootData = RootData(db: dependencies.database, auth: dependencies.auth)
  }

  private func setupWindowFor(route _: NavEntry.Route) {
//    switch route {
//    case .chat:
//      window?.backgroundColor = .controlBackgroundColor
//
//    default:
//      window?.backgroundColor = .controlBackgroundColor
//      window?.titlebarAppearsTransparent = titlebarAppearsTransparent
//      window?.isMovableByWindowBackground = false
//    }
  }

  // MARK: - Toolbar event handling

  private var rightClickMonitor: Any?

  private func setupEventMonitor() {
    // Block right-click on toolbar
    rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
      guard let self,
            let window else { return event }

      let locationInWindow = event.locationInWindow

      // Check if click is in toolbar area (top of window)
      let windowFrame = window.frame
      let toolbarHeight: CGFloat = 52 // Approximate toolbar height
      let toolbarRect = NSRect(
        x: 0,
        y: windowFrame.height - toolbarHeight,
        width: windowFrame.width,
        height: toolbarHeight
      )

      if toolbarRect.contains(locationInWindow) {
        return nil // Block the event
      }

      return event
    }
  }

  // MARK: - NSWindowDelegate

  func window(
    _: NSWindow,
    willUseFullScreenPresentationOptions _: NSApplication.PresentationOptions = []
  ) -> NSApplication
    .PresentationOptions
  {
    [.autoHideToolbar, .autoHideMenuBar, .fullScreen]
  }

  // MARK: - Deinit

  deinit {
    if let monitor = rightClickMonitor {
      NSEvent.removeMonitor(monitor)
    }

    cancellables.removeAll()
    navBackButton = nil
    navForwardButton = nil
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
  static let participants = Self("Participants")
  static let translate = Self("Translate")
  static let transparentItem = Self("TransparentItem")
  static let textItem = Self("TextItem")
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
}

//    // Create buttons
//    let backButton = NSButton()
//    backButton.bezelStyle = .texturedRounded
//    backButton.isBordered = true
//    backButton.controlSize = .large
//    backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
//    backButton.target = self
//    backButton.action = #selector(goBack)
//    backButton.isEnabled = dependencies.nav.canGoBack
//
//    let forwardButton = NSButton()
//    forwardButton.bezelStyle = .texturedRounded
//    forwardButton.controlSize = .large
//    forwardButton.isBordered = true
//    forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
//    forwardButton.target = self
//    forwardButton.action = #selector(goForward)
//    forwardButton.isEnabled = dependencies.nav.canGoForward
//
//    // Add buttons to container
//    containerView.addSubview(backButton)
//    containerView.addSubview(forwardButton)
//
//    // Layout constraints
//    backButton.translatesAutoresizingMaskIntoConstraints = false
//    forwardButton.translatesAutoresizingMaskIntoConstraints = false
//
//    NSLayoutConstraint.activate([
//      backButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
//      backButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
//
//      forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 0), // No gap
//      forwardButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
//      forwardButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
//
//      // Make sure the container sizes itself to fit the buttons
//      containerView.heightAnchor.constraint(equalTo: backButton.heightAnchor),
//    ])
//
//    item.view = containerView
//
//    // Store references for state updates
//    navBackButton = backButton
//    navForwardButton = forwardButton
//
//    return item
//  }
//
//  // Then in your action:
//  @objc private func segmentedNavAction(_ sender: NSSegmentedControl) {
//    switch sender.selectedSegment {
//    case 0:
//      goBack()
//    case 1:
//      goForward()
//    default:
//      break
//    }
//  }
// }
