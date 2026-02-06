import AppKit
import Auth
import Combine
import GRDB
import InlineKit
import Logger
import RealtimeV2

class ChatTitleToolbar: NSToolbarItem {
  private var peer: Peer
  private var dependencies: AppDependencies
  private var iconSize: CGFloat = Theme.chatToolbarIconSize
  private var chatSubscription: AnyCancellable?
  private var isEditingTitle = false

  private lazy var iconView = ChatIconView(peer: peer, iconSize: iconSize)
  private lazy var statusView = ChatStatusView(peer: peer, dependencies: self.dependencies)

  private var user: UserInfo? {
    if case let .user(id) = peer {
      ObjectCache.shared.getUser(id: id)
    } else {
      nil
    }
  }

  private var chat: Chat? {
    if case let .thread(id) = peer {
      ObjectCache.shared.getChat(id: id)
    } else {
      nil
    }
  }

  private let nameLabel: NSTextField = {
    let tf = NSTextField(labelWithString: "")
    tf.font = .systemFont(ofSize: 13, weight: .semibold)
    tf.maximumNumberOfLines = 1
    tf.usesSingleLineMode = true
    tf.lineBreakMode = .byTruncatingTail
    tf.cell?.lineBreakMode = .byTruncatingTail
    tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return tf
  }()

  private let nameEditor: NSTextField = {
    let tf = NSTextField(string: "")
    tf.font = .systemFont(ofSize: 13, weight: .semibold)
    tf.maximumNumberOfLines = 1
    tf.usesSingleLineMode = true
    tf.isEditable = true
    tf.isSelectable = true
    tf.isBordered = true
    tf.isBezeled = true
    tf.focusRingType = .default
    tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
    tf.isHidden = true
    return tf
  }()

  private lazy var textStack: NSStackView = {
    let stack = NSStackView(views: [nameLabel, nameEditor, statusView])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return stack
  }()

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    super.init(itemIdentifier: .chatTitle)

    visibilityPriority = .high
    isBordered = false
    minSize = NSSize(width: iconSize + 8, height: Theme.toolbarHeight)
    maxSize = NSSize(width: 600, height: Theme.toolbarHeight)

