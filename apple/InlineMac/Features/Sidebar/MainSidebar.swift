import AppKit
import InlineKit
import Observation

class MainSidebar: NSViewController {
  private let dependencies: AppDependencies
  private let listView: MainSidebarList

  private var nav2: Nav2? { dependencies.nav2 }

  // MARK: - Sizes

  // Used in header, collection view item, and collection view layout.

  static let iconSize: CGFloat = 24
  static let itemHeight: CGFloat = 32
  static let iconTrailingPadding: CGFloat = 8
  static let fontSize: CGFloat = 13
  static let fontWeight: NSFont.Weight = .regular
  static let font: NSFont = .systemFont(ofSize: fontSize, weight: fontWeight)
  static let itemSpacing: CGFloat = 2
  static let outerEdgeInsets: CGFloat = 10
  static let innerEdgeInsets: CGFloat = 8
  static let edgeInsets: CGFloat = MainSidebar.outerEdgeInsets + MainSidebar.innerEdgeInsets

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    listView = MainSidebarList(dependencies: dependencies)

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Header
  private lazy var headerView: MainSidebarHeaderView = {
    let view = MainSidebarHeaderView(dependencies: dependencies)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var headerTopConstraint: NSLayoutConstraint?

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
  }

  private func setupViews() {
    view.addSubview(headerView)
    view.addSubview(listView)

    headerTopConstraint = headerView.topAnchor.constraint(equalTo: view.topAnchor, constant: headerTopInset())

    NSLayoutConstraint.activate([
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.edgeInsets),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: Self.edgeInsets),
      headerTopConstraint!,

      listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      listView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 6),
      listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  private func headerTopInset() -> CGFloat {
    if let window = view.window, window.styleMask.contains(.fullSizeContentView) {
      // Leave room for traffic lights when content is full-height.
      return 44
    }
    return 8
  }

  // TODO: This doesn't trigger the change when the window enters full screen
  override func viewDidLayout() {
    super.viewDidLayout()
    headerTopConstraint?.constant = headerTopInset()
  }
}
