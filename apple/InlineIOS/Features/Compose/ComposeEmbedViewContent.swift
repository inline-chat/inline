import InlineKit
import UIKit

// TODO: extract the content into another view
// TODO: make ComposeEmbedView a skelton for all the embeds

class ComposeEmbedViewContent: UIView, UIGestureRecognizerDelegate {
  private enum Constants {
    static let topPadding: CGFloat = 8
    static let closeButtonSize: CGFloat = 24
  }

  static let height: CGFloat = EmbedMessageView.composeHeight + Constants.topPadding

  enum Mode {
    case reply
    case edit
    case forward
  }

  var mode: Mode = .reply
  var peerId: Peer
  private var messageChatId: Int64
  private var messageId: Int64
  private var viewModel: FullMessageViewModel

  private lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }()

  private lazy var closeButton: UIButton = {
    let button = ComposeEmbedCloseButton()
    let config = UIImage.SymbolConfiguration(pointSize: 17)
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .secondaryLabel
    button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()

  init(peerId: Peer, messageChatId: Int64, messageId: Int64, mode: Mode) {
    self.mode = mode
    self.peerId = peerId
    self.messageChatId = messageChatId
    self.messageId = messageId
    viewModel = FullMessageViewModel(db: AppDatabase.shared, messageId: messageId, chatId: messageChatId)

    super.init(frame: .zero)

    setupViews()
    setupConstraints()
    setupObservers()
    updateContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    backgroundColor = .clear
    clipsToBounds = true
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = true

    addSubview(embedView)
    addSubview(closeButton)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleEmbedTapped))
    tapGesture.delegate = self
    addGestureRecognizer(tapGesture)
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      embedView.leadingAnchor.constraint(equalTo: leadingAnchor),
      embedView.topAnchor.constraint(equalTo: topAnchor, constant: Constants.topPadding),
      embedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      embedView.heightAnchor.constraint(equalToConstant: EmbedMessageView.composeHeight),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      closeButton.centerYAnchor.constraint(equalTo: embedView.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: Constants.closeButtonSize),
      closeButton.heightAnchor.constraint(equalToConstant: Constants.closeButtonSize),
    ])
  }

  private func setupObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(messageUpdated),
      name: .init("FullMessageDidChange"),
      object: nil
    )
  }

  @objc private func messageUpdated() {
    updateContent()
  }

  func setMessageIdToVM(_ msgId: Int64) {
    viewModel = FullMessageViewModel(db: AppDatabase.shared, messageId: msgId, chatId: messageChatId)
  }

  func fetchMessage(_ msgId: Int64, chatId: Int64) {
    viewModel.fetchMessage(msgId, chatId: chatId)

    DispatchQueue.main.async { [weak self] in
      self?.updateContent()
    }
  }

  func updateContent() {
    let kind: EmbedMessageView.Kind = switch mode {
    case .reply:
      .replyingInCompose
    case .edit:
      .editingInCompose
    case .forward:
      .forwardingInCompose
    }
    let style: EmbedMessageView.Style = mode == .reply ? .replyBubble : .compose
    let fallbackSenderName = viewModel.fullMessage?.from?.shortDisplayName ?? "User"
    let forwardSenderName = mode == .forward
      ? (viewModel.fullMessage?.forwardFromUserInfo?.user.shortDisplayName ?? fallbackSenderName)
      : fallbackSenderName

    if let fullMessage = viewModel.fullMessage {
      embedView.configure(
        fullMessage: fullMessage,
        kind: kind,
        outgoing: false,
        isOnlyEmoji: false,
        style: style,
        senderNameOverride: mode == .forward ? forwardSenderName : nil
      )
    } else {
      embedView.showNotLoaded(
        kind: kind,
        senderName: forwardSenderName,
        outgoing: false,
        isOnlyEmoji: false,
        style: style
      )
    }
  }

  @objc private func closeButtonTapped() {
    if let composeView = findComposeView() {
      composeView.dismissEmbed(mode: mode)
      return
    }

    switch mode {
    case .reply:
      ChatState.shared.clearReplyingMessageId(peer: peerId)
    case .edit:
      ChatState.shared.clearEditingMessageId(peer: peerId)
    case .forward:
      ChatState.shared.clearForwarding(peer: peerId)
    }
  }

  @objc private func handleEmbedTapped() {
    guard mode == .reply else { return }

    NotificationCenter.default.post(
      name: Notification.Name("ScrollToRepliedMessage"),
      object: nil,
      userInfo: [
        "repliedToMessageId": messageId,
        "chatId": messageChatId,
      ]
    )
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if let touchedView = touch.view, touchedView.isDescendant(of: closeButton) {
      return false
    }
    return true
  }

  private func findComposeView() -> ComposeView? {
    var current: UIView? = self
    while let parent = current?.superview {
      if let chatContainer = parent as? ChatContainerView {
        return chatContainer.composeView
      }
      current = parent
    }
    return nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

private final class ComposeEmbedCloseButton: UIButton {
  private let hitSlop: CGFloat = 10

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let hitFrame = bounds.insetBy(dx: -hitSlop, dy: -hitSlop)
    return hitFrame.contains(point)
  }
}