    setupView()
    setupConstraints()
    setupInteraction()
    configure()
    subscribeToChatUpdates()
  }

  private let containerView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private func setupView() {
    view = containerView
    containerView.addSubview(iconView)
    containerView.addSubview(textStack)
    containerView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    containerView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textStack.translatesAutoresizingMaskIntoConstraints = false
    nameEditor.delegate = self
    nameEditor.target = self
    nameEditor.action = #selector(commitTitleEdit)
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      iconView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

      textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      textStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      textStack.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
    ])
  }

  private func setupInteraction() {
    let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    containerView.addGestureRecognizer(click)

    let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleTitleDoubleClick))
    doubleClick.numberOfClicksRequired = 2
    doubleClick.delaysPrimaryMouseButtonEvents = false
    nameLabel.addGestureRecognizer(doubleClick)

    let rightClick = NSClickGestureRecognizer(target: self, action: #selector(handleTitleRightClick))
    rightClick.buttonMask = 2
    nameLabel.addGestureRecognizer(rightClick)

    nameLabel.isSelectable = false
  }

  @objc private func handleClick() {
    // Handle title click to show chat info
    // NSApp.sendAction(#selector(ChatWindowController.showChatInfo(_:)), to: nil, from: self)
  }

  @objc private func handleTitleDoubleClick() {
    beginTitleEditing()
  }

  @objc private func handleTitleRightClick() {
    guard let event = NSApp.currentEvent else { return }

    let menu = NSMenu()
    let renameItem = NSMenuItem(title: "Rename Chat...", action: #selector(handleRenameMenu), keyEquivalent: "")
    renameItem.target = self
    renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
    renameItem.isEnabled = isRenameAllowed()
    menu.addItem(renameItem)

    NSMenu.popUpContextMenu(menu, with: event, for: nameLabel)
  }

  @objc private func handleRenameMenu() {
    guard isRenameAllowed() else { return }
    NotificationCenter.default.post(name: .renameThread, object: nil)
  }

  @objc private func commitTitleEdit() {
    endTitleEditing(commit: true)
  }

  private func beginTitleEditing() {
    guard peer.isThread else { return }
    guard isRenameAllowed() else { return }
    guard !isEditingTitle else { return }
    isEditingTitle = true
    nameEditor.stringValue = chatTitle
    nameLabel.isHidden = true
    nameEditor.isHidden = false
    nameEditor.selectText(nil)
    containerView.window?.makeFirstResponder(nameEditor)
  }

  private func endTitleEditing(commit: Bool) {
    guard isEditingTitle else { return }
    isEditingTitle = false
    nameEditor.isHidden = true
    nameLabel.isHidden = false

    let trimmedTitle = nameEditor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

    if commit, !trimmedTitle.isEmpty, trimmedTitle != chatTitle {
      nameLabel.stringValue = trimmedTitle
      if let chatId = peer.asThreadId() {
        Task {
          do {
            _ = try await dependencies.realtimeV2.send(.updateChatInfo(
              chatID: chatId,
              title: trimmedTitle,
              emoji: nil
            ))
          } catch {
            Log.shared.error("Failed to update chat title", error: error)
          }
        }
      }
    } else {
      nameLabel.stringValue = chatTitle
    }

    nameEditor.stringValue = chatTitle
  }

  private func isRenameAllowed() -> Bool {
    guard case let .thread(chatId) = peer else { return false }
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }

    do {
      return try dependencies.database.reader.read { db in
        if let chat = try Chat.fetchOne(db, id: chatId),
           chat.isPublic == true,
           let spaceId = chat.spaceId
        {
          return try Member
            .filter(Member.Columns.userId == currentUserId)
            .filter(Member.Columns.spaceId == spaceId)
            .fetchOne(db) != nil
        }

        return try ChatParticipant
          .filter(Column("chatId") == chatId)
          .filter(Column("userId") == currentUserId)
          .fetchOne(db) != nil
      }
    } catch {
      Log.shared.error("Failed to check chat rename eligibility", error: error)
      return false
    }
  }

  var chatTitle: String {
    if let user {
      if user.user.isCurrentUser() {
        "Saved Messages"
      } else {
        user.user.displayName
      }
    } else if let chat {
      chat.title ?? "Untitled"
    } else {
      "Unknown"
    }
  }

  func configure() {
    nameLabel.stringValue = chatTitle
    if !isEditingTitle {
      nameEditor.stringValue = chatTitle
    }
    statusView.isHidden = user?.user.isCurrentUser() == true
    iconView.configure()
  }

  private func subscribeToChatUpdates() {
    guard case let .thread(chatId) = peer else { return }
    chatSubscription = ObjectCache.shared.getChatPublisher(id: chatId)
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.configure()
        }
      }
  }
}

// MARK: Status / Subtitle

final class ChatStatusView: NSView {
  private var timer: Timer?
  private var dependencies: AppDependencies

  // Connection state tracking
  private var connectionState: RealtimeConnectionState = .connected {
    didSet {
      if oldValue != connectionState {
        DispatchQueue.main.async {
          self.updateLabel()
        }
      }
    }
  }

  private var connectionStateSubscription: AnyCancellable?

