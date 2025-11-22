import AppKit
import Combine
import InlineKit
import Logger

class MainSidebarItemCell: NSView {
  typealias ScrollEvent = MainSidebarAppKit.ScrollEvent

  private var dependencies: AppDependencies?
  private weak var events: PassthroughSubject<ScrollEvent, Never>?

  private var item: HomeChatItem?

  private static let height: CGFloat = 34
  private static let avatarSize: CGFloat = 28
  private static let horizontalPadding: CGFloat = 6
  private static let avatarSpacing: CGFloat = 6
  private static let cornerRadius: CGFloat = 8
  private static let unreadBadgeSize: CGFloat = 5
  private static let unreadBadgeCornerRadius: CGFloat = 2.5
  private static let pinnedBadgeSize: CGFloat = 8
  private static let pinnedBadgePointSize: CGFloat = 8
  private static let fontSize: CGFloat = 13
  private static let backgroundOpacity: CGFloat = 0.1
  private static let animationDurationFast: TimeInterval = 0.08
  private static let animationDurationSlow: TimeInterval = 0.15

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

  func configure(
    with item: HomeChatItem,
    dependencies: AppDependencies,
    events: PassthroughSubject<ScrollEvent, Never>
  ) {
    preparingForReuse = false
    self.item = item
    self.dependencies = dependencies
    self.events = events

    cancellables.removeAll()

    if let user = item.user {
      NSAnimationContext.runAnimationGroup { context in
        context.allowsImplicitAnimation = false
        context.duration = 0.0

        avatarView.removeFromSuperview()
        avatarView = ChatIconSwiftUIBridge(
          .user(user),
          size: Self.avatarSize
        )
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        stackView.insertArrangedSubview(avatarView, at: 0)
        stackView.setCustomSpacing(Self.avatarSpacing, after: avatarView)
      }
    }

    if let user = item.user {
      nameLabel.stringValue = user.user.firstName ??
        user.user.lastName ??
        user.user.username ??
        user.user.phoneNumber ??
        user.user.email ?? ""
    } else {
      nameLabel.stringValue = ""
    }

    let hasUnread = (item.dialog.unreadCount ?? 0) > 0 || (item.dialog.unreadMark == true)
    let isPinned = item.dialog.pinned ?? false

    badgeView?.removeFromSuperview()
    badgeView = nil

    if hasUnread {
      badgeView = createUnreadBadge()
      stackView.addArrangedSubview(badgeView!)
    } else if isPinned {
      badgeView = createPinnedBadge()
      stackView.addArrangedSubview(badgeView!)
    }

    isSelected = dependencies.nav.currentRoute == route

    setupEventListeners()
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

  private var route: NavEntry.Route? {
    guard let item else { return nil }
    return .chat(peer: item.peerId)
  }

  private func setupEventListeners() {
    guard let dependencies, let events else { return }

    events.sink { [weak self] event in
      self?.handleScrollEvent(event)
    }
    .store(in: &cancellables)

    dependencies.nav.$currentRoute
      .sink { [weak self] currentRoute in
        guard let self else { return }
        isSelected = currentRoute == route
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
    guard let route, let dependencies else { return }
    dependencies.nav.open(route)
  }
}
