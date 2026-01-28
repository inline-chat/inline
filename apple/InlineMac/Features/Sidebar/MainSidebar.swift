import AppKit
import InlineKit
import SwiftUI

class MainSidebar: NSViewController, NSMenuDelegate {
  private let dependencies: AppDependencies
  private let listView: MainSidebarList
  private let homeViewModel: HomeViewModel
  private let spacePickerState = SpacePickerState()

  private var activeMode: MainSidebarMode = .inbox

  // MARK: - Sizes

  // Used in header, collection view item, and collection view layout.

  static let iconSize: CGFloat = 24
  static let itemHeight: CGFloat = 34
  static let iconTrailingPadding: CGFloat = 8
  static let fontSize: CGFloat = 14
  static let fontWeight: NSFont.Weight = .regular
  static let font: NSFont = .systemFont(ofSize: fontSize, weight: fontWeight)
  static let itemSpacing: CGFloat = 0
  static let outerEdgeInsets: CGFloat = 10
  static let innerEdgeInsets: CGFloat = 8
  static let edgeInsets: CGFloat = MainSidebar.outerEdgeInsets + MainSidebar.innerEdgeInsets

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    homeViewModel = HomeViewModel(db: dependencies.database)
    listView = MainSidebarList(dependencies: dependencies)

    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Header
  private lazy var headerView: MainSidebarHeaderView = {
    let view = MainSidebarHeaderView(
      dependencies: dependencies,
      spacePickerState: spacePickerState
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    // Space picker overlay is hosted in MainSidebar so it can render above the list.
    view.onSpacePickerChange = { [weak self] isVisible in
      self?.updateSpacePicker(isVisible: isVisible)
    }
    return view
  }()

  private static let spacePickerWidth: CGFloat = 240

  private var spacePickerWindow: SpacePickerOverlayWindow?
  private var spacePickerClickMonitor: Any?
  private var spacePickerEscapeUnsubscriber: (() -> Void)?

  private lazy var footerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var leftFooterStack: NSStackView = {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var rightFooterStack: NSStackView = {
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.alignment = .centerY
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var archiveButton: MainSidebarArchiveButton = {
    let button = MainSidebarArchiveButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = #selector(handleArchiveButton)
    return button
  }()

  private lazy var searchButton: MainSidebarFooterIconButton = {
    let button = MainSidebarFooterIconButton(
      symbolName: "magnifyingglass",
      accessibilityLabel: "Search"
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = #selector(handleSearchButton)
    button.toolTip = "Search"
    return button
  }()

  private lazy var plusButton: MainSidebarFooterIconButton = {
    let button = MainSidebarFooterIconButton(
      symbolName: "plus",
      accessibilityLabel: "New"
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = #selector(handlePlusButton)
    button.toolTip = "New"
    return button
  }()

  private lazy var notificationsButton: MainSidebarFooterHostingButton = {
    let hostingView = NSHostingView(
      rootView: AnyView(
        NotificationSettingsButton()
          .environmentObject(dependencies.userSettings.notification)
      )
    )
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    let container = MainSidebarFooterHostingButton(contentView: hostingView)
    container.translatesAutoresizingMaskIntoConstraints = false
    return container
  }()

  private lazy var viewOptionsButton: MainSidebarFooterIconButton = {
    let button = MainSidebarFooterIconButton(
      symbolName: "line.3.horizontal.decrease",
      accessibilityLabel: "View options"
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = #selector(handleViewOptionsButton)
    button.toolTip = "View options"
    return button
  }()

  private lazy var newSpaceMenuItem: NSMenuItem = {
    let item = NSMenuItem(
      title: "New Space",
      action: #selector(handleNewSpace),
      keyEquivalent: ""
    )
    item.target = self
    item.image = menuIcon(named: "plus")
    return item
  }()

  private lazy var inviteMenuItem: NSMenuItem = {
    let item = NSMenuItem(
      title: "Invite",
      action: #selector(handleInvite),
      keyEquivalent: ""
    )
    item.target = self
    item.image = menuIcon(named: "person.badge.plus")
    return item
  }()

  private lazy var newThreadMenuItem: NSMenuItem = {
    let item = NSMenuItem(
      title: "New Thread",
      action: #selector(handleNewThread),
      keyEquivalent: ""
    )
    item.target = self
    item.image = menuIcon(named: "bubble.left.and.bubble.right")
    return item
  }()

  private lazy var plusMenu: NSMenu = {
    let menu = NSMenu()
    menu.items = [newSpaceMenuItem, inviteMenuItem, newThreadMenuItem]
    return menu
  }()

  private lazy var sortHeaderMenuItem: NSMenuItem = {
    let item = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }()

  private lazy var sortByLastActivityMenuItem: NSMenuItem = {
    let item = NSMenuItem(
      title: "Last activity",
      action: #selector(handleSortByLastActivity),
      keyEquivalent: ""
    )
    item.target = self
    return item
  }()

  private lazy var sortByCreationDateMenuItem: NSMenuItem = {
    let item = NSMenuItem(
      title: "Creation date",
      action: #selector(handleSortByCreationDate),
      keyEquivalent: ""
    )
    item.target = self
    return item
  }()

  private lazy var displayModeHeaderMenuItem: NSMenuItem = {
    let item = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }()

  private lazy var displayModeCompactMenuItem: NSMenuItem = {
    let item = NSMenuItem(
      title: "Compact",
      action: #selector(handleDisplayModeCompact),
      keyEquivalent: ""
    )
    item.target = self
    item.image = menuIcon(named: "rectangle.compress.vertical")
    item.attributedTitle = displayModeTitle(
      title: "Compact",
      subtitle: "Single line, smaller avatars"
    )
    return item
  }()

  private lazy var displayModePreviewMenuItem: NSMenuItem = {
    let item = NSMenuItem(
      title: "Show previews",
      action: #selector(handleDisplayModePreview),
      keyEquivalent: ""
    )
    item.target = self
    item.image = menuIcon(named: "rectangle.expand.vertical")
    item.attributedTitle = displayModeTitle(
      title: "Show previews",
      subtitle: "Preview line, larger avatars"
    )
    return item
  }()

  private lazy var viewOptionsMenu: NSMenu = {
    let menu = NSMenu()
    menu.delegate = self
    menu.items = [
      // sortHeaderMenuItem,
      // sortByLastActivityMenuItem,
      // sortByCreationDateMenuItem,
      // .separator(),
      displayModeHeaderMenuItem,
      displayModeCompactMenuItem,
      displayModePreviewMenuItem,
    ]
    return menu
  }()

  private lazy var archiveEmptyView: NSStackView = {
    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
    let symbolImage = NSImage(
      systemSymbolName: "archivebox",
      accessibilityDescription: "Archive"
    )?.withSymbolConfiguration(symbolConfiguration)

    let symbolView = NSImageView()
    symbolView.image = symbolImage
    symbolView.contentTintColor = .tertiaryLabelColor
    symbolView.imageScaling = .scaleProportionallyDown

    let titleLabel = NSTextField(labelWithString: "Your archive is empty")
    titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.alignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail

    let descriptionLabel = NSTextField(
      labelWithString: "Archived chats appear here and return to your main list when they get new messages."
    )
    descriptionLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
    descriptionLabel.textColor = .secondaryLabelColor
    descriptionLabel.alignment = .center
    descriptionLabel.lineBreakMode = .byWordWrapping

    let stack = NSStackView(views: [symbolView, titleLabel, descriptionLabel])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var archiveTitleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "Archived Chats")
    label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.usesSingleLineMode = true
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isHidden = true
    return label
  }()

  private var headerTopConstraint: NSLayoutConstraint?
  private var archiveTitleHeightConstraint: NSLayoutConstraint?
  private var archiveTitleTopConstraint: NSLayoutConstraint?
  private var archiveTitleBottomConstraint: NSLayoutConstraint?
  private var switchToInboxObserver: NSObjectProtocol?
  private static let footerHeight: CGFloat = MainSidebarFooterStyle.buttonSize + 16
  private static let archiveTitleHeight: CGFloat = 16
  private static let archiveTitleTopSpacing: CGFloat = 12
  private static let archiveTitleBottomSpacing: CGFloat = 4

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    setupViews()
  }

  private func setupViews() {
    view.addSubview(headerView)
    view.addSubview(archiveTitleLabel)
    view.addSubview(listView)
    view.addSubview(footerView)
    footerView.addSubview(leftFooterStack)
    footerView.addSubview(plusButton)
    footerView.addSubview(rightFooterStack)
    view.addSubview(archiveEmptyView)

    leftFooterStack.addArrangedSubview(archiveButton)
    leftFooterStack.addArrangedSubview(searchButton)
    rightFooterStack.addArrangedSubview(viewOptionsButton)
    rightFooterStack.addArrangedSubview(notificationsButton)

    headerTopConstraint = headerView.topAnchor.constraint(equalTo: view.topAnchor, constant: headerTopInset())

    let archiveTitleTopConstraint = archiveTitleLabel.topAnchor.constraint(
      equalTo: headerView.bottomAnchor,
      constant: Self.archiveTitleTopSpacing
    )
    self.archiveTitleTopConstraint = archiveTitleTopConstraint

    NSLayoutConstraint.activate([
      headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.outerEdgeInsets),
      headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.outerEdgeInsets),
      headerTopConstraint!,

      archiveTitleLabel.leadingAnchor.constraint(
        equalTo: view.leadingAnchor,
        constant: Self.outerEdgeInsets + Self.innerEdgeInsets
      ),
      archiveTitleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor,
        constant: -Self.outerEdgeInsets
      ),
      archiveTitleTopConstraint,

      listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      listView.bottomAnchor.constraint(equalTo: footerView.topAnchor, constant: -8),

      footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      footerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      footerView.heightAnchor.constraint(equalToConstant: Self.footerHeight),

      leftFooterStack.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: Self.edgeInsets),
      leftFooterStack.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

      archiveButton.widthAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      archiveButton.heightAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      searchButton.widthAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      searchButton.heightAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),

      plusButton.centerXAnchor.constraint(equalTo: footerView.centerXAnchor),
      plusButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
      plusButton.widthAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      plusButton.heightAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),

      rightFooterStack.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -Self.edgeInsets),
      rightFooterStack.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),

      viewOptionsButton.widthAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      viewOptionsButton.heightAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      notificationsButton.widthAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      notificationsButton.heightAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),

      archiveEmptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      archiveEmptyView.centerYAnchor.constraint(equalTo: listView.centerYAnchor),
      archiveEmptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      archiveEmptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])

    let archiveTitleHeightConstraint = archiveTitleLabel.heightAnchor.constraint(equalToConstant: 0)
    let archiveTitleBottomConstraint = listView.topAnchor.constraint(
      equalTo: archiveTitleLabel.bottomAnchor,
      constant: 0
    )
    archiveTitleHeightConstraint.isActive = true
    archiveTitleBottomConstraint.isActive = true
    self.archiveTitleHeightConstraint = archiveTitleHeightConstraint
    self.archiveTitleBottomConstraint = archiveTitleBottomConstraint

    archiveEmptyView.isHidden = true

    listView.onChatCountChanged = { [weak self] mode, count in
      guard let self else { return }
      let isArchiveEmpty = mode == .archive && count == 0
      archiveEmptyView.isHidden = !isArchiveEmpty
      updateArchiveTitle(archiveCount: count)
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
        let archiveCount = listView.lastChatItemCount
        archiveEmptyView.isHidden = archiveCount != 0
        updateArchiveTitle(archiveCount: archiveCount)
      case .inbox:
        listView.setMode(.inbox)
        archiveEmptyView.isHidden = true
        updateArchiveTitle(archiveCount: 0)
    }
  }

  private func updateArchiveButton() {
    archiveButton.isActive = activeMode == .archive
    archiveButton.toolTip = activeMode == .archive ? "Show inbox" : "Show archives"
  }

  private func updateArchiveTitle(archiveCount: Int) {
    let shouldShow = activeMode == .archive && archiveCount > 0
    archiveTitleLabel.isHidden = !shouldShow
    archiveTitleTopConstraint?.constant = shouldShow ? Self.archiveTitleTopSpacing : 0
    archiveTitleHeightConstraint?.constant = shouldShow ? Self.archiveTitleHeight : 0
    archiveTitleBottomConstraint?.constant = shouldShow ? Self.archiveTitleBottomSpacing : 0
  }

  @objc private func handleArchiveButton() {
    let nextMode: MainSidebarMode = activeMode == .archive ? .inbox : .archive
    setContent(for: nextMode)
  }

  @objc private func handlePlusButton(_ sender: NSButton) {
    let point = NSPoint(x: 0, y: sender.bounds.maxY + 6)
    plusMenu.popUp(positioning: nil, at: point, in: sender)
  }

  @objc private func handleSearchButton() {
    NotificationCenter.default.post(name: .focusSearch, object: nil)
  }

  private func updateSpacePicker(isVisible: Bool) {
    if isVisible {
      showSpacePicker()
    } else {
      hideSpacePicker()
    }
  }

  private func showSpacePicker() {
    guard let parentWindow = view.window else { return }
    let window = ensureSpacePickerWindow()

    if window.parent != parentWindow {
      parentWindow.addChildWindow(window, ordered: .above)
    }

    let headerRectInWindow = headerView.convert(headerView.bounds, to: nil)
    let headerRectInScreen = parentWindow.convertToScreen(headerRectInWindow)
    let size = window.frame.size
    let insetX = SpacePickerOverlayWindow.contentInsetX
    let insetY = SpacePickerOverlayWindow.contentInsetY
    var origin = NSPoint(
      x: headerRectInScreen.minX - insetX,
      y: headerRectInScreen.minY - size.height - 6 + insetY
    )

    if let screen = parentWindow.screen {
      let visible = screen.visibleFrame
      let maxX = visible.maxX - size.width
      origin.x = min(max(origin.x, visible.minX), maxX)
      if origin.y < visible.minY {
        origin.y = visible.minY
      }
    }

    window.setFrameOrigin(origin)
    window.orderFront(nil)
    installSpacePickerClickMonitor()
    installSpacePickerKeyHandlers()
  }

  private func hideSpacePicker() {
    if let window = spacePickerWindow {
      window.orderOut(nil)
      window.parent?.removeChildWindow(window)
    }
    if spacePickerState.isVisible {
      spacePickerState.isVisible = false
    }
    removeSpacePickerClickMonitor()
    removeSpacePickerKeyHandlers()
  }

  private func ensureSpacePickerWindow() -> SpacePickerOverlayWindow {
    let items = spacePickerItems()
    let activeTab = dependencies.nav2?.activeTab ?? .home
    let rootView = SpacePickerOverlayView(
      items: items,
      activeTab: activeTab,
      onSelect: { [weak self] item in
        self?.handleSpacePickerSelection(item)
        self?.hideSpacePicker()
      },
      onCreateSpace: { [weak self] in
        self?.dependencies.nav2?.navigate(to: .createSpace)
        self?.hideSpacePicker()
      }
    )

    if let window = spacePickerWindow {
      window.update(rootView: rootView)
      return window
    }

    let window = SpacePickerOverlayWindow(rootView: rootView, preferredWidth: Self.spacePickerWidth)
    spacePickerWindow = window
    return window
  }

  private func spacePickerItems() -> [SpaceHeaderItem] {
    [.home] + homeViewModel.spaces.map { SpaceHeaderItem(space: $0.space) }
  }

  private func handleSpacePickerSelection(_ item: SpaceHeaderItem) {
    guard let nav2 = dependencies.nav2 else { return }
    switch item.kind {
      case .home:
        if let index = nav2.tabs.firstIndex(of: .home) {
          nav2.setActiveTab(index: index)
        }
      case .space:
        if let space = item.space {
          nav2.openSpace(space)
        }
    }
  }

  private func installSpacePickerClickMonitor() {
    guard spacePickerClickMonitor == nil else { return }
    spacePickerClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
      guard let self else { return event }
      guard let window = spacePickerWindow, window.isVisible else { return event }
      if let parentWindow = view.window, event.window === parentWindow {
        let pointInHeader = headerView.convert(event.locationInWindow, from: nil)
        if headerView.bounds.contains(pointInHeader) {
          return event
        }
      }
      if event.window !== window {
        hideSpacePicker()
      }
      return event
    }
  }

  private func removeSpacePickerClickMonitor() {
    if let spacePickerClickMonitor {
      NSEvent.removeMonitor(spacePickerClickMonitor)
      self.spacePickerClickMonitor = nil
    }
  }

  private func installSpacePickerKeyHandlers() {
    guard spacePickerEscapeUnsubscriber == nil else { return }
    guard let keyMonitor = dependencies.keyMonitor else { return }
    spacePickerEscapeUnsubscriber = keyMonitor.addHandler(
      for: .escape,
      key: "space_picker_escape"
    ) { [weak self] _ in
      self?.hideSpacePicker()
    }
  }

  private func removeSpacePickerKeyHandlers() {
    spacePickerEscapeUnsubscriber?()
    spacePickerEscapeUnsubscriber = nil
  }

  @objc private func handleViewOptionsButton(_ sender: NSButton) {
    updateViewOptionsMenuState()
    let point = NSPoint(x: 0, y: sender.bounds.maxY + 6)
    viewOptionsMenu.popUp(positioning: nil, at: point, in: sender)
  }

  @objc private func handleSortByLastActivity() {
    listView.setSortStrategy(.lastActivity)
    updateViewOptionsMenuState()
  }

  @objc private func handleSortByCreationDate() {
    listView.setSortStrategy(.creationDate)
    updateViewOptionsMenuState()
  }

  @objc private func handleDisplayModeCompact() {
    AppSettings.shared.showSidebarMessagePreview = false
    updateViewOptionsMenuState()
  }

  @objc private func handleDisplayModePreview() {
    AppSettings.shared.showSidebarMessagePreview = true
    updateViewOptionsMenuState()
  }

  @objc private func handleNewSpace() {
    dependencies.nav2?.navigate(to: .createSpace)
  }

  @objc private func handleInvite() {
    dependencies.nav2?.navigate(to: .inviteToSpace)
  }

  @objc private func handleNewThread() {
    dependencies.nav2?.navigate(to: .newChat)
  }

  private func updateViewOptionsMenuState() {
    // let currentSort = listView.currentSortStrategy
    // sortByLastActivityMenuItem.state = currentSort == .lastActivity ? .on : .off
    // sortByCreationDateMenuItem.state = currentSort == .creationDate ? .on : .off
    let showPreview = AppSettings.shared.showSidebarMessagePreview
    displayModeCompactMenuItem.state = showPreview ? .off : .on
    displayModePreviewMenuItem.state = showPreview ? .on : .off
  }

  func menuWillOpen(_ menu: NSMenu) {
    guard menu == viewOptionsMenu else { return }
    updateViewOptionsMenuState()
  }

  private func displayModeTitle(title: String, subtitle: String) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.lineSpacing = 0

    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .regular),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraph,
    ]
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]

    let combined = NSMutableAttributedString(string: title, attributes: titleAttributes)
    combined.append(NSAttributedString(string: "\n\(subtitle)", attributes: subtitleAttributes))
    return combined
  }

  private func menuIcon(named symbolName: String) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
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

