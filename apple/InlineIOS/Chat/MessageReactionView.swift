import InlineKit
import UIKit

class MessageReactionView: UIView {
  // MARK: - Properties

  private let emoji: String
  private let count: Int
  private let byCurrentUser: Bool
  private let outgoing: Bool

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
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var emojiLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 17)
    label.text = emoji
    return label
  }()

  private lazy var countLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
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
      stackView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 6),
      stackView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -6),
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
    let stackSize = stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    return CGSize(width: stackSize.width + 5, height: stackSize.height + 8)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    intrinsicContentSize
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
