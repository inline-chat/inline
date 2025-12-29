import AppKit
import InlineKit
import Observation

class MainSidebar: NSViewController {
  private let dependencies: AppDependencies
  private let listView: MainSidebarList

  private var nav2: Nav2? { dependencies.nav2 }
  private var activeTab: MainSidebarTopTab = .inbox
  private var focusSearchObserver: NSObjectProtocol?

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

  private lazy var tabsView: MainSidebarTopTabsView = {
    let view = MainSidebarTopTabsView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var searchFieldView: MainSidebarSearchFieldView = {
    let view = MainSidebarSearchFieldView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var footerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
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
    view.addSubview(searchFieldView)
    view.addSubview(footerView)
    footerView.addSubview(tabsView)
    view.addSubview(archiveEmptyView)

    headerTopConstraint = headerView.topAnchor.constraint(equalTo: view.topAnchor, constant: headerTopInset())

    NSLayoutConstraint.activate([
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.edgeInsets),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: Self.edgeInsets),
      headerTopConstraint!,

      searchFieldView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.edgeInsets),
      searchFieldView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.edgeInsets),
      searchFieldView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 10),
      searchFieldView.heightAnchor.constraint(equalToConstant: 30),

      listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      listView.topAnchor.constraint(equalTo: searchFieldView.bottomAnchor, constant: 10),
      listView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

      footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      footerView.heightAnchor.constraint(equalToConstant: 40),

      tabsView.centerXAnchor.constraint(equalTo: footerView.centerXAnchor),
      tabsView.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
      tabsView.leadingAnchor.constraint(greaterThanOrEqualTo: footerView.leadingAnchor, constant: Self.edgeInsets),
      tabsView.trailingAnchor.constraint(lessThanOrEqualTo: footerView.trailingAnchor, constant: -Self.edgeInsets),

      archiveEmptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      archiveEmptyView.centerYAnchor.constraint(equalTo: listView.centerYAnchor),
      archiveEmptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      archiveEmptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])

    archiveEmptyView.isHidden = true

    tabsView.onSelect = { [weak self] tab in
      self?.setContent(for: tab)
    }
    setContent(for: .inbox)

    listView.onChatCountChanged = { [weak self] mode, count in
      guard let self else { return }
      self.archiveEmptyView.isHidden = !(mode == .archive && count == 0)
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    focusSearchObserver = NotificationCenter.default.addObserver(
      forName: .focusSearch,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.handleFocusSearch()
    }
    switchToInboxObserver = NotificationCenter.default.addObserver(
      forName: .switchToInbox,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setContent(for: .inbox)
    }
  }

  deinit {
    if let focusSearchObserver {
      NotificationCenter.default.removeObserver(focusSearchObserver)
    }
    if let switchToInboxObserver {
      NotificationCenter.default.removeObserver(switchToInboxObserver)
    }
  }

  private func setContent(for tab: MainSidebarTopTab) {
    activeTab = tab
    tabsView.selectTab(tab)

    switch tab {
      case .archive:
        listView.setMode(.archive)
        archiveEmptyView.isHidden = listView.lastChatItemCount != 0
      case .inbox:
        listView.setMode(.inbox)
        archiveEmptyView.isHidden = true
    }
  }

  private func handleFocusSearch() {
    view.window?.makeFirstResponder(searchFieldView.textField)
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

private enum MainSidebarTopTab: Int, CaseIterable {
  case archive
  case inbox

  var symbolName: String {
    switch self {
      case .archive:
        return "archivebox.fill"
      case .inbox:
        return "tray.fill"
    }
  }

  var accessibilityLabel: String {
    switch self {
      case .archive:
        return "Archive"
      case .inbox:
        return "Inbox"
    }
  }
}

final class MainSidebarTopTabsView: NSView {
  private static let height: CGFloat = 30
  private static let cornerRadius: CGFloat = 12
  private static let iconSize: CGFloat = 15
  private static let backgroundColor = NSColor.clear
  private static let hoverColor = NSColor.black.withAlphaComponent(0.08)
  private static let pressedColor = NSColor.black.withAlphaComponent(0.12)
  private static let minButtonWidth: CGFloat = 44

  private var selectedTab: MainSidebarTopTab = .inbox {
    didSet { updateSelection() }
  }

  fileprivate var onSelect: ((MainSidebarTopTab) -> Void)?

  private lazy var stackView: NSStackView = {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.distribution = .fillEqually
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private var buttons: [MainSidebarTopTab: NSButton] = [:]

  override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    addSubview(stackView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      stackView.topAnchor.constraint(equalTo: topAnchor),
      stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    MainSidebarTopTab.allCases.forEach { tab in
      let button = makeButton(for: tab)
      buttons[tab] = button
      stackView.addArrangedSubview(button)
    }

    updateSelection()
  }

  private func makeButton(for tab: MainSidebarTopTab) -> NSButton {
    let button = MainSidebarTopTabButton(
      tab: tab,
      baseColor: Self.backgroundColor,
      hoverColor: Self.hoverColor,
      pressedColor: Self.pressedColor
    )
    button.target = self
    button.action = #selector(didPressTab(_:))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setButtonType(.momentaryChange)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.tag = tab.rawValue
    button.toolTip = tab.accessibilityLabel
    button.focusRingType = .none

    if let image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.accessibilityLabel) {
      let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .regular)
      button.image = image.withSymbolConfiguration(config)
    }

    button.layer?.cornerRadius = Self.cornerRadius
    button.layer?.cornerCurve = .continuous

    NSLayoutConstraint.activate([
      button.heightAnchor.constraint(equalToConstant: Self.height),
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minButtonWidth),
    ])

    return button
  }

  private func updateSelection() {
    for (tab, button) in buttons {
      let isSelected = tab == selectedTab
      button.contentTintColor = isSelected ? .controlAccentColor : .tertiaryLabelColor
    }
  }

  fileprivate func selectTab(_ tab: MainSidebarTopTab, notify: Bool = false) {
    if tab == selectedTab {
      if notify {
        onSelect?(tab)
      }
      return
    }

    selectedTab = tab
    if notify {
      onSelect?(tab)
    }
  }

  @objc private func didPressTab(_ sender: NSButton) {
    guard let tab = MainSidebarTopTab(rawValue: sender.tag) else { return }
    selectTab(tab, notify: true)
  }
}