private enum MainSidebarFooterStyle {
  static let buttonSize: CGFloat = 24
  static let cornerRadius: CGFloat = 8
  static let iconSize: CGFloat = 15
  static let hoverColor = NSColor.black.withAlphaComponent(0.08)
  static let pressedColor = NSColor.black.withAlphaComponent(0.12)
}

private final class MainSidebarArchiveButton: NSButton {
  private static let cornerRadius: CGFloat = MainSidebarFooterStyle.cornerRadius
  private static let iconSize: CGFloat = MainSidebarFooterStyle.iconSize
  private static let hoverColor = MainSidebarFooterStyle.hoverColor
  private static let pressedColor = MainSidebarFooterStyle.pressedColor
  private static let activeTint = NSColor.controlAccentColor
  private static let inactiveTint = NSColor.tertiaryLabelColor

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
    let color: NSColor = if isHighlighted {
      Self.pressedColor
    } else if isHovering {
      Self.hoverColor
    } else {
      .clear
    }
    layer?.backgroundColor = color.cgColor
  }

  override func accessibilityLabel() -> String? {
    "Archive"
  }
}

private final class MainSidebarFooterIconButton: NSButton {
  private static let cornerRadius: CGFloat = MainSidebarFooterStyle.cornerRadius
  private static let iconSize: CGFloat = MainSidebarFooterStyle.iconSize
  private static let hoverColor = MainSidebarFooterStyle.hoverColor
  private static let pressedColor = MainSidebarFooterStyle.pressedColor
  private static let tint = NSColor.tertiaryLabelColor

