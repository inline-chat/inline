import AppKit
import Combine
import InlineKit

class ChatTitleToolbar: NSToolbarItem {
  private var peer: Peer
  private var dependencies: AppDependencies
  private var iconSize: CGFloat = Theme.chatToolbarIconSize

  private lazy var iconView = ChatIconView(peer: peer, iconSize: iconSize)
  private lazy var statusView = ChatStatusView(peer: peer)

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
    return tf
  }()

  private lazy var textStack: NSStackView = {
    let subviews = if user?.user.isCurrentUser() == true { [nameLabel] } else { [nameLabel, statusView] }
    let stack = NSStackView(
      views: subviews
    )
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    return stack
  }()

  init(peer: Peer, dependencies: AppDependencies) {
    self.peer = peer
    self.dependencies = dependencies
    super.init(itemIdentifier: .chatTitle)

    visibilityPriority = .high

    setupView()
    setupConstraints()
    setupInteraction()
    configure()
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
  }

  @objc private func handleClick() {
    // Handle title click to show chat info
    // NSApp.sendAction(#selector(ChatWindowController.showChatInfo(_:)), to: nil, from: self)
  }

  var chatTitle: String {
    if let user {
      if user.user.isCurrentUser() {
        "Saved Messages"
      } else {
        user.user.fullName
      }
    } else if let chat {
      chat.title ?? "Untitled"
    } else {
      "Unknown"
    }
  }

  func configure() {
    nameLabel.stringValue = chatTitle
    iconView.configure()
  }
}

// MARK: Status / Subtitle

final class ChatStatusView: NSView {
  private let label: NSTextField = {
    let tf = NSTextField(labelWithString: "")
    tf.font = .systemFont(ofSize: 11)
    tf.textColor = .secondaryLabelColor
    tf.translatesAutoresizingMaskIntoConstraints = false
    return tf
  }()

  init(peer: Peer) {
    self.peer = peer
    super.init(frame: .zero)
    setupView()
    subscribeToUpdates()
    updateLabel()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func subscribeToUpdates() {
    // typing... updates
    ComposeActions.shared.$actions.sink { [weak self] actions in
      guard let self else { return }

      // If changed
      if actions[peer]?.action != currentComposeAction {
        DispatchQueue.main.async {
          self.updateLabel()
        }
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

  private var currentLabel: String {
    if chat != nil {
      return "public"
    }

    guard let user else { return "last seen a long time ago" }

    if user.isCurrentUser() {
      return ""
    }

    if let action = currentComposeAction {
      return action.toHumanReadable()
    } else if user.online == true {
      return "online"
    } else if let lastOnline = user.lastOnline {
      return getLastOnlineText(date: lastOnline)
    }
    return "last seen recently"
  }

  private func updateLabel() {
    label.stringValue = currentLabel
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor),
      label.trailingAnchor.constraint(equalTo: trailingAnchor),
      label.topAnchor.constraint(equalTo: topAnchor),
      label.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  static let formatter = RelativeDateTimeFormatter()

  private func getLastOnlineText(date: Date?, _ currentTime: Date = Date()) -> String {
    guard let date else { return "" }

    let diffSeconds = currentTime.timeIntervalSince(date)
    if diffSeconds < 59 {
      return "last seen just now"
    }

    Self.formatter.dateTimeStyle = .named
    return "last seen \(Self.formatter.localizedString(for: date, relativeTo: Date()))"
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
          let avatar = ChatIconSwiftUIBridge(.savedMessage(user.user), size: iconSize)
          avatar.translatesAutoresizingMaskIntoConstraints = false
          addSubview(avatar)
          return avatar
        } else {
          let avatar = ChatIconSwiftUIBridge(.user(user), size: iconSize)
          avatar.translatesAutoresizingMaskIntoConstraints = false
          addSubview(avatar)
          return avatar
        }
      } else if let chat {
        let avatar = ChatIconSwiftUIBridge(.chat(chat), size: iconSize)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)
        return avatar
      } else {
        let avatar = ChatIconSwiftUIBridge(.user(.deleted), size: iconSize)
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
