import AppKit
import Combine
import InlineKit
import Logger
import Observation

class MainSidebarItemCell: NSView {
  typealias ScrollEvent = MainSidebarList.ScrollEvent

  private var dependencies: AppDependencies?
  private var nav2: Nav2?
  private weak var events: PassthroughSubject<ScrollEvent, Never>?

  private var item: ChatListItem?
  private var onHeaderTap: ((MainSidebarList.Section) -> Void)?

  private static let avatarSize: CGFloat = MainSidebar.iconSize
  private static let avatarSpacing: CGFloat = MainSidebar.iconTrailingPadding
  private static let horizontalPadding: CGFloat = MainSidebar.innerEdgeInsets
  private static let font: NSFont = MainSidebar.font
  private static let headerFont: NSFont = .systemFont(ofSize: 11, weight: .semibold)
  private static let headerTextColor: NSColor = .tertiaryLabelColor
  private static let headerDisclosureSize: CGFloat = 10

  private static let cornerRadius: CGFloat = 10
  private static let unreadBadgeSize: CGFloat = 5
  private static let unreadBadgeCornerRadius: CGFloat = 2.5
  private static let pinnedBadgeSize: CGFloat = 8
  private static let pinnedBadgePointSize: CGFloat = 8
  private static let actionButtonSize: CGFloat = 16
  private static let actionButtonPadding: CGFloat = 3

  private var hoverColor: NSColor {
    .white.withAlphaComponent(0.2)
  }

  private var selectedColor: NSColor {
    Theme.windowContentBackgroundColor
  }

  private var keyboardSelectionColor: NSColor {
    hoverColor
  }

  private var isHovered = false {
    didSet {
      updateAppearance()
    }
  }

  private var isNavSelected = false {
    didSet {
      updateAppearance()
    }
  }

  private var isKeyboardSelected = false {
    didSet {
      updateAppearance()
    }
  }

  private var highlightNavSelection = true

  private var isParentScrolling = false {
    didSet {
      updateTrackingArea()
      isHovered = false
    }
  }