  private var trackingArea: NSTrackingArea?
  private let symbolName: String
  private let labelText: String

  private var isHovering = false {
    didSet { updateBackground() }
  }

  init(symbolName: String, accessibilityLabel: String) {
    self.symbolName = symbolName
    labelText = accessibilityLabel
    super.init(frame: .zero)
    setup()
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
    let config = NSImage.SymbolConfiguration(pointSize: Self.iconSize, weight: .semibold)
    image = NSImage(systemSymbolName: symbolName, accessibilityDescription: labelText)?
      .withSymbolConfiguration(config)
    contentTintColor = Self.tint
    updateBackground()
  }

  override func accessibilityLabel() -> String? {
    labelText
  }

  private func updateBackground() {
    let color: NSColor = if isHighlighted {
      Self.pressedColor
    } else if isHovering {
      Self.hoverColor
    } else {
      .clear
    }
    layer?.backgroundColor = color.cgColor
  }
}

private final class MainSidebarFooterHostingButton: NSView {
  private var trackingArea: NSTrackingArea?
  private var mouseMonitor: Any?
  private let contentView: NSView

  private var isHovering = false {
    didSet { updateBackground() }
  }

  private var isPressed = false {
    didSet { updateBackground() }
  }

  init(contentView: NSView) {
    self.contentView = contentView
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      removeMouseMonitor()
    } else if mouseMonitor == nil {
      installMouseMonitor()
    }
  }

  deinit {
    removeMouseMonitor()
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = MainSidebarFooterStyle.cornerRadius
    layer?.cornerCurve = .continuous
    addSubview(contentView)

    NSLayoutConstraint.activate([
      contentView.centerXAnchor.constraint(equalTo: centerXAnchor),
      contentView.centerYAnchor.constraint(equalTo: centerYAnchor),
      contentView.widthAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
      contentView.heightAnchor.constraint(equalToConstant: MainSidebarFooterStyle.buttonSize),
    ])

    updateBackground()
  }

  private func installMouseMonitor() {
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      guard let self else { return event }
      let location = convert(event.locationInWindow, from: nil)
      let containsPoint = bounds.contains(location)
      switch event.type {
        case .leftMouseDown:
          if containsPoint {
            isPressed = true
          }
        case .leftMouseUp:
          isPressed = false
        default:
          break
      }
      return event
    }
  }

  private func removeMouseMonitor() {
    if let mouseMonitor {
      NSEvent.removeMonitor(mouseMonitor)
      self.mouseMonitor = nil
    }
  }

  private func updateBackground() {
    let color: NSColor = if isPressed {
      MainSidebarFooterStyle.pressedColor
    } else if isHovering {
      MainSidebarFooterStyle.hoverColor
    } else {
      .clear
    }
    layer?.backgroundColor = color.cgColor
  }
}
