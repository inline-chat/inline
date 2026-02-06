import AppKit
import Combine
import InlineKit
import Logger
import Translation

class SidebarItemRow: NSTableCellView {
  typealias SidebarEvents = NewSidebar.SidebarEvents

  private let dependencies: AppDependencies
  private weak var events: PassthroughSubject<SidebarEvents, Never>?

  private var item: HomeChatItem?

  // MARK: - Configuration Signature (for efficient updates)

  /// Lightweight struct capturing only UI-relevant state for diffing
  private struct RowSignature: Equatable {
    let name: String
    let message: String
    let hasUnread: Bool
    let isPinned: Bool
    let isThread: Bool
    let peerKey: String
    let senderName: String?
    let spaceName: String?
  }

  private var previousSignature: RowSignature?

  /// Build signature from current item
  private func makeSignature(from item: HomeChatItem) -> RowSignature {
    let name: String
    if let user = item.user {
      name = user.user.firstName ?? user.user.lastName ?? user.user.username ?? user.user.phoneNumber ?? user.user.email ?? ""
    } else if let chat = item.chat {
      name = chat.humanReadableTitle ?? "Unknown"
    } else {
      name = "Unknown"
    }

    let message: String
    if let lastMessage = item.lastMessage {
      message = lastMessage.displayTextForLastMessage ?? lastMessage.message.stringRepresentationWithEmoji ?? ""
    } else {
      message = ""
    }

    let peerKey: String
    if let user = item.user {
      peerKey = "user_\(user.user.id)"
    } else if let chat = item.chat {
      peerKey = "chat_\(chat.id)"
    } else {
      peerKey = ""
    }

    let isThread = item.dialog.peerThreadId != nil
    let senderName = isThread ? item.lastMessage?.senderInfo?.user.firstName : nil
    let spaceName = isThread ? item.space?.displayName : nil

    return RowSignature(
      name: name,
      message: message,
      hasUnread: (item.dialog.unreadCount ?? 0) > 0 || (item.dialog.unreadMark == true),
      isPinned: item.dialog.pinned ?? false,
      isThread: isThread,
      peerKey: peerKey,
      senderName: senderName,
      spaceName: spaceName
    )
  }

  // MARK: - UI props

  static let avatarSize: CGFloat = 48
  static let height: CGFloat = 64
  static let verticalPadding: CGFloat = ((SidebarItemRow.height - SidebarItemRow.avatarSize) / 2)
  static let avatarBackgroundOpacity: Double = 0.85
  let avatarSpacing: CGFloat = 6

