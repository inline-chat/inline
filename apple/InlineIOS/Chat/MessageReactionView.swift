import InlineKit
import UIKit

class MessageReactionView: UIView {
  // MARK: - Properties

  let emoji: String
  let count: Int
  let byCurrentUser: Bool
  let outgoing: Bool

  var onTap: ((String) -> Void)?

  // MARK: - UI Components

  private lazy var containerView: UIView = {
    let view = UIView()
    UIView.performWithoutAnimation {
      view.layer.cornerRadius = 14
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var stackView: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 0
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var emojiLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 17)

    if emoji == "✓" || emoji == "✔️" {
      let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
      let checkmarkImage = UIImage(systemName: "checkmark", withConfiguration: config)?
        .withTintColor(UIColor(hex: "#2AAC28")!, renderingMode: .alwaysOriginal)
      let imageAttachment = NSTextAttachment()
      imageAttachment.image = checkmarkImage
      let attributedString = NSAttributedString(attachment: imageAttachment)
      label.attributedText = attributedString
    } else {
      label.text = emoji
    }

    return label
  }()

  private lazy var countLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 13)
    label.text = "\(count)"
    return label
  }()

  // MARK: - Initialization

  init(emoji: String, count: Int, byCurrentUser: Bool, outgoing: Bool) {
    self.emoji = emoji
    self.count = count
    self.byCurrentUser = byCurrentUser
    self.outgoing = outgoing

    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupView() {
    // Configure container appearance
    containerView.backgroundColor = byCurrentUser ?
      (outgoing ? UIColor.reactionBackgroundOutgoingSelf : UIColor.reactionBackgroundIncomingSelf) :
      (outgoing ? UIColor.reactionBackgroundOutgoing : UIColor.reactionBackgroundIncoming)

    // Configure text colors
    countLabel.textColor = outgoing ? .white : .label

    // Center the emoji and count labels
    stackView.distribution = .equalSpacing
    stackView.alignment = .center

    // Add subviews
    addSubview(containerView)
    containerView.addSubview(stackView)

    stackView.addArrangedSubview(emojiLabel)
    stackView.addArrangedSubview(countLabel)

    // Setup constraints
    NSLayoutConstraint.activate([
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 4),
      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      stackView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4),
    ])

    // Add tap gesture
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    containerView.addGestureRecognizer(tapGesture)
    containerView.isUserInteractionEnabled = true
  }

  // MARK: - Actions

  @objc private func handleTap() {
    onTap?(emoji)
  }

  // MARK: - Layout

  override var intrinsicContentSize: CGSize {
    let height = stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height + 8
    return CGSize(width: 48, height: height)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    intrinsicContentSize
  }

  func updateCount(_ newCount: Int, animated: Bool) {
    guard count != newCount else { return }

    if animated {
      UIView.animate(withDuration: 0.15, animations: {
        self.countLabel.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
      }) { _ in
        self.countLabel.text = "\(newCount)"
        UIView.animate(withDuration: 0.15) {
          self.countLabel.transform = .identity
        }
      }
    } else {
      countLabel.text = "\(newCount)"
    }
  }
}

extension UIColor {
  /// Background color for reactions on outgoing messages by others
  static let reactionBackgroundOutgoing = UIColor(.white).withAlphaComponent(0.3)

  /// Background color for reactions on outgoing messages by the current user
  static let reactionBackgroundOutgoingSelf = UIColor(.white).withAlphaComponent(0.4)

  /// Background color for reactions on incoming messages by the current user
  static let reactionBackgroundIncomingSelf = UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark ?
      UIColor(hex: "#4F4E52")! : UIColor(hex: "#DCDCDC")!
  }

  /// Background color for reactions on incoming messages by others
  static let reactionBackgroundIncoming = UIColor { traitCollection in
    traitCollection.userInterfaceStyle == .dark ?
      UIColor(hex: "#414044")! : UIColor(hex: "#EBEBEB")!
  }
}
