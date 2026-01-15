import InlineKit
import UIKit

// TODO: extract the content into another view
// TODO: make ComposeEmbedView a skelton for all the embeds

class ComposeEmbedViewContent: UIView, UIGestureRecognizerDelegate {
  private enum Constants {
    static let topPadding: CGFloat = 8
    static let closeButtonSize: CGFloat = 24
  }

  static let height: CGFloat = EmbedMessageView.height + Constants.topPadding

  enum Mode {
    case reply
    case edit
  }

  var mode: Mode = .reply
  var peerId: Peer
  private var chatId: Int64
  private var messageId: Int64
  private var viewModel: FullMessageViewModel

  private lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }()

  private lazy var closeButton: UIButton = {
    let button = UIButton()
    let config = UIImage.SymbolConfiguration(pointSize: 17)
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .secondaryLabel
    button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }()

  init(peerId: Peer, chatId: Int64, messageId: Int64) {
    mode = ChatState.shared.getState(peer: peerId).editingMessageId != nil ? .edit : .reply

    self.peerId = peerId
    self.chatId = chatId
    self.messageId = messageId
    viewModel = FullMessageViewModel(db: AppDatabase.shared, messageId: messageId, chatId: chatId)

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
      embedView.heightAnchor.constraint(equalToConstant: EmbedMessageView.height),

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
    viewModel = FullMessageViewModel(db: AppDatabase.shared, messageId: msgId, chatId: chatId)
  }

  func fetchMessage(_ msgId: Int64, chatId: Int64) {
    viewModel.fetchMessage(msgId, chatId: chatId)

    DispatchQueue.main.async { [weak self] in
      self?.updateContent()
    }
  }

  func updateContent() {
    let kind: EmbedMessageView.Kind = mode == .reply ? .replyingInCompose : .editingInCompose
    let style: EmbedMessageView.Style = mode == .reply ? .replyBubble : .compose
    let senderName = viewModel.fullMessage?.from?.shortDisplayName ?? "User"

    if let fullMessage = viewModel.fullMessage {
      embedView.configure(
        fullMessage: fullMessage,
        kind: kind,
        outgoing: false,
        isOnlyEmoji: false,
        style: style
      )
    } else {
      embedView.showNotLoaded(
        kind: kind,
        senderName: senderName,
        outgoing: false,
        isOnlyEmoji: false,
        style: style
      )
    }
  }

  @objc private func closeButtonTapped() {
    switch mode {
    case .reply:
      ChatState.shared.clearReplyingMessageId(peer: peerId)
    case .edit:
      ChatState.shared.clearEditingMessageId(peer: peerId)
      if let composeView = findComposeView() {
        composeView.textView.text = ""
        composeView.textView.showPlaceholder(true)
        composeView.buttonDisappear()

        composeView.clearDraft()
        composeView.updateHeight()
      }
    }
  }

  @objc private func handleEmbedTapped() {
    guard mode == .reply else { return }

    NotificationCenter.default.post(
      name: Notification.Name("ScrollToRepliedMessage"),
      object: nil,
      userInfo: [
        "repliedToMessageId": messageId,
        "chatId": chatId,
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