  private lazy var label: NSTextField = {
    let tf = NSTextField(labelWithString: "")
    tf.font = .systemFont(ofSize: 11)
    tf.textColor = subtitleColor
    tf.maximumNumberOfLines = 1
    tf.usesSingleLineMode = true
    tf.lineBreakMode = .byTruncatingTail
    tf.cell?.lineBreakMode = .byTruncatingTail
    tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
    tf.translatesAutoresizingMaskIntoConstraints = false
    return tf
  }()

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    super.init(frame: .zero)
    setupView()
    subscribeToUpdates()
    updateLabel()
    startTimer()
  }

  deinit {
    stopTimer()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func subscribeToUpdates() {
    // typing... updates
    ComposeActions.shared.$actions.sink { [weak self] _ in
      guard let self else { return }
      DispatchQueue.main.async {
        self.updateLabel()
      }
    }.store(in: &cancellables)

    // user online updates
    if let user {
      ObjectCache.shared.getUserPublisher(id: user.id).sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.updateLabel()
        }
      }.store(in: &cancellables)
    }

    if case let .thread(chatId) = peer {
      ObjectCache.shared.getChatPublisher(id: chatId).sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.updateLabel()
        }
      }.store(in: &cancellables)
    }

    // connection state updates
    Task {
      let stateObject = await Api.realtime.stateObject
      await MainActor.run {
        self.connectionState = stateObject.connectionState
        self.connectionStateSubscription = stateObject.connectionStatePublisher
          .sink { [weak self] state in
            self?.connectionState = state
          }
      }
    }
  }

  private var cancellables: Set<AnyCancellable> = []
  private var peer: Peer
  private var user: User? {
    if case let .user(id) = peer {
      ObjectCache.shared.getUser(id: id)?.user
    } else {
      nil
    }
  }

  private var chat: Chat? {
    if case let .thread(id) = peer {
      ObjectCache.shared.getChat(id: id)
    } else {
      nil
    }
  }

  private var currentComposeAction: ApiComposeAction? {
    ComposeActions.shared.getComposeAction(for: peer)?.action
  }

  private enum StatusState {
    case connecting(String)
    case publicChat
    case privateChat
    case composing(String) // Changed to String to support custom typing text
    case online(User)
    case offline(User)
    case timezone(String)
    case empty

    var label: String {
      switch self {
        case let .connecting(message): message
        case .publicChat: "public"
        case .privateChat: "private"
        case let .composing(text): text // Use custom typing text
        case let .online(user): getOnlineText(user: user)
        case let .offline(user): getOfflineText(user: user)
        case let .timezone(timeZone): getTimeZoneText(timeZone: timeZone)
        case .empty: ""
      }
    }

    var color: NSColor {
      switch self {
        case .composing: .accent
        default: .secondaryLabelColor
      }
    }

    func getTimeZoneText(timeZone: String) -> String {
      TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timeZone) ?? ""
    }

    func getOnlineText(user: User) -> String {
      if let timeZone = user.timeZone, timeZone != TimeZone.current.identifier {
        return TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timeZone) ?? ""
      }

      // For now disabled
      return ""
      // return "online"
    }

    func getOfflineText(user: User) -> String {
      if let timeZone = user.timeZone, timeZone != TimeZone.current.identifier {
        return TimeZoneFormatter.shared.formatTimeZoneInfo(userTimeZoneId: timeZone) ?? ""
      }

      // For now disabled
      return ""
      // if let lastOnline = user.lastOnline {
      //   return ChatStatusView.getLastOnlineText(date: lastOnline)
      // } else {
      //   return "offline"
      // }
    }
  }

  private var statusState: StatusState {
    // Check connection state first
    if connectionState != .connected {
      return .connecting(connectionState.title.lowercased())
    }

    // Check for typing text first (synchronously)
    if let typingText = ComposeActions.shared.getTypingDisplayText(for: peer), !typingText.isEmpty {
      return .composing(typingText)
    }

    // Check chat state
    if let chat {
      if chat.isPublic == true {
        return .publicChat
      } else if chat.isPublic == false {
        return .privateChat
      }
      return .empty
    }

    // Check user state
    guard let user else { return .empty }
    if user.isCurrentUser() { return .empty }

    // Fallback to old compose action behavior for non-typing actions
    if let action = currentComposeAction, action != .typing {
      return .composing(action.toHumanReadable())
    }

    if user.online == true {
      return .online(user)
    } else if let _ = user.lastOnline {
      return .offline(user)
    }

    // Show timezone
    if let timeZone = user.timeZone, timeZone != TimeZone.current.identifier {
      return .timezone(timeZone)
    }

    return .empty
  }

  private var currentLabel: String {
    statusState.label
  }

  private var subtitleColor: NSColor {
    statusState.color
  }

  private func updateLabel() {
    label.stringValue = currentLabel
    label.textColor = subtitleColor

    // Hide the entire status view if there's no text to display
    isHidden = currentLabel.isEmpty
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setContentHuggingPriority(.defaultLow, for: .horizontal)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.trailingAnchor.constraint(equalTo: trailingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  static let formatter = RelativeDateTimeFormatter()

  static func getLastOnlineText(date: Date?, _ currentTime: Date = Date()) -> String {
    guard let date else { return "" }

    let diffSeconds = currentTime.timeIntervalSince(date)
    if diffSeconds < 59 {
      return "last seen just now"
    }

    Self.formatter.dateTimeStyle = .named
    return "last seen \(Self.formatter.localizedString(for: date, relativeTo: Date()))"
  }

  // Render view every minute to ensure correct last online text
  private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
      self?.updateLabel()
    }

    RunLoop.current.add(timer!, forMode: .default)
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }
}

