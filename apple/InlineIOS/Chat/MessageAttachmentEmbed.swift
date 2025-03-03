import InlineKit
import SafariServices
import UIKit

class MessageAttachmentEmbed: UIView {
  private enum Constants {
    static let cornerRadius: CGFloat = 12
    static let rectangleWidth: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 8
    static let horizontalPadding: CGFloat = 6
  }

  static let height = 28.0
  private var outgoing: Bool = false
  private var url: URL?

  private lazy var circleImageView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    imageView.image = UIImage(systemName: "circle", withConfiguration: config)
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 17)
    label.numberOfLines = 1
    return label
  }()

  private lazy var issueIdentifierLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .right
    label.numberOfLines = 1
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupLayer()
    setupTapGesture()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
    setupLayer()
    setupTapGesture()
  }

  func configure(userName: String, outgoing: Bool, url: URL? = nil, issueIdentifier: String? = nil) {
    self.outgoing = outgoing
    self.url = url
    messageLabel.text = "\(userName) will do"
    issueIdentifierLabel.text = issueIdentifier
    updateColors()
  }

  @objc private func handleTap() {
    guard let url else { return }
    if let viewController = findViewController() {
      let safariVC = SFSafariViewController(url: url)
      viewController.present(safariVC, animated: true)
    } else {
      UIApplication.shared.open(url)
    }
  }

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
  }
}

private extension MessageAttachmentEmbed {
  func setupViews() {
    addSubview(circleImageView)
    addSubview(messageLabel)
    addSubview(issueIdentifierLabel)

    NSLayoutConstraint.activate([
      circleImageView.leadingAnchor.constraint(
        equalTo: leadingAnchor,
        constant: Constants.horizontalPadding
      ),
      circleImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      circleImageView.widthAnchor.constraint(equalToConstant: 16),
      circleImageView.heightAnchor.constraint(equalToConstant: 16),

      messageLabel.leadingAnchor.constraint(
        equalTo: circleImageView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      issueIdentifierLabel.leadingAnchor.constraint(
        equalTo: messageLabel.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      issueIdentifierLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),
      issueIdentifierLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      heightAnchor.constraint(equalToConstant: MessageAttachmentEmbed.height),
    ])
  }

  func setupTapGesture() {
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tapGesture)
    isUserInteractionEnabled = true
  }

  func setupLayer() {
    layer.cornerRadius = Constants.cornerRadius
    layer.masksToBounds = true
  }

  func updateColors() {
    let textColor: UIColor = outgoing ? .white : .label
    let bgAlpha: CGFloat = outgoing ? 0.13 : 0.08
    backgroundColor = outgoing ? .white.withAlphaComponent(bgAlpha) : .systemGray.withAlphaComponent(bgAlpha)

    messageLabel.textColor = textColor
    issueIdentifierLabel.textColor = textColor.withAlphaComponent(0.8)
    circleImageView.tintColor = textColor
  }
}
