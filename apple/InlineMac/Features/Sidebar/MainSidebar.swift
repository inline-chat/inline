import AppKit
class MainSidebar: NSViewController {
  private let dependencies: AppDependencies
  private let listView: MainSidebarList

  private var activeMode: MainSidebarMode = .inbox

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

  private lazy var footerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var archiveButton: MainSidebarArchiveButton = {
    let button = MainSidebarArchiveButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = #selector(handleArchiveButton)
    return button
  }()

  private lazy var archiveEmptyView: NSStackView = {
    let label = NSTextField(labelWithString: "You haven't archived any chats yet!")
    label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    label.textColor = .tertiaryLabelColor
    label.alignment = .center
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byWordWrapping

    let stack = NSStackView(views: [label])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private var headerTopConstraint: NSLayoutConstraint?
  private var switchToInboxObserver: NSObjectProtocol?

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
  }

  private func setupViews() {
    view.addSubview(headerView)
    view.addSubview(listView)
    view.addSubview(footerView)
    footerView.addSubview(archiveButton)
    view.addSubview(archiveEmptyView)

    headerTopConstraint = headerView.topAnchor.constraint(equalTo: view.topAnchor, constant: headerTopInset())

    NSLayoutConstraint.activate([
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.outerEdgeInsets),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.outerEdgeInsets),
      headerTopConstraint!,

      listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      listView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
      listView.bottomAnchor.constraint(equalTo: footerView.topAnchor, constant: -8),

      footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      footerView.heightAnchor.constraint(equalToConstant: 40),

      archiveButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: Self.edgeInsets),
      archiveButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
      archiveButton.widthAnchor.constraint(equalToConstant: 28),
      archiveButton.heightAnchor.constraint(equalToConstant: 28),

      archiveEmptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      archiveEmptyView.centerYAnchor.constraint(equalTo: listView.centerYAnchor),
      archiveEmptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      archiveEmptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])

    archiveEmptyView.isHidden = true

    listView.onChatCountChanged = { [weak self] mode, count in
      guard let self else { return }
      self.archiveEmptyView.isHidden = !(mode == .archive && count == 0)
    }

    setContent(for: .inbox)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    switchToInboxObserver = NotificationCenter.default.addObserver(
      forName: .switchToInbox,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setContent(for: .inbox)
    }
  }

  deinit {
    if let switchToInboxObserver {
      NotificationCenter.default.removeObserver(switchToInboxObserver)
    }
  }

  private func setContent(for mode: MainSidebarMode) {
    activeMode = mode
    updateArchiveButton()

    switch mode {
      case .archive:
        listView.setMode(.archive)
        archiveEmptyView.isHidden = listView.lastChatItemCount != 0
      case .inbox:
        listView.setMode(.inbox)
        archiveEmptyView.isHidden = true
    }
  }

  private func updateArchiveButton() {
    archiveButton.isActive = activeMode == .archive
    archiveButton.toolTip = activeMode == .archive ? "Show inbox" : "Show archives"
  }

  @objc private func handleArchiveButton() {
    let nextMode: MainSidebarMode = activeMode == .archive ? .inbox : .archive
    setContent(for: nextMode)
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

private enum MainSidebarMode {
  case archive
  case inbox
}

private final class MainSidebarArchiveButton: NSButton {
  private static let cornerRadius: CGFloat = 8
  private static let iconSize: CGFloat = 14
  private static let hoverColor = NSColor.black.withAlphaComponent(0.08)
  private static let pressedColor = NSColor.black.withAlphaComponent(0.12)
  private static let activeTint = NSColor.controlAccentColor
  private static let inactiveTint = NSColor.secondaryLabelColor

  private var trackingArea: NSTrackingArea?

  private var isHovering = false {
    didSet { updateBackground() }
  }

  var isActive: Bool = false {
    didSet { updateAppearance() }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }

  convenience init() {
    self.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet { updateBackground() }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    trackingArea = area
    addTrackingArea(area)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovering = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovering = false
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = Self.cornerRadius
    layer?.cornerCurve = .continuous
    setButtonType(.momentaryChange)
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    focusRingType = .none
    updateAppearance()
  }

  private func updateAppearance() {
    let symbolName = isActive ? "archivebox.fill" : "archivebox"
    let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .semibold)
    image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Archive")?
      .withSymbolConfiguration(config)
    contentTintColor = isActive ? Self.activeTint : Self.inactiveTint
    updateBackground()
  }

  private func updateBackground() {
    let color: NSColor
    if isHighlighted {
      color = Self.pressedColor
    } else if isHovering {
      color = Self.hoverColor
    } else {
      color = .clear
    }
    layer?.backgroundColor = color.cgColor
  }
}
