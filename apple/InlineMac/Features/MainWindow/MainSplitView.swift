import AppKit

class MainSplitView: NSViewController {
  private let dependencies: AppDependencies

  // Views

  lazy var tabsArea: NSView = .init()

  lazy var sideArea: NSView = .init()

  lazy var contentArea: NSView = .init()

  // Constants

  private var tabsHeight: CGFloat = Theme.tabBarHeight
  private var sideWidth: CGFloat = 240
  private var innerPadding: CGFloat = Theme.mainSplitViewInnerPadding
  private var contentRadius: CGFloat = Theme.mainSplitViewContentRadius

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

//    tabsArea.layer?.backgroundColor = NSColor.controlBackgroundColor
//      .withAlphaComponent(0.4).cgColor
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
  }

  override func viewDidLoad() {
    super.viewDidLoad()
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
}
