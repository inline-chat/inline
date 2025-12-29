import AppKit
import InlineKit
import Observation
import SwiftUI

class MainSplitView: NSViewController {
  let dependencies: AppDependencies

  // Views

  lazy var tabsArea: NSView = .init()

  lazy var sideArea: NSView = .init()

  lazy var contentContainer: NSView = .init()

  lazy var contentArea: NSView = {
    let view = ContentAreaView()
    view.wantsLayer = true
    return view
  }()

  lazy var toolbarArea: MainToolbarView = {
    let view = MainToolbarView(dependencies: dependencies)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.transparent = true
    return view
  }()

  // Constants

  private var tabsHeight: CGFloat = Theme.tabBarHeight
  private var sideWidth: CGFloat = 240
  private var innerPadding: CGFloat = Theme.mainSplitViewInnerPadding
  private var contentRadius: CGFloat = Theme.mainSplitViewContentRadius

  private var lastRenderedRoute: Nav2Route?
  private var escapeKeyUnsubscriber: (() -> Void)?

  // ....

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init(coder _: NSCoder) {
    fatalError("Not implemented")
  }

  override func loadView() {
    let rootView = NSView()
    view = rootView
    view.wantsLayer = true

    view.addSubview(contentContainer)

    contentContainer.addSubview(contentArea)
    contentArea.addSubview(toolbarArea)

    view.addSubview(tabsArea)
    view.addSubview(sideArea)

    sideArea.translatesAutoresizingMaskIntoConstraints = false
    tabsArea.translatesAutoresizingMaskIntoConstraints = false
    contentContainer.translatesAutoresizingMaskIntoConstraints = false
    contentArea.translatesAutoresizingMaskIntoConstraints = false

    sideArea.wantsLayer = true
    tabsArea.wantsLayer = true
    contentContainer.wantsLayer = true
    contentArea.wantsLayer = true

    tabsArea.layer?.backgroundColor = .clear
    sideArea.layer?.backgroundColor = .clear

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
    shadow.shadowBlurRadius = 2.0
    shadow.shadowOffset = .init(width: 0.0, height: -1.0)
    contentContainer.shadow = shadow

    contentContainer.layer?.cornerRadius = contentRadius
    contentContainer.layer?.cornerCurve = .continuous

    contentArea.layer?.cornerRadius = contentRadius
    contentArea.layer?.cornerCurve = .continuous
    contentArea.layer?.maskedCorners = [
      .layerMinXMinYCorner,
      .layerMaxXMinYCorner,
      .layerMinXMaxYCorner,
      .layerMaxXMaxYCorner,
    ]
    contentArea.layer?.masksToBounds = true

    NSLayoutConstraint.activate([
      tabsArea.heightAnchor.constraint(equalToConstant: tabsHeight),
      sideArea.widthAnchor.constraint(equalToConstant: sideWidth),

      sideArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      sideArea.topAnchor.constraint(equalTo: view.topAnchor),
      sideArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentContainer.leadingAnchor.constraint(equalTo: sideArea.trailingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -innerPadding),

      toolbarArea
        .leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
      toolbarArea
        .trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
      toolbarArea
        .topAnchor.constraint(equalTo: contentContainer.topAnchor),
      toolbarArea
        .heightAnchor.constraint(equalToConstant: Theme.toolbarHeight),

      tabsArea.leadingAnchor.constraint(equalTo: sideArea.trailingAnchor),
      tabsArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      tabsArea.topAnchor.constraint(equalTo: view.topAnchor),
      contentContainer.topAnchor
        .constraint(equalTo: tabsArea.bottomAnchor),
      contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -innerPadding),

      contentArea.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
      contentArea.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
      contentArea.topAnchor.constraint(equalTo: contentContainer.topAnchor),
      contentArea.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
    ])

    setSidebar(viewController: MainSidebar(dependencies: dependencies))
    setTabBar(viewController: MainTabBar(dependencies: dependencies))

