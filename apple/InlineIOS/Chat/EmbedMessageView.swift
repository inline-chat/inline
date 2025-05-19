import InlineKit
import UIKit

class EmbedMessageView: UIView {
  private enum Constants {
    static let cornerRadius: CGFloat = 8
    static let rectangleWidth: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 2
    static let horizontalPadding: CGFloat = 6
    static let imageIconSize: CGFloat = 16
  }

  static let height = 42.0
  private var outgoing: Bool = false
  private var isOnlyEmoji: Bool = false

  private lazy var headerLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14, weight: .bold)
    label.numberOfLines = 1
    return label
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14)
    label.numberOfLines = 1

    return label
  }()

  private lazy var imageIconView: UIImageView = {
    let imageView = UIImageView()
    let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    imageView.image = UIImage(systemName: "photo.fill", withConfiguration: config)
    imageView.contentMode = .scaleAspectFit
    imageView.setContentHuggingPriority(.required, for: .horizontal)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    return imageView
  }()

  private lazy var messageStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [imageIconView, messageLabel])
    stackView.axis = .horizontal
    stackView.spacing = 4
    stackView.alignment = .center
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }()

  private lazy var rectangleView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.mask = CAShapeLayer()
    return view
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupLayer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
    setupLayer()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateRectangleMask()
  }

  func showNotLoaded(outgoing: Bool, isOnlyEmoji: Bool) {
    self.outgoing = outgoing
    self.isOnlyEmoji = isOnlyEmoji
    headerLabel.text = nil
    messageLabel.text = "Message not loaded"
    let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    imageIconView.image = UIImage(systemName: "exclamationmark.circle", withConfiguration: config)
    imageIconView.isHidden = false
    updateColors()
  }

  func configure(message: Message, senderName: String, outgoing: Bool, isOnlyEmoji: Bool) {
    self.outgoing = outgoing
    self.isOnlyEmoji = isOnlyEmoji
    headerLabel.text = senderName

    if message.hasUnsupportedTypes {
      imageIconView.isHidden = true
      messageLabel.text = "Unsupported message"
    } else if message.isSticker == true {
      let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
      imageIconView.image = UIImage(systemName: "face.smiling", withConfiguration: config)
      imageIconView.isHidden = false
      messageLabel.text = "Sticker"
    } else if message.documentId != nil, !message.hasText {
      let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
      imageIconView.image = UIImage(systemName: "document.fill", withConfiguration: config)
      imageIconView.isHidden = false
      messageLabel.text = "Document"
    } else if message.documentId != nil, message.hasText {
      let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
      imageIconView.image = UIImage(systemName: "document.fill", withConfiguration: config)
      imageIconView.isHidden = false
      messageLabel.text = message.text
    } else if message.hasPhoto, message.hasText {
      imageIconView.isHidden = false
      messageLabel.text = message.text
    } else if message.hasPhoto, !message.hasText {
      imageIconView.isHidden = true
      messageLabel.text = "Photo"
    } else if !message.hasPhoto, message.hasText {
      imageIconView.isHidden = true
      messageLabel.text = message.text
    }

    updateColors()
  }
}

private extension EmbedMessageView {
  func setupViews() {
    addSubview(rectangleView)
    addSubview(headerLabel)
    addSubview(messageStackView)

    NSLayoutConstraint.activate([
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleView.widthAnchor.constraint(equalToConstant: Constants.rectangleWidth),
      rectangleView.topAnchor.constraint(equalTo: topAnchor),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor),

      headerLabel.leadingAnchor.constraint(
        equalTo: rectangleView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      headerLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),
      headerLabel.topAnchor.constraint(
        equalTo: topAnchor,
        constant: Constants.verticalPadding
      ),
      headerLabel.bottomAnchor.constraint(equalTo: messageStackView.topAnchor),

      messageStackView.leadingAnchor.constraint(
        equalTo: rectangleView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      messageStackView.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),
      messageStackView.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -Constants.verticalPadding
      ),

    ])
  }

  func setupLayer() {
    UIView.performWithoutAnimation {
      layer.cornerRadius = Constants.cornerRadius
    }
    layer.masksToBounds = true
  }

  func updateColors() {
    let textColor: UIColor = outgoing && !isOnlyEmoji ?.white : .secondaryLabel
    let rectangleColor = outgoing && !isOnlyEmoji ? UIColor.white : .systemGray
    let bgAlpha: CGFloat = outgoing && !isOnlyEmoji ? 0.13 : 0.1
    backgroundColor = outgoing && !isOnlyEmoji ? .white.withAlphaComponent(bgAlpha) : .systemGray
      .withAlphaComponent(bgAlpha)

    headerLabel.textColor = textColor
    messageLabel.textColor = textColor
    rectangleView.backgroundColor = rectangleColor
    imageIconView.tintColor = textColor
  }
}

private extension EmbedMessageView {
  func updateRectangleMask() {
    let path = UIBezierPath(
      roundedRect: rectangleView.bounds,
      byRoundingCorners: [.topLeft, .bottomLeft],
      cornerRadii: CGSize(width: Constants.cornerRadius, height: Constants.cornerRadius)
    )

    if let mask = rectangleView.layer.mask as? CAShapeLayer {
      mask.path = path.cgPath
    }
  }
}