  private var hoverColor: NSColor {
    if #available(macOS 14.0, *) {
      .tertiarySystemFill
    } else {
      .controlBackgroundColor
    }
  }

  private var selectedColor: NSColor {
    // if #available(macOS 14.0, *) {
    //   .quaternarySystemFill
    // } else {
    //   .selectedControlColor
    // }
    .labelColor.withAlphaComponent(0.1)
  }

  // MARK: - State

  private var isHovered = false {
    didSet {
      guard oldValue != isHovered else { return }
      updateAppearance()
    }
  }

  private var isSelected = false {
    didSet {
      guard oldValue != isSelected else { return }
      // When deselecting, also clear hover (click moved elsewhere)
      if !isSelected {
        isHovered = false
      }
      updateAppearance()
    }
  }

  private var isParentScrolling = false {
    didSet {
      updateTrackingArea()

      // Reset hover state
      isHovered = false
    }
  }

  init(dependencies: AppDependencies, events: PassthroughSubject<SidebarEvents, Never>) {
    self.dependencies = dependencies
    self.events = events
    super.init(frame: .zero)
    setup()
    setupGestureRecognizers()
    setupTrackingArea()
    setupEventListeners()
  }

  private var cancellables = Set<AnyCancellable>()

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The background view
  lazy var containerView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = 10
    view.layer?.masksToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// Wraps badges, avatar and content
  lazy var stackView: NSStackView = {
    let view = NSStackView()
    view.orientation = .horizontal
    view.spacing = 0
    view.alignment = .top
    view.distribution = .fill
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// Wraps unread badge and pinned badge
  lazy var gutterView: NSStackView = {
    let view = NSStackView()
    view.orientation = .horizontal
    view.alignment = .centerY
    view.distribution = .equalCentering
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 12).isActive = true
    // TODO: move to nslayoutconstraint to match the height of the stackview
    view.heightAnchor.constraint(equalToConstant: Self.height - Self.verticalPadding * 2).isActive = true
    return view
  }()

  /// Unread indicator badge (pre-created, toggle isHidden)
  private lazy var unreadBadge: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = 2.5
    view.layer?.masksToBounds = true
    view.layer?.backgroundColor = NSColor.accent.cgColor
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: 5).isActive = true
    view.heightAnchor.constraint(equalToConstant: 5).isActive = true
    view.setContentHuggingPriority(.required, for: .horizontal)
    view.setContentHuggingPriority(.required, for: .vertical)
    view.isHidden = true
    return view
  }()

  /// Pinned indicator badge (pre-created, toggle isHidden)
  private lazy var pinnedBadge: NSImageView = {
    let view = NSImageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    let config = NSImage.SymbolConfiguration(
      pointSize: 10,
      weight: .bold,
      scale: .small
    )
    .applying(.init(paletteColors: [.tertiaryLabelColor]))
    view.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
    view.widthAnchor.constraint(equalToConstant: 10).isActive = true
    view.heightAnchor.constraint(equalToConstant: 10).isActive = true
    view.isHidden = true
    return view
  }()

  /// The avatar view
  lazy var avatarView: ChatIconSwiftUIBridge = {
    let view = ChatIconSwiftUIBridge(
      .user(.deleted),
      size: Self.avatarSize,
      backgroundOpacity: Self.avatarBackgroundOpacity
    )
    view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// The avatar spacer view (probably unused)
  lazy var avatarSpacerView: NSView = {
    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    return spacer
  }()

  /// The content stack view wraps name and message labels
  lazy var contentStackView: NSStackView = {
    let view = NSStackView()
    view.orientation = .vertical
    view.alignment = .leading
    view.spacing = 0
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// The message container view wraps sender and message labels
  lazy var messageContainerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// The last message label
  lazy var messageLabel: NSTextView = {
    let view = NSTextView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isEditable = false
    view.isSelectable = false
    view.drawsBackground = false
    view.textContainer?.lineFragmentPadding = 0
    view.textContainerInset = .zero
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.font = .systemFont(ofSize: 13, weight: .regular)
    view.textColor = .secondaryLabelColor
    view.alphaValue = 0.8
    return view
  }()

  /// The space name label (pre-created, toggle isHidden)
  /// Only used for threads that are in a space
  lazy var spaceNameLabel: NSTextView = {
    let view = NSTextView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isEditable = false
    view.isSelectable = false
    view.drawsBackground = false
    view.textContainer?.lineFragmentPadding = 0
    view.textContainerInset = .zero
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.font = .systemFont(ofSize: 11, weight: .medium)
    view.textColor = .labelColor
    view.alphaValue = 0.4
    view.textContainer?.lineBreakMode = .byTruncatingTail
    view.textContainer?.maximumNumberOfLines = 1
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.heightAnchor.constraint(equalToConstant: 14).isActive = true
    view.isHidden = true
    return view
  }()

  /// The chat title label
  lazy var nameLabel: NSTextView = {
    let view = NSTextView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isEditable = false
    view.isSelectable = false
    view.drawsBackground = false
    view.textContainer?.lineFragmentPadding = 0
    view.textContainerInset = .zero
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.font = .systemFont(ofSize: 13, weight: .regular)
    view.textContainer?.lineBreakMode = .byTruncatingTail
    view.textContainer?.maximumNumberOfLines = 1
    view.heightAnchor.constraint(equalToConstant: 18).isActive = true
    return view
  }()

  /// The sender view
  var senderView: SidebarSenderView?

  /// Constraint for message label leading anchor
  private var messageLabelLeadingConstraint: NSLayoutConstraint?
  private enum MessageLeadingMode {
    case container
    case sender
  }
  private var messageLabelLeadingMode: MessageLeadingMode = .container

  private func createSenderView() -> SidebarSenderView {
    let view = SidebarSenderView(
      userInfo: item?.lastMessage?.senderInfo ?? .deleted
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    return view
  }

  /// Common layout setup happens here
  private func setup() {
    // Setup layout
    addSubview(containerView)
    containerView.addSubview(stackView)
    stackView.addArrangedSubview(gutterView)
    stackView.addArrangedSubview(avatarView)
    stackView.addArrangedSubview(contentStackView)
    contentStackView.addArrangedSubview(nameLabel)
    contentStackView.addArrangedSubview(messageContainerView)
    messageContainerView.addSubview(messageLabel)

    // Pre-create badges (hidden by default, toggled in configure)
    gutterView.addArrangedSubview(unreadBadge)
    gutterView.addArrangedSubview(pinnedBadge)

    // Pre-add spaceNameLabel (hidden by default, toggled in configure for threads)
    contentStackView.insertArrangedSubview(spaceNameLabel, at: 0)

    // Set minimum height instead of fixed height
    heightAnchor.constraint(greaterThanOrEqualToConstant: Self.height).isActive = true

    NSLayoutConstraint.activate([
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    NSLayoutConstraint.activate([
      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 0),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -6),
      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Self.verticalPadding),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: 0), // Don't apply padding
    ])

    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
      avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
    ])

    // Set fixed spacing between stack view items
    stackView.setCustomSpacing(avatarSpacing, after: avatarView)

    // Configure content hugging and compression resistance
    contentStackView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    contentStackView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    messageContainerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    messageContainerView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // Add constraints for messageLabel within messageContainerView
    NSLayoutConstraint.activate([
      messageLabel.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor),
      messageLabel.topAnchor.constraint(equalTo: messageContainerView.topAnchor),
      messageLabel.bottomAnchor.constraint(equalTo: messageContainerView.bottomAnchor),
    ])

    // Initialize message label leading constraint
    messageLabelLeadingConstraint = messageLabel.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor)
    messageLabelLeadingConstraint?.isActive = true
  }

  private func updateMessageLeadingConstraint(showsSender: Bool) {
    let targetMode: MessageLeadingMode = showsSender ? .sender : .container
    guard messageLabelLeadingMode != targetMode else { return }

    messageLabelLeadingConstraint?.isActive = false
    if showsSender, let senderView {
      messageLabelLeadingConstraint = messageLabel.leadingAnchor.constraint(equalTo: senderView.trailingAnchor)
    } else {
      messageLabelLeadingConstraint = messageLabel.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor)
    }
    messageLabelLeadingConstraint?.isActive = true
    messageLabelLeadingMode = targetMode
  }

  func configure(with item: HomeChatItem) {
    preparingForReuse = false

    // Build signature for efficient comparison
    let newSignature = makeSignature(from: item)
    let isThreadItem = newSignature.isThread

    // Always enforce line count (protects against reuse/config issues)
    let maxLines = isThreadItem ? 1 : 2
    messageLabel.textContainer?.maximumNumberOfLines = maxLines
    messageLabel.textContainer?.lineBreakMode = .byTruncatingTail

    // Early exit if nothing changed
    if let previousSignature, previousSignature == newSignature {
      // Still update selection state (can change without item change)
      isSelected = currentRoute == route
      return
    }

    self.item = item
    previousSignature = newSignature

    // Configure avatar (update in place)
    let peer: ChatIcon.PeerType? = if let user = item.user {
      .user(user)
    } else if let chat = item.chat {
      .chat(chat)
    } else {
      nil
    }

    if let peer {
      avatarView.update(peerType: peer)
    }

    // Configure space name (toggle visibility)
    spaceNameLabel.isHidden = !isThreadItem
    if isThreadItem {
      spaceNameLabel.string = newSignature.spaceName ?? "Unknown space"
    }

    // Configure name (only if changed)
    if nameLabel.string != newSignature.name {
      nameLabel.string = newSignature.name
    }

    // Configure last message
    if messageLabel.string != newSignature.message {
      messageLabel.string = newSignature.message
    }

    // Configure sender view (lazy creation, toggle visibility)
    if isThreadItem, let senderInfo = item.lastMessage?.senderInfo {
      if senderView == nil {
        senderView = createSenderView()
        messageContainerView.addSubview(senderView!)

        // Add constraints for sender view
        NSLayoutConstraint.activate([
          senderView!.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor),
          senderView!.topAnchor.constraint(equalTo: messageContainerView.topAnchor),
        ])

      }
      senderView?.isHidden = false
      senderView?.configure(with: senderInfo, inlineWithMessage: isThreadItem)
      updateMessageLeadingConstraint(showsSender: true)
    } else {
      senderView?.isHidden = true
      updateMessageLeadingConstraint(showsSender: false)
    }

    // Configure badges (toggle visibility instead of add/remove)
    if newSignature.hasUnread {
      unreadBadge.isHidden = false
      pinnedBadge.isHidden = true
    } else {
      unreadBadge.isHidden = true
      pinnedBadge.isHidden = !newSignature.isPinned
    }

    // Update selection state
    isSelected = currentRoute == route
  }

  private var preparingForReuse = false

  override func prepareForReuse() {
    super.prepareForReuse()
    preparingForReuse = true
    previousSignature = nil  // Reset signature to force reconfigure on reuse
    isHovered = false
    isSelected = false
    updateMessageLeadingConstraint(showsSender: false)
  }

  // MARK: - Context Menu

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let item else { return nil }

    let menu = NSMenu()

    // Pin item
    let pinItem = NSMenuItem(
      title: isPinned ? "Unpin" : "Pin",
      action: #selector(handlePinAction),
      keyEquivalent: "p"
    )
    pinItem.target = self
    pinItem.image = NSImage(systemSymbolName: isPinned ? "pin.slash" : "pin", accessibilityDescription: nil)
    menu.addItem(pinItem)

    // Read/Unread item
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

    // Archive item
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

    if isThread {
      // Separator
      menu.addItem(.separator())

      // Delete item
      let deleteItem = NSMenuItem(
        title: "Delete",
        action: #selector(handleDeleteAction),
        keyEquivalent: ""
      )
      deleteItem.target = self
      deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
      deleteItem.attributedTitle = NSAttributedString(
        string: "Delete",
        attributes: [.foregroundColor: NSColor.systemRed]
      )
      menu.addItem(deleteItem)
    }

    return menu
  }

  @objc private func handlePinAction() {
    guard let item else { return }
    Task(priority: .userInitiated) {
      try await DataManager.shared.updateDialog(peerId: item.peerId, pinned: !isPinned)
    }
  }

  @objc private func handleArchiveAction() {
    guard let item else { return }
    Task(priority: .userInitiated) {
      try await DataManager.shared.updateDialog(peerId: item.peerId, archived: !isArchived)
    }
  }

  @objc private func handleReadUnreadAction() {
    guard let item else { return }

    Task(priority: .userInitiated) {
      do {
        if hasUnread {
          // Mark as read using UnreadManager
          UnreadManager.shared.readAll(item.peerId, chatId: item.chat?.id ?? 0)
        } else {
          // Mark as unread using realtime API
          try await dependencies.realtimeV2.send(.markAsUnread(peerId: item.peerId))
        }
      } catch {
        Log.shared.error("Failed to update read/unread status", error: error)
      }
    }
  }

  @objc private func handleDeleteAction() {
    // Ask for confirmation
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete chat"
    if let chatTitle = chat?.title {
      alert
        .informativeText =
        "Are you sure you want to delete \(chatTitle)? This action cannot be undone. This will delete all messages in the chat."
    } else {
      alert.informativeText = "Are you sure you want to delete this chat?"
    }

    // Add Cancel button first to make it the default/primary button
    let cancel = alert.addButton(withTitle: "Cancel")
    cancel.keyEquivalent = "\r" // Return key
    cancel.keyEquivalentModifierMask = []

    // Add Delete button second - no keyboard shortcuts for safety
    let delete = alert.addButton(withTitle: "Delete")
    delete.contentTintColor = .systemRed
    delete.hasDestructiveAction = true
    delete.keyEquivalent = "" // No key equivalent

    // Set Cancel as the default button (this prevents space from triggering Delete)
    alert.window.defaultButtonCell = cancel.cell as? NSButtonCell

    if alert.runModal() == .alertSecondButtonReturn { // Now Delete is the second button
      Task(priority: .userInitiated) {
        guard let peerId else { return }
        do {
          try await dependencies.realtimeV2.send(.deleteChat(peerId: peerId))

          navigateOut()

          // Delete in local db
          if let dialog {
            try await dialog.deleteFromLocalDatabase()
          } else {
            try await chat?.deleteFromLocalDatabase()
          }

        } catch let error as RealtimeAPIError {
          switch error {
            case .rpcError(errorCode: .chatIDInvalid, _, _):
              Log.shared.debug("Chat ID invalid, deleting in local db anyway")
              navigateOut()
              // Delete in local db anyway
              if let dialog {
                try await dialog.deleteFromLocalDatabase()
              } else {
                try await chat?.deleteFromLocalDatabase()
              }

            default:
              Log.shared.error("Failed to delete chat", error: error)
              let alert = NSAlert()
              alert.alertStyle = .warning
              alert.messageText = "Failed to delete chat"
              alert.informativeText = "Error \(error.localizedDescription)"
              alert.addButton(withTitle: "OK")
              alert.runModal()
          }
        } catch {
          // Show alert
          Log.shared.error("Failed to delete chat", error: error)
          let alert = NSAlert()
          alert.alertStyle = .warning
          alert.messageText = "Failed to delete chat"
          alert.informativeText = "Error \(error.localizedDescription)"
          alert.addButton(withTitle: "OK")
          alert.runModal()
        }
      }
    }
  }

  private func navigateOut() {
    if isSelected {
      // TODO: replace route
      dependencies.nav.open(.empty)
    }
  }

  // MARK: - Computed

  private var showsSpaceName: Bool {
    isThread
  }

  private var isThread: Bool {
    guard let item else { return false }
    return item.dialog.peerThreadId != nil
  }

  private var hasUnread: Bool {
    guard let item else { return false }
    return (item.dialog.unreadCount ?? 0) > 0 || (item.dialog.unreadMark == true)
  }

  private var isPinned: Bool {
    guard let item else { return false }
    return item.dialog.pinned ?? false
  }

  private var isArchived: Bool {
    guard let item else { return false }
    return item.dialog.archived ?? false
  }

  private var dialog: Dialog? {
    guard let item else { return nil }
    return item.dialog
  }

  /// PeerId for this item
  private var peerId: Peer? {
    guard let item else {
      return nil
    }
    return item.chat?.peerId.toPeer()
  }

  private var chat: Chat? {
    guard let item else { return nil }
    return item.chat
  }

  /// Route for this item
  private var route: NavEntry.Route? {
    if let peerId {
      .chat(peer: peerId)
    } else {
      nil
    }
  }

  /// Helper to get the current route faster
  private var currentRoute: NavEntry.Route {
    dependencies.nav.currentRoute
  }
}

