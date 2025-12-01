import AppKit
import InlineKit
import Observation
import SwiftUI

class MainSplitView: NSViewController {
  let dependencies: AppDependencies

  // Views

  lazy var tabsArea: NSView = .init()

  lazy var sideArea: NSView = .init()

  lazy var contentArea: NSView = .init()

  // Constants

  private var tabsHeight: CGFloat = Theme.tabBarHeight
  private var sideWidth: CGFloat = 240
  private var innerPadding: CGFloat = Theme.mainSplitViewInnerPadding
  private var contentRadius: CGFloat = Theme.mainSplitViewContentRadius

  private var lastRenderedRoute: Nav2Route?

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
    view = NSView()
    view.wantsLayer = true
    // view.layer?.backgroundColor = CGColor(red: 0.0, green: 1.0, blue: 0, alpha: 1)
    // view.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(contentArea)
    view.addSubview(tabsArea)
    view.addSubview(sideArea)

    sideArea.translatesAutoresizingMaskIntoConstraints = false
    tabsArea.translatesAutoresizingMaskIntoConstraints = false
    contentArea.translatesAutoresizingMaskIntoConstraints = false

    sideArea.wantsLayer = true
    tabsArea.wantsLayer = true
    contentArea.wantsLayer = true

    tabsArea.layer?.backgroundColor = .clear
    sideArea.layer?.backgroundColor = .clear
    contentArea.layer?.backgroundColor = NSColor.controlBackgroundColor
      .withAlphaComponent(1.0).cgColor

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
    shadow.shadowBlurRadius = 2.0
    shadow.shadowOffset = .init(width: 0.0, height: 0.0)
    contentArea.shadow = shadow

    contentArea.layer?.cornerRadius = contentRadius

    NSLayoutConstraint.activate([
      tabsArea.heightAnchor.constraint(equalToConstant: tabsHeight),
      sideArea.widthAnchor.constraint(equalToConstant: sideWidth),

      sideArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      sideArea.topAnchor.constraint(equalTo: view.topAnchor),
      sideArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      contentArea.leadingAnchor.constraint(equalTo: sideArea.trailingAnchor),
      contentArea.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -innerPadding),
      tabsArea.leadingAnchor.constraint(equalTo: sideArea.trailingAnchor),
      tabsArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      tabsArea.topAnchor.constraint(equalTo: view.topAnchor),
      contentArea.topAnchor
        .constraint(equalTo: tabsArea.bottomAnchor),
      contentArea.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -innerPadding),
    ])

    setSidebar(viewController: MainSidebar(dependencies: dependencies))
    setTabBar(viewController: MainTabBar(dependencies: dependencies))

    setupNav()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  private func setupNav() {
    guard let nav2 = dependencies.nav2 else { return }

    // Render immediately so we have the right content on first load.
    updateContent(for: nav2.currentRoute)

    // Re-register observation on every change (Observation doesn't keep watchers alive).
    withObservationTracking { [weak self] in
      guard let self else { return }
      _ = nav2.currentRoute
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let nav2 = dependencies.nav2 else { return }
        updateContent(for: nav2.currentRoute)
        setupNav()
      }
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
    contentArea.addSubview(viewController.view)

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
    setContentArea(viewController: viewController)
  }
}