extension ChatTitleToolbar: NSTextFieldDelegate {
  func controlTextDidEndEditing(_ obj: Notification) {
    guard isEditingTitle else { return }
    let movementValue = obj.userInfo?[NSText.movementUserInfoKey] as? Int
    if movementValue == NSTextMovement.return.rawValue {
      endTitleEditing(commit: true)
    } else {
      endTitleEditing(commit: false)
    }
  }
}

// MARK: - Chat Icon

final class ChatIconView: NSView {
  private let iconSize: CGFloat
  private let peer: Peer
  private var currentAvatar: NSView?

  init(peer: Peer, iconSize: CGFloat) {
    self.peer = peer
    self.iconSize = iconSize

    super.init(frame: .zero)
    setupConstraints()
  }

  private var user: UserInfo? {
    if case let .user(id) = peer {
      ObjectCache.shared.getUser(id: id)
    } else {
      nil
    }
  }

  private var chat: Chat? {
    if case let .thread(id) = peer {
      ObjectCache.shared.getChat(id: id)
    } else {
      nil
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure() {
    currentAvatar?.removeFromSuperview()

    let avatar = {
      if let user {
        if user.user.isCurrentUser() {
          let avatar = SidebarChatIconSwiftUIBridge(.savedMessage(user.user), size: iconSize, ignoresSafeArea: true)
          avatar.translatesAutoresizingMaskIntoConstraints = false
          addSubview(avatar)
          return avatar
        } else {
          let avatar = SidebarChatIconSwiftUIBridge(.user(user), size: iconSize, ignoresSafeArea: true)
          avatar.translatesAutoresizingMaskIntoConstraints = false
          addSubview(avatar)
          return avatar
        }
      } else if let chat {
        let avatar = SidebarChatIconSwiftUIBridge(.chat(chat), size: iconSize, ignoresSafeArea: true)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)
        return avatar
      } else {
        let avatar = SidebarChatIconSwiftUIBridge(.user(.deleted), size: iconSize, ignoresSafeArea: true)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)
        return avatar
      }
    }()

    NSLayoutConstraint.activate([
      avatar.widthAnchor.constraint(equalToConstant: iconSize),
      avatar.heightAnchor.constraint(equalToConstant: iconSize),
      avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
      avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    currentAvatar = avatar
  }

  private func setupConstraints() {
    translatesAutoresizingMaskIntoConstraints = false
    widthAnchor.constraint(equalToConstant: iconSize).isActive = true
    heightAnchor.constraint(equalToConstant: iconSize).isActive = true
  }
}