// MARK: - Hover and interactions

extension SidebarItemRow {
  private func setupEventListeners() {
    events?.sink { [weak self] event in
      self?.handleEvent(event)
    }
    .store(in: &cancellables)

    dependencies.nav.$currentRoute
      .sink { [weak self] currentRoute in
        guard let self else { return }
        isSelected = currentRoute == route
      }
      .store(in: &cancellables)

    // Subscribe to translation state changes
    TranslationState.shared.subject.sink { [weak self] peer, _ in
      guard let self, let currentPeer = peerId else { return }

      // Only reconfigure if the translation change is for this item's peer
      if peer == currentPeer, let item {
        configure(with: item)
      }
    }.store(in: &cancellables)
  }

  private func handleEvent(_ event: SidebarEvents) {
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
    // Remove any existing tracking areas
    trackingAreas.forEach { removeTrackingArea($0) }

    if isParentScrolling {
      return
    }

    // Add new tracking area with current bounds
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
    Log.shared.debug("SidebarItemRow mouse entered")
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    Log.shared.debug("SidebarItemRow mouse exited")
    isHovered = false
  }

  private func setupGestureRecognizers() {
    let tapGesture = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
  }

  private func updateAppearance() {
    let color = isSelected ? selectedColor : isHovered ? hoverColor : .clear
    let cgColor = color.cgColor

    guard let layer = containerView.layer else { return }

    // Skip if color hasn't changed
    if layer.backgroundColor == cgColor {
      return
    }

    CATransaction.begin()
    if preparingForReuse {
      CATransaction.setDisableActions(true)
    } else {
      CATransaction.setAnimationDuration(isHovered || isSelected ? 0.08 : 0.15)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
    }
    layer.backgroundColor = cgColor
    CATransaction.commit()
  }

