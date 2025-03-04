import Auth
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
    label.numberOfLines = 1

    return label
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 17, weight: .regular)
    label.textColor = .secondaryLabel
    label.numberOfLines = 1

    return label
  }()

  private lazy var imageIconView: UIImageView = {
    let imageView = UIImageView()
    let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    imageView.image = UIImage(systemName: "photo.fill", withConfiguration: config)
    imageView.tintColor = .secondaryLabel
    imageView.contentMode = .scaleAspectFit

    return imageView
  }()

  private lazy var closeButton: UIButton = {
    let button = UIButton()
    let config = UIImage.SymbolConfiguration(pointSize: 17)
    button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
    button.tintColor = .secondaryLabel
    button.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    return button
  }()

  private lazy var messageStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [imageIconView, messageLabel])
    stackView.axis = .horizontal
    stackView.spacing = 6
    stackView.alignment = .center
    return stackView
  }()

  private lazy var labelsStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [nameLabel, messageStackView])
    stackView.axis = .vertical
    stackView.spacing = 4
    stackView.alignment = .leading
    return stackView
  }()

  private lazy var containerStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [labelsStackView, closeButton])
    stackView.axis = .horizontal
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
    clipsToBounds = true
    translatesAutoresizingMaskIntoConstraints = false

    messageStackView.addArrangedSubview(imageIconView)
    messageStackView.addArrangedSubview(messageLabel)

    labelsStackView.addArrangedSubview(nameLabel)
    labelsStackView.addArrangedSubview(messageStackView)

    containerStackView.addArrangedSubview(labelsStackView)
    containerStackView.addArrangedSubview(closeButton)

    addSubview(containerStackView)
  }

  private func setupConstraints() {
    containerStackView.translatesAutoresizingMaskIntoConstraints = false
    imageIconView.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      imageIconView.widthAnchor.constraint(equalToConstant: 20),
      imageIconView.heightAnchor.constraint(equalToConstant: 20),

      containerStackView.heightAnchor.constraint(equalToConstant: Self.height),
      containerStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    if let message = viewModel.fullMessage?.message {
      let hasFile = viewModel.fullMessage?.message.fileId != nil
      let hasText = message.text?.isEmpty == false
      if hasFile {
        imageIconView.isHidden = false
        if hasText {
          messageLabel.text = message.text
        } else {
          messageLabel.text = "Photo"
        }
      } else {
        imageIconView.isHidden = true
        messageLabel.text = message.text
      }
    }
  }

  @objc private func closeButtonTapped() {
    ChatState.shared.clearReplyingMessageId(peer: peerId)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
