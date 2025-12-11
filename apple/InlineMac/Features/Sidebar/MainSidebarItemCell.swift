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

  private var item: HomeChatItem?

  private static let height: CGFloat = MainSidebar.iconSize
  private static let avatarSize: CGFloat = MainSidebar.iconSize
  private static let avatarSpacing: CGFloat = MainSidebar.iconTrailingPadding
  private static let horizontalPadding: CGFloat = MainSidebar.innerEdgeInsets
  private static let font: NSFont = MainSidebar.font

  private static let cornerRadius: CGFloat = 10
  private static let unreadBadgeSize: CGFloat = 5
  private static let unreadBadgeCornerRadius: CGFloat = 2.5
  private static let pinnedBadgeSize: CGFloat = 8
  private static let pinnedBadgePointSize: CGFloat = 8

  private var hoverColor: NSColor {
    .gray.withAlphaComponent(Self.backgroundOpacity)
  }

  private var selectedColor: NSColor {
    NSColor.labelColor.withAlphaComponent(Self.backgroundOpacity)
  }

  private var isHovered = false {
    didSet {
      updateAppearance()
    }
  }

  private var isSelected = false {
    didSet {
      updateAppearance()
    }
  }

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
    label.font = .systemFont(ofSize: Self.fontSize, weight: .regular)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
  }()

  private var badgeView: NSView?

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
    stackView.addArrangedSubview(avatarView)
    stackView.addArrangedSubview(nameLabel)

    heightAnchor.constraint(equalToConstant: Self.height).isActive = true

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

    stackView.setCustomSpacing(Self.avatarSpacing, after: avatarView)
  }

  struct Content {
    enum Kind {
      case chat(HomeChatItem)
      case member(Member, UserInfo?)
      case header(title: String, symbol: String)
    }

    let kind: Kind
  }

  func configure(
    with content: MainSidebarItemCollectionViewItem.Content,
    dependencies: AppDependencies,
    events: PassthroughSubject<ScrollEvent, Never>
  ) {
    preparingForReuse = false
    item = nil
    switch content.kind {
      case let .chat(chatItem):
        item = chatItem
      case .member, .header:
        break
    }
    self.dependencies = dependencies
    nav2 = dependencies.nav2
    self.events = events

    cancellables.removeAll()

    configureLeadingView(for: content.kind)
    nameLabel.stringValue = title(for: content.kind)

    let hasUnread: Bool
    let isPinned: Bool

    switch content.kind {
      case let .chat(chatItem):
        hasUnread = (chatItem.dialog.unreadCount ?? 0) > 0 || (chatItem.dialog.unreadMark == true)
        isPinned = chatItem.dialog.pinned ?? false
      case .member, .header:
        hasUnread = false
        isPinned = false
    }

    badgeView?.removeFromSuperview()
    badgeView = nil

    if hasUnread {
      badgeView = createUnreadBadge()
      stackView.addArrangedSubview(badgeView!)
    } else if isPinned {
      badgeView = createPinnedBadge()
      stackView.addArrangedSubview(badgeView!)
    }

    isSelected = nav2?.currentRoute == route

    setupEventListeners()
    observeNavRoute()
  }

  private var preparingForReuse = false

  func reset() {
    Log.shared.debug("MainSidebarItemCell preparing for reuse")
    preparingForReuse = true
    isHovered = false
    isSelected = false
    cancellables.removeAll()
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let item, let dependencies else { return nil }

    let menu = NSMenu()

    let isPinned = item.dialog.pinned ?? false
    let pinItem = NSMenuItem(
      title: isPinned ? "Unpin" : "Pin",
      action: #selector(handlePinAction),
      keyEquivalent: "p"
    )
    pinItem.target = self
    pinItem.image = NSImage(systemSymbolName: isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
    menu.addItem(pinItem)

    let hasUnread = (item.dialog.unreadCount ?? 0) > 0 || (item.dialog.unreadMark == true)
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

    let isArchived = item.dialog.archived ?? false
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
    guard let item else { return }
    let isPinned = item.dialog.pinned ?? false
    Task(priority: .userInitiated) {
      try await DataManager.shared.updateDialog(peerId: item.peerId, pinned: !isPinned)
    }
  }

  @objc private func handleArchiveAction() {
    guard let item else { return }
    let isArchived = item.dialog.archived ?? false
    Task(priority: .userInitiated) {
      try await DataManager.shared.updateDialog(peerId: item.peerId, archived: !isArchived)
    }
  }

  @objc private func handleReadUnreadAction() {
    guard let item, let dependencies else { return }
    let hasUnread = (item.dialog.unreadCount ?? 0) > 0 || (item.dialog.unreadMark == true)

    Task(priority: .userInitiated) {
      do {
        if hasUnread {
          UnreadManager.shared.readAll(item.peerId, chatId: item.chat?.id ?? 0)
        } else {
          try await dependencies.realtimeV2.send(.markAsUnread(peerId: item.peerId))
        }
      } catch {
        Log.shared.error("Failed to update read/unread status", error: error)
      }
    }
  }

  private var route: Nav2Route? {
    guard let item else { return nil }
    return .chat(peer: item.peerId)
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
    let tapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
  }

  private func configureLeadingView(for kind: MainSidebarItemCollectionViewItem.Content.Kind) {
    // Remove current leading view
    stackView.arrangedSubviews.first?.removeFromSuperview()

    switch kind {
      case let .chat(chatItem):
        if let user = chatItem.user {
          avatarView = ChatIconSwiftUIBridge(.user(user), size: Self.avatarSize)
        } else if let chat = chatItem.chat {
          avatarView = ChatIconSwiftUIBridge(.chat(chat), size: Self.avatarSize)
        } else {
          avatarView = ChatIconSwiftUIBridge(.user(.deleted), size: Self.avatarSize)
        }
        stackView.insertArrangedSubview(avatarView, at: 0)
        stackView.setCustomSpacing(Self.avatarSpacing, after: avatarView)
        avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
      case let .member(_, userInfo):
        if let user = userInfo {
          avatarView = ChatIconSwiftUIBridge(.user(user), size: Self.avatarSize)
        } else {
          avatarView = ChatIconSwiftUIBridge(.user(.deleted), size: Self.avatarSize)
        }
        stackView.insertArrangedSubview(avatarView, at: 0)
        stackView.setCustomSpacing(Self.avatarSpacing, after: avatarView)
        avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
      case let .header(title: _, symbol: symbol):
        let iconView = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
          .applying(.init(paletteColors: [.secondaryLabelColor]))
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
          .withSymbolConfiguration(config)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        stackView.insertArrangedSubview(iconView, at: 0)
        stackView.setCustomSpacing(Self.avatarSpacing, after: iconView)
        iconView.widthAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: Self.avatarSize).isActive = true
        avatarView = ChatIconSwiftUIBridge(.user(.deleted), size: Self.avatarSize) // placeholder for reuse safety
    }
  }

  private func title(for kind: MainSidebarItemCollectionViewItem.Content.Kind) -> String {
    switch kind {
      case let .chat(chatItem):
        chatItem.user?.user.firstName ??
          chatItem.user?.user.lastName ??
          chatItem.user?.user.username ??
          chatItem.chat?.title ??
          chatItem.space?.displayName ??
          "Chat"
      case let .member(_, user):
        user?.user.firstName ??
          user?.user.lastName ??
          user?.user.username ??
          "Member"
      case let .header(title, _):
        title
    }
  }

  private func updateAppearance() {
    let color = isSelected ? selectedColor : isHovered ? hoverColor : .clear

    if preparingForReuse {
      containerView.layer?.backgroundColor = color.cgColor
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = isHovered || isSelected ? Self.animationDurationFast : Self.animationDurationSlow
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        containerView.layer?.backgroundColor = color.cgColor
      }
    }
  }

  @objc private func handleTap() {
    guard let dependencies, let item else { return }

    if let nav2 {
      nav2.navigate(to: .chat(peer: item.peerId))
    } else {
      // Fallback to legacy nav
      dependencies.nav.open(.chat(peer: item.peerId))
    }
  }

  private func observeNavRoute() {
    guard let nav2 else { return }

    withObservationTracking { [weak self] in
      _ = nav2.currentRoute
      guard let self else { return }
      isSelected = nav2.currentRoute == route
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observeNavRoute()
      }
    }
  }
}