private final class MainSidebarTopTabButton: NSButton {
  private let baseColor: NSColor
  private let hoverColor: NSColor
  private let pressedColor: NSColor
  private var trackingArea: NSTrackingArea?

  private var isHovering = false {
    didSet { updateBackground() }
  }

  init(tab: MainSidebarTopTab, baseColor: NSColor, hoverColor: NSColor, pressedColor: NSColor) {
    self.baseColor = baseColor
    self.hoverColor = hoverColor
    self.pressedColor = pressedColor
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = baseColor.cgColor
    setButtonType(.momentaryChange)
    isBordered = false
    bezelStyle = .regularSquare
    imagePosition = .imageOnly
    focusRingType = .none
    toolTip = tab.accessibilityLabel
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

  private func updateBackground() {
    let color: NSColor
    if isHighlighted {
      color = pressedColor
    } else if isHovering {
      color = hoverColor
    } else {
      color = baseColor
    }
    layer?.backgroundColor = color.cgColor
  }
}

private final class MainSidebarSearchFieldView: NSView {
  private static let cornerRadius: CGFloat = 8
  private static let iconSize: CGFloat = 12
  private static let iconLeadingPadding: CGFloat = 8
  private static let textLeadingPadding: CGFloat = 6
  private static let trailingPadding: CGFloat = 8

  let textField: NSTextField = {
    let field = NSTextField()
    field.translatesAutoresizingMaskIntoConstraints = false
    field.placeholderString = "Search"
    field.isBordered = false
    field.isBezeled = false
    field.focusRingType = .none
    field.alignment = .natural
    field.font = NSFont.systemFont(ofSize: 13, weight: .regular)
    field.controlSize = .regular
    field.isEditable = true
    field.isSelectable = true
    field.drawsBackground = false
    field.backgroundColor = .clear
    return field
  }()

  private let iconView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
    view.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    view.contentTintColor = .tertiaryLabelColor
    return view
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = Self.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    addSubview(iconView)
    addSubview(textField)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconLeadingPadding),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.textLeadingPadding),
      textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingPadding),
      textField.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }
}
