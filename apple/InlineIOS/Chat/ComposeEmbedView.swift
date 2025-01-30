import InlineKit
import UIKit

class ComposeEmbedView: UIView {
  static let height: CGFloat = 56

  var peerId: Peer
  private var chatId: Int64
  private var messageId: Int64
  private var viewModel: FullMessageViewModel

  private lazy var nameLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 17, weight: .medium)
    label.textColor = ColorManager.shared.selectedColor
    return label
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 17, weight: .regular)
    label.textColor = .secondaryLabel
    label.numberOfLines = 1

    return label
  }()

  private lazy var closeButton: UIButton = {
    let button = UIButton()
    let config = UIImage.SymbolConfiguration(pointSize: 17)
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .secondaryLabel
    button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    return button
  }()

  private lazy var labelsStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [nameLabel, messageLabel])
    stackView.axis = .vertical
    stackView.spacing = 0
    stackView.alignment = .leading

    return stackView
  }()

  private lazy var containerStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [labelsStackView, closeButton])
    stackView.axis = .horizontal
    stackView.spacing = 0
    stackView.alignment = .center

    return stackView
  }()

  init(peerId: Peer, chatId: Int64, messageId: Int64) {
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
    addSubview(containerStackView)

    closeButton.setContentHuggingPriority(.required, for: .horizontal)
    closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  private func setupConstraints() {
    containerStackView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      containerStackView.topAnchor.constraint(equalTo: topAnchor),
      containerStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerStackView.trailingAnchor.constraint(equalTo: trailingAnchor),

      closeButton.widthAnchor.constraint(equalToConstant: 24),
      closeButton.heightAnchor.constraint(equalToConstant: 24),
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
    let name = Auth.shared.getCurrentUserId() == viewModel.fullMessage?.message.fromId ?
      "You" : viewModel.fullMessage?.from?.firstName ?? "User"

    nameLabel.text = "Replying to \(name)"
    messageLabel.text = viewModel.fullMessage?.message.text ?? ""
  }

  @objc private func closeButtonTapped() {
    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseInOut) {
      ChatState.shared.clearReplyingMessageId(peer: self.peerId)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