  @objc private func handleTap() {
    guard let route else { return }
    dependencies.nav.open(route)
  }
}

// MARK: - Preview

#Preview("SidebarItemRow") {
  let dependencies = AppDependencies()
  let events = PassthroughSubject<NewSidebar.SidebarEvents, Never>()

  let row = SidebarItemRow(dependencies: dependencies, events: events)
  let chat = Chat(
    id: Int64.random(in: 1 ... 50_000),
    date: Date(),
    type: .thread,
    title: "Thread Chat",
    spaceId: nil,
    peerUserId: nil,
    lastMsgId: 1,
    emoji: nil
  )

  let sampleMessageInfo = EmbeddedMessage(
    message: Message(
      messageId: 1,
      fromId: 1,
      date: Date(),
      text: "This is a preview message.",
      peerUserId: 0,
      peerThreadId: chat.id,
      chatId: chat.id
    ),
    senderInfo: UserInfo.preview,
    translations: []
  )

  let sampleDialog = Dialog.previewThread

  let sampleItem = HomeChatItem(
    dialog: sampleDialog,
    user: nil,
    chat: Chat.preview,
    lastMessage: sampleMessageInfo,
    space: Space.preview
  )

  row.configure(with: sampleItem)

  NSLayoutConstraint.activate([
    row.widthAnchor.constraint(equalToConstant: 300),
    row.heightAnchor.constraint(equalToConstant: SidebarItemRow.height),
  ])

  row.frame = NSRect(x: 0, y: 0, width: 300, height: SidebarItemRow.height)
  return row
}