  private var cancellables = Set<AnyCancellable>()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
    setupGestureRecognizers()
    setupTrackingArea()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  lazy var containerView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = Self.cornerRadius
    view.layer?.masksToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  lazy var stackView: NSStackView = {
    let view = NSStackView()
    view.orientation = .horizontal
    view.spacing = 0
    view.alignment = .centerY
    view.distribution = .fill
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var leadingContainerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private var leadingWidthConstraint: NSLayoutConstraint?
  private var leadingHeightConstraint: NSLayoutConstraint?

  lazy var avatarView: ChatIconSwiftUIBridge = {
    let view = ChatIconSwiftUIBridge(
      .user(.deleted),
      size: Self.avatarSize
    )
    view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  lazy var nameLabel: NSTextField = {
    let label = NSTextField()
    label.isEditable = false
    label.isBordered = false
    label.drawsBackground = false
    label.font = Self.font
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var badgeContainerView: NSStackView = {
    let view = NSStackView()
    view.orientation = .horizontal
    view.spacing = 4
    view.alignment = .centerY
    view.distribution = .fill
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentCompressionResistancePriority(.required, for: .horizontal)
    return view
  }()

  private lazy var headerDisclosureView: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    let config = NSImage.SymbolConfiguration(
      pointSize: Self.headerDisclosureSize,
      weight: .semibold,
      scale: .small
    )
    view.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    view.contentTintColor = .tertiaryLabelColor
    return view
  }()

  private lazy var actionButton: NSButton = {
    let button = NSButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = 4
    button.layer?.masksToBounds = true
    button.imagePosition = .imageOnly

    button.widthAnchor.constraint(equalToConstant: Self.actionButtonSize).isActive = true
    button.heightAnchor.constraint(equalToConstant: Self.actionButtonSize).isActive = true
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)

    button.target = self
    button.action = #selector(handleActionButtonClick)
    button.isHidden = true

    return button
  }()

  private func createUnreadBadge() -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = Self.unreadBadgeCornerRadius
    view.layer?.masksToBounds = true
    view.layer?.backgroundColor = NSColor.accent.cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: Self.unreadBadgeSize).isActive = true
    view.heightAnchor.constraint(equalToConstant: Self.unreadBadgeSize).isActive = true
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentHuggingPriority(.required, for: .vertical)
    return view
  }

  private func createPinnedBadge() -> NSImageView {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    let config = NSImage.SymbolConfiguration(
      pointSize: Self.pinnedBadgePointSize,
      weight: .bold,
      scale: .small
    )
    .applying(.init(paletteColors: [.tertiaryLabelColor]))
    view.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    view.widthAnchor.constraint(equalToConstant: Self.pinnedBadgeSize).isActive = true
    view.heightAnchor.constraint(equalToConstant: Self.pinnedBadgeSize).isActive = true
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentHuggingPriority(.required, for: .vertical)
    return view
  }

  private func setup() {
    addSubview(containerView)
    containerView.addSubview(stackView)
    containerView.addSubview(actionButton)
    stackView.addArrangedSubview(leadingContainerView)
    stackView.addArrangedSubview(nameLabel)
    stackView.addArrangedSubview(badgeContainerView)

    leadingWidthConstraint = leadingContainerView.widthAnchor.constraint(equalToConstant: Self.avatarSize)
    leadingHeightConstraint = leadingContainerView.heightAnchor.constraint(equalToConstant: Self.avatarSize)
    leadingWidthConstraint?.isActive = true
    leadingHeightConstraint?.isActive = true

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: Self.horizontalPadding),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Self.horizontalPadding),
      stackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
    ])

    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
      avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
    ])

    NSLayoutConstraint.activate([
      actionButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Self.actionButtonPadding),
      actionButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
    ])

    stackView.setCustomSpacing(Self.avatarSpacing, after: leadingContainerView)
  }

  private var content: MainSidebarItemCollectionViewItem.Content?

  func configure(
    with content: MainSidebarItemCollectionViewItem.Content,
    dependencies: AppDependencies,
    events: PassthroughSubject<ScrollEvent, Never>,
    highlightNavSelection: Bool,
    onHeaderTap: ((MainSidebarList.Section) -> Void)?
  ) {
    preparingForReuse = false
    item = nil
    self.content = content
    switch content.kind {
      case let .item(chatItem):
        item = chatItem
      case .header:
        break
    }
    self.dependencies = dependencies
    nav2 = dependencies.nav2
    self.events = events
    self.highlightNavSelection = highlightNavSelection
    self.onHeaderTap = onHeaderTap

    cancellables.removeAll()

    configureLeadingView(for: content.kind)
    configureTitle(for: content.kind)
    configureBadges(for: content.kind)

    if highlightNavSelection {
      isNavSelected = nav2?.currentRoute == route
    } else {
      isNavSelected = false
    }

    if highlightNavSelection == false {
      isKeyboardSelected = false
    }

    setupEventListeners()
    observeNavRoute()
  }

  private var preparingForReuse = false

  func reset() {
    Log.shared.debug("MainSidebarItemCell preparing for reuse")
    preparingForReuse = true
    isHovered = false
    isNavSelected = false
    isKeyboardSelected = false
    onHeaderTap = nil
    clearBadges()
    cancellables.removeAll()
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let item, let dependencies, item.dialog != nil else { return nil }

    let menu = NSMenu()

    let pinItem = NSMenuItem(
      title: isPinned ? "Unpin" : "Pin",
      action: #selector(handlePinAction),
      keyEquivalent: "p"
    )
    pinItem.target = self
    pinItem.image = NSImage(systemSymbolName: isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
    menu.addItem(pinItem)

    let readUnreadItem = NSMenuItem(
      title: hasUnread ? "Mark as Read" : "Mark as Unread",
      action: #selector(handleReadUnreadAction),
      keyEquivalent: "r"
    )
    readUnreadItem.target = self
    readUnreadItem.image = NSImage(
      systemSymbolName: hasUnread ? "checkmark.message.fill" : "message.badge.filled.fill",
      accessibilityDescription: nil
    )
    menu.addItem(readUnreadItem)

    let archiveItem = NSMenuItem(
      title: isArchived ? "Unarchive" : "Archive",
      action: #selector(handleArchiveAction),
      keyEquivalent: "a"
    )
    archiveItem.target = self
    archiveItem.image = NSImage(
      systemSymbolName: isArchived ? "archivebox" : "archivebox",
      accessibilityDescription: nil
    )
    menu.addItem(archiveItem)

    return menu
  }

  @objc private func handlePinAction() {
    guard let item, let peer = item.peerId else { return }
    Task(priority: .userInitiated) {
      try await DataManager.shared.updateDialog(peerId: peer, pinned: !isPinned, spaceId: item.spaceId)
    }
  }

  @objc private func handleArchiveAction() {
    guard let item, let peer = item.peerId else { return }
    Task(priority: .userInitiated) {
      try await DataManager.shared.updateDialog(peerId: peer, archived: !isArchived, spaceId: item.spaceId)
    }
  }

  @objc private func handleReadUnreadAction() {
    guard let item, let dependencies, let peer = item.peerId else { return }

    Task(priority: .userInitiated) {
      do {
        if hasUnread {
          UnreadManager.shared.readAll(peer, chatId: item.chat?.id ?? 0)
        } else {
          try await dependencies.realtimeV2.send(.markAsUnread(peerId: peer))
        }
      } catch {
        Log.shared.error("Failed to update read/unread status", error: error)
      }
    }
  }

  @objc private func handleActionButtonClick() {
    guard let item, let peer = item.peerId else {
      Log.shared.warning("handleActionButtonClick: item or peer is nil")
      return
    }

    if isArchived {
      // Switch to inbox and navigate first, then unarchive in background
      // This avoids a race condition where the tab switch happens before
      // the view model receives the database update via Combine
      nav2?.navigate(to: .chat(peer: peer))
      NotificationCenter.default.post(name: .switchToInbox, object: nil)
      Task(priority: .userInitiated) {
        try await DataManager.shared.updateDialog(peerId: peer, archived: false, spaceId: item.spaceId)
      }
    } else {
      // Archive the chat
      Task(priority: .userInitiated) {
        try await DataManager.shared.updateDialog(peerId: peer, archived: true, spaceId: item.spaceId)
      }
    }
  }

  private var route: Nav2Route? {
    guard let item, let peer = item.peerId else { return nil }
    return .chat(peer: peer)
  }

  private var hasUnread: Bool {
    guard let dialog = item?.dialog else { return false }
    return (dialog.unreadCount ?? 0) > 0 || (dialog.unreadMark == true)
  }

  private var isPinned: Bool {
    guard let dialog = item?.dialog else { return false }
    return dialog.pinned ?? false
  }

  private var isArchived: Bool {
    guard let dialog = item?.dialog else { return false }
    return dialog.archived ?? false
  }

  private func setupEventListeners() {
    guard let dependencies, let events else { return }

    events.sink { [weak self] event in
      self?.handleScrollEvent(event)
    }
    .store(in: &cancellables)
  }

  private func handleScrollEvent(_ event: ScrollEvent) {
    switch event {
      case .didLiveScroll:
        isParentScrolling = true
      case .didEndLiveScroll:
        isParentScrolling = false
    }
  }

  private func setupTrackingArea() {
    updateTrackingArea()
  }

  private func updateTrackingArea() {
    trackingAreas.forEach { removeTrackingArea($0) }

    if isParentScrolling {
      return
    }

    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    updateTrackingArea()
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
  }

  private func setupGestureRecognizers() {
    let tapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    addGestureRecognizer(tapGesture)
  }

  private func configureLeadingView(for kind: MainSidebarItemCollectionViewItem.Content.Kind) {
    leadingContainerView.subviews.forEach { $0.removeFromSuperview() }

    switch kind {
      case let .item(chatItem):
        leadingContainerView.isHidden = false
        leadingWidthConstraint?.constant = Self.avatarSize
        leadingHeightConstraint?.constant = Self.avatarSize
        if let user = chatItem.user {
          avatarView = ChatIconSwiftUIBridge(.user(user), size: Self.avatarSize)
        } else if let chat = chatItem.chat {
          avatarView = ChatIconSwiftUIBridge(.chat(chat), size: Self.avatarSize)
        } else {
          avatarView = ChatIconSwiftUIBridge(.user(.deleted), size: Self.avatarSize)
        }
        leadingContainerView.addSubview(avatarView)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          avatarView.centerXAnchor.constraint(equalTo: leadingContainerView.centerXAnchor),
          avatarView.centerYAnchor.constraint(equalTo: leadingContainerView.centerYAnchor),
          avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
          avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
        ])
        stackView.setCustomSpacing(Self.avatarSpacing, after: leadingContainerView)
      case .header:
        leadingContainerView.isHidden = true
        leadingWidthConstraint?.constant = 0
        leadingHeightConstraint?.constant = 0
        stackView.setCustomSpacing(0, after: leadingContainerView)
    }
  }

  private func configureTitle(for kind: MainSidebarItemCollectionViewItem.Content.Kind) {
    nameLabel.stringValue = title(for: kind)
    updateHeaderStyle(for: kind)
  }

  private func title(for kind: MainSidebarItemCollectionViewItem.Content.Kind) -> String {
    switch kind {
      case let .item(chatItem):
        title(for: chatItem)
      case let .header(_, title, _, _, _):
        title
    }
  }

  private func title(for chatItem: ChatListItem) -> String {
    if let user = chatItem.user {
      return userTitle(for: user.user)
    }
    if let chatTitle = nonEmpty(chatItem.chat?.title) {
      return chatTitle
    }
    return "Chat"
  }

  private func userTitle(for user: User) -> String {
    if let displayName = nonEmpty(user.displayName) {
      return displayName
    }
    if let username = nonEmpty(user.username) {
      return username
    }
    if let email = nonEmpty(user.email) {
      return email
    }
    if let phoneNumber = nonEmpty(user.phoneNumber) {
      return phoneNumber
    }
    return "User"
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func configureBadges(for kind: MainSidebarItemCollectionViewItem.Content.Kind) {
    clearBadges()
    switch kind {
      case .item:
        guard item?.kind == .thread else { return }
        if hasUnread {
          badgeContainerView.addArrangedSubview(createUnreadBadge())
        } else if isPinned {
          badgeContainerView.addArrangedSubview(createPinnedBadge())
        }
      case let .header(_, _, _, showsDisclosure, isCollapsed):
        if showsDisclosure {
          let symbolName = isCollapsed ? "chevron.right" : "chevron.down"
          let config = NSImage.SymbolConfiguration(
            pointSize: Self.headerDisclosureSize,
            weight: .semibold,
            scale: .small
          )
          headerDisclosureView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
          badgeContainerView.addArrangedSubview(headerDisclosureView)
        }
    }
  }

  private func clearBadges() {
    badgeContainerView.arrangedSubviews.forEach { badge in
      badge.removeFromSuperview()
    }
  }

  private func updateAppearance() {
    updateLayer()
    updateActionButtonVisibility()
  }

  private func updateActionButtonVisibility() {
    let shouldShow = isHovered && item != nil
    actionButton.isHidden = !shouldShow
    if shouldShow {
      updateActionButtonAppearance()
    }
  }

  private func updateActionButtonAppearance() {
    let symbolName: String
    let accessibilityLabel: String

    if isArchived {
      symbolName = "chevron.right"
      accessibilityLabel = "Open"
    } else {
      symbolName = "xmark"
      accessibilityLabel = "Archive"
    }

    let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
      .applying(.init(paletteColors: [.secondaryLabelColor]))
    actionButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
      .withSymbolConfiguration(config)
  }

  override func updateLayer() {
    containerView.effectiveAppearance.performAsCurrentDrawingAppearance {
      let backgroundColor: NSColor
      if isHeader {
        backgroundColor = .clear
      } else if isNavSelected {
        backgroundColor = selectedColor
      } else if isKeyboardSelected {
        backgroundColor = keyboardSelectionColor
      } else if isHovered {
        backgroundColor = hoverColor
      } else {
        backgroundColor = .clear
      }

      containerView.layer?.backgroundColor = backgroundColor.cgColor
    }
    super.updateLayer()
  }

  @objc private func handleTap(_ gesture: NSClickGestureRecognizer) {
    let location = gesture.location(in: containerView)
    if !actionButton.isHidden, actionButton.frame.contains(location) {
      Log.shared.debug("handleTap: button click detected at \(location), button frame: \(actionButton.frame)")
      handleActionButtonClick()
      return
    }

    guard let content else { return }

    switch content.kind {
      case let .item(item):
        guard let nav2, let peer = item.peerId else { return }
        nav2.navigate(to: .chat(peer: peer))
      case let .header(section, _, _, showsDisclosure, _):
        guard showsDisclosure else { return }
        onHeaderTap?(section)
    }
  }

  private func observeNavRoute() {
    guard let nav2 else { return }

    withObservationTracking { [weak self] in
      _ = nav2.currentRoute
      guard let self else { return }
      if highlightNavSelection {
        isNavSelected = nav2.currentRoute == route
      } else {
        isNavSelected = false
      }
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observeNavRoute()
      }
    }
  }

  func setListSelected(_ selected: Bool) {
    guard highlightNavSelection == false else { return }
    isKeyboardSelected = selected
  }

  private var isHeader: Bool {
    if let content, case .header = content.kind {
      return true
    }
    return false
  }

  private func updateHeaderStyle(for kind: MainSidebarItemCollectionViewItem.Content.Kind) {
    switch kind {
      case .item:
        nameLabel.font = Self.font
        nameLabel.textColor = .labelColor
      case .header:
        nameLabel.font = Self.headerFont
        nameLabel.textColor = Self.headerTextColor
    }
  }
}
