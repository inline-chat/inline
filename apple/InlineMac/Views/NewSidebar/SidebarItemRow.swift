import AppKit
import Combine
import InlineKit
import Logger

class SidebarItemRow: NSTableCellView {
  typealias SidebarEvents = NewSidebar.SidebarEvents

  private let dependencies: AppDependencies
  private weak var events: PassthroughSubject<SidebarEvents, Never>?

  private var item: HomeChatItem?

  // MARK: - UI props

  static let avatarSize: CGFloat = 48
  static let height: CGFloat = 62
  static let verticalPadding: CGFloat = (SidebarItemRow.height - SidebarItemRow.avatarSize) / 2

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

    if preparingForReuse {
      containerView.layer?.backgroundColor = color.cgColor
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = isHovered || isSelected ? 0.08 : 0.15
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        containerView.layer?.backgroundColor = color.cgColor
      }
    }
  }

  @objc private func handleTap() {
    guard let route else { return }
    dependencies.nav.open(route)
  }

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

  private var unreadBadge: NSView?

  private func createUnreadBadge() -> NSView {
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
    return view
  }

  private var pinnedBadge: NSImageView?

  private func createPinnedBadge() -> NSImageView {
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
    // view.image?.isTemplate = true
    view.widthAnchor.constraint(equalToConstant: 10).isActive = true
    view.heightAnchor.constraint(equalToConstant: 10).isActive = true
    return view
  }

  /// The avatar view
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
    view.spacing = 1
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// The title label
  lazy var nameLabel: NSTextField = {
    let view = NSTextField()
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
    // view.textContainer?.containerSize = CGSize(
    //   width: CGFloat.greatestFiniteMagnitude,
    //   height: CGFloat.greatestFiniteMagnitude
    // )
    // view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    return view
  }()

  /// The sender view
  var senderView: SidebarSenderView?

  private func createSenderView() -> SidebarSenderView {
    let view = SidebarSenderView(
      userInfo: item?.from ?? .deleted
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  private func setup() {
    // Configure text fields
    nameLabel.isEditable = false
    nameLabel.isBordered = false
    nameLabel.clipsToBounds = false
    nameLabel.backgroundColor = .clear
    nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.maximumNumberOfLines = 1
    nameLabel.cell?.usesSingleLineMode = true
    nameLabel.cell?.wraps = false
    nameLabel.cell?.isScrollable = false

    messageLabel.font = .systemFont(ofSize: 13)
    messageLabel.textColor = .secondaryLabelColor
    messageLabel.alphaValue = 0.8
    // Note: line limits will be set in configure()

    // Setup layout
    addSubview(containerView)
    containerView.addSubview(stackView)
    stackView.addArrangedSubview(gutterView)
    stackView.addArrangedSubview(avatarView)
    stackView.addArrangedSubview(contentStackView)
    contentStackView.addArrangedSubview(nameLabel)
    contentStackView.addArrangedSubview(messageLabel)

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
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: 0),
      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Self.verticalPadding),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -Self.verticalPadding),
    ])

    NSLayoutConstraint.activate([
      avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
      avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
    ])

    // Set fixed spacing between stack view items
    stackView.setCustomSpacing(6, after: avatarView)

    // Configure content hugging and compression resistance
    contentStackView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    contentStackView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

    messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    messageLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
  }

  func configure(with item: HomeChatItem) {
    preparingForReuse = false
    self.item = item

    Log.shared.debug("SidebarItemRow configuring with item: \(item.dialog.id)")

    // Configure avatar
    let peer: ChatIcon.PeerType? = if let user = item.user {
      .user(user)
    } else if let chat = item.chat {
      .chat(chat)
    } else {
      nil
    }

    if let peer {
      NSAnimationContext.runAnimationGroup { context in
        context.allowsImplicitAnimation = false
        context.duration = 0.0

        avatarView.removeFromSuperview()
        avatarView = ChatIconSwiftUIBridge(
          peer,
          size: Self.avatarSize
        )
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        stackView.insertArrangedSubview(avatarView, at: 1)
        stackView.setCustomSpacing(6, after: avatarView)
      }
    }

    // Configure name
    if let user = item.user {
      nameLabel.stringValue = user.user.firstName ??
        user.user.lastName ??
        user.user.username ??
        user.user.phoneNumber ??
        user.user.email ?? ""
    } else if let chat = item.chat {
      let spaceName = item.space?.displayName
      if let spaceName {
        nameLabel.stringValue = "\(spaceName) / \(chat.title ?? "Unknown")"
      } else {
        nameLabel.stringValue = chat.title ?? "Unknown"
      }
    } else {
      nameLabel.stringValue = "Unknown"
    }

    // Configure last message
    let maxLines = isThread ? 1 : 2
    messageLabel.textContainer?.maximumNumberOfLines = maxLines
    messageLabel.textContainer?.lineBreakMode = .byTruncatingTail
    // messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    if let message = item.message {
      messageLabel.string = message.stringRepresentationWithEmoji ?? ""
      Log.shared.debug("SidebarItemRow message set to: \(messageLabel.string)")
    } else {
      messageLabel.string = "Empty chat"
      Log.shared.debug("SidebarItemRow no message")
    }

    // Force the text view to recalculate its layout
    // messageLabel.invalidateIntrinsicContentSize()
    // messageLabel.needsLayout = true

    // Gutter badges ---
    // Unread badge
    if hasUnread {
      if unreadBadge == nil {
        // remove pinned badge if it exists
        pinnedBadge?.removeFromSuperview()
        pinnedBadge = nil

        // add unread badge
        unreadBadge = createUnreadBadge()
        gutterView.addArrangedSubview(unreadBadge!)
      }
    } else {
      unreadBadge?.removeFromSuperview()
      unreadBadge = nil

      // Pinned icon
      if isPinned {
        if pinnedBadge == nil {
          pinnedBadge = createPinnedBadge()
          gutterView.addArrangedSubview(pinnedBadge!)
        }
      } else {
        pinnedBadge?.removeFromSuperview()
        pinnedBadge = nil
      }
    }

    // Update sender view
    if isThread, let from = item.from {
      if senderView == nil {
        senderView = createSenderView()
        contentStackView.insertArrangedSubview(senderView!, at: 1)
      } else {
        senderView?.configure(with: from)
      }
    } else {
      senderView?.removeFromSuperview()
      senderView = nil
    }

    // Update selection state
    isSelected = currentRoute == route
  }

  private var preparingForReuse = false

  override func prepareForReuse() {
    super.prepareForReuse()
    Log.shared.debug("SidebarItemRow preparing for reuse")
    preparingForReuse = true
    isHovered = false
    isSelected = false
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
    menu.addItem(pinItem)

    // Archive item
    let archiveItem = NSMenuItem(
      title: isArchived ? "Unarchive" : "Archive",
      action: #selector(handleArchiveAction),
      keyEquivalent: "a"
    )
    archiveItem.target = self
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
          try await dependencies.realtime
            .invokeWithHandler(.deleteChat, input: .deleteChat(.with {
              $0.peerID = peerId.toInputPeer()
            }))

          // Delete in local db
          if let dialog {
            try await dialog.deleteFromLocalDatabase()
          } else {
            try await chat?.deleteFromLocalDatabase()
          }

          navigateOut()
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

  private var isThread: Bool {
    guard let item else { return false }
    return item.dialog.peerThreadId != nil
  }

  private var hasUnread: Bool {
    guard let item else { return false }
    return (item.dialog.unreadCount ?? 0) > 0
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