    setupNav()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  deinit {
    escapeKeyUnsubscriber?()
    escapeKeyUnsubscriber = nil
  }

  private func setupNav() {
    guard let nav2 = dependencies.nav2 else { return }

    // Render immediately so we have the right content on first load.
    updateContent(for: nav2.currentRoute)
    updateEscapeHandler(for: nav2)

    // Re-register observation on every change (Observation doesn't keep watchers alive).
    withObservationTracking { [weak self] in
      guard let self else { return }
      _ = nav2.currentRoute
      _ = nav2.activeTab
      // updateContent(for: nav2.currentRoute)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let nav2 = dependencies.nav2 else { return }
        updateContent(for: nav2.currentRoute)
        updateEscapeHandler(for: nav2)
        setupNav()
      }
    }
  }

  private func updateEscapeHandler(for nav2: Nav2) {
    let shouldHandleEscape = escapeTargetRoute(for: nav2) != nil

    if shouldHandleEscape {
      guard escapeKeyUnsubscriber == nil else { return }
      guard let keyMonitor = dependencies.keyMonitor else { return }
      escapeKeyUnsubscriber = keyMonitor.addHandler(for: .escape, key: "nav2_escape") { [weak self] _ in
        self?.handleEscape()
      }
    } else {
      escapeKeyUnsubscriber?()
      escapeKeyUnsubscriber = nil
    }
  }

  private func handleEscape() {
    guard let nav2 = dependencies.nav2 else { return }
    guard let targetRoute = escapeTargetRoute(for: nav2) else { return }
    nav2.navigate(to: targetRoute)
  }

  private func escapeTargetRoute(for nav2: Nav2) -> Nav2Route? {
    switch nav2.activeTab {
      case .home:
        return nav2.currentRoute == .spaces ? nil : .spaces
      case .space:
        return nav2.currentRoute == .empty ? nil : .empty
    }
  }

  // MARK: - Public API

  private var sidebarVC: NSViewController?
  private var tabBarVC: NSViewController?
  private var contentVC: NSViewController?

  func setSidebar(viewController: NSViewController) {
    // Remove previous
    sidebarVC?.removeFromParent()
    sidebarVC?.view.removeFromSuperview()
    sidebarVC = viewController

    // Add new view
    addChild(viewController)
    sideArea.addSubview(viewController.view)

    // Pin to superview
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: sideArea.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: sideArea.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: sideArea.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: sideArea.trailingAnchor),
    ])
  }

  func setTabBar(viewController: NSViewController) {
    tabBarVC?.removeFromParent()
    tabBarVC?.view.removeFromSuperview()
    tabBarVC = viewController

    addChild(viewController)
    tabsArea.addSubview(viewController.view)

    // Pin to superview
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: tabsArea.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: tabsArea.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: tabsArea.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: tabsArea.trailingAnchor),
    ])
  }

  private func setContentArea(viewController: NSViewController) {
    contentVC?.removeFromParent()
    contentVC?.view.removeFromSuperview()
    contentVC = viewController

    addChild(viewController)
    contentArea.addSubview(viewController.view, positioned: .below, relativeTo: toolbarArea)

    // Pin to superview
    viewController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      viewController.view.topAnchor.constraint(equalTo: contentArea.topAnchor),
      viewController.view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
      viewController.view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
      viewController.view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
    ])
  }

  @MainActor
  private func updateContent(for route: Nav2Route) {
    guard route != lastRenderedRoute else { return }
    lastRenderedRoute = route

    let viewController = viewController(for: route)
    let toolbar = toolbar(for: route)
    toolbarArea.update(with: toolbar)
    setContentArea(viewController: viewController)
  }
}

class ContentAreaView: NSView {
  init() {
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateLayer() {
    layer?.backgroundColor = Theme.windowContentBackgroundColor.cgColor
    super.updateLayer()
  }
}
