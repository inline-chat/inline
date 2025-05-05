import InlineKit
import InlineUI
import SwiftUI
import UIKit

protocol MessageCellDelegate: AnyObject {
  func didSwipeToReply(for message: FullMessage)
}

class MessageCollectionViewCell: UICollectionViewCell, UIGestureRecognizerDelegate {
  static let reuseIdentifier = "MessageCell"

  var messageView: UIMessageView?
  var avatarHostingController: UIHostingController<UserAvatar>?

  var isThread: Bool = false
  var outgoing: Bool = false
  var fromOtherSender: Bool = false
  var message: FullMessage!
  var spaceId: Int64 = 0

  private var panGesture: UIPanGestureRecognizer!
  private let replyIndicator = ReplyIndicatorView()
  private var swipeActive = false
  private var initialTranslation: CGFloat = 0

  weak var delegate: MessageCellDelegate?

  lazy var nameLabel: UILabel = {
    var label = UILabel()
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false

    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupContentSize()
    setupSwipeGestures()
    setupReplyIndicator()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with message: FullMessage, fromOtherSender: Bool, spaceId: Int64) {
    if self.message != nil {
      if self.message == message, self.fromOtherSender == fromOtherSender, self.spaceId == spaceId {
        // skip only if everything is exact match
        return
      }
    }

    // update it first
    self.message = message
    self.fromOtherSender = fromOtherSender
    self.spaceId = spaceId
    isThread = message.peerId.isThread
    outgoing = message.message.out == true

    resetCell()

    nameLabel.text = message.from?.firstName ?? "USER"

    setupIncomingThreadMessage()
    setupBaseMessageConstraints()

    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // resetCell()
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
    layoutIfNeeded()

    let targetSize = CGSize(
      width: layoutAttributes.frame.width,
      height: UIView.layoutFittingCompressedSize.height
    )

    let size = contentView.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )

    attributes.frame.size = size
    return attributes
  }
}

extension MessageCollectionViewCell {
  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer == panGesture else { return true }

    let velocity = panGesture.velocity(in: contentView)

    // Calculate angle and only allow nearly horizontal swipes
    // An 16 degree angle corresponds to tan(16°) ≈ 0.287
    // This means vertical component should be at most 0.287 times the horizontal component
    let maxAngleTangent: CGFloat = 0.287 // tan(16°)
    let isHorizontalEnough = abs(velocity.y) <= abs(velocity.x) * maxAngleTangent

    return abs(velocity.x) > abs(velocity.y) && isHorizontalEnough // Must be predominantly horizontal
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: contentView)
    let velocity = gesture.velocity(in: contentView)

    switch gesture.state {
      case .began:
        initialTranslation = translation.x
        replyIndicator.isHidden = false
        replyIndicator.alpha = 1
        replyIndicator.reset()
      case .changed:
        handleSwipeProgress(translation: translation, velocity: velocity)
      case .ended, .cancelled:
        finalizeSwipe(translation: translation, velocity: velocity)
      default:
        resetSwipeState()
    }
  }

  private func handleSwipeProgress(translation: CGPoint, velocity: CGPoint) {
    let adjustedTranslation = translation.x - initialTranslation
    let isTrailingSwipe = adjustedTranslation < 0

    guard isTrailingSwipe else {
      resetSwipeState()
      return
    }

    let maxTranslation: CGFloat = 80
    let progress = min(abs(adjustedTranslation) / maxTranslation, 1)
    let boundedTranslation = -maxTranslation * progress

    messageView?.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)
    nameLabel.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)
    avatarHostingController?.view.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)

    replyIndicator.isHidden = false
    replyIndicator.updateProgress(progress)

    if progress > 0.7 {
      // Play haptic feedback when swipe crosses the activation threshold
      if !swipeActive {
        let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
        feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
      }
      swipeActive = true
    } else {
      swipeActive = false
    }
  }

  private func finalizeSwipe(translation: CGPoint, velocity: CGPoint) {
    let adjustedTranslation = translation.x - initialTranslation
    let isTrailingSwipe = adjustedTranslation < 0

    // Only trigger for trailing swipes (left direction)
    guard isTrailingSwipe else {
      UIView.animate(withDuration: 0.4) {
        self.messageView?.transform = .identity
        self.nameLabel.transform = .identity
        self.avatarHostingController?.view.transform = .identity
      }
      resetSwipeState()
      return
    }

    let progress = min(abs(adjustedTranslation) / 80, 1)
    let shouldTrigger = progress > 0.7 || abs(velocity.x) > 600

    if shouldTrigger {
      ChatState.shared.setReplyingMessageId(peer: message.message.peerId, id: message.message.messageId)
    }

    UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
      self.messageView?.transform = .identity
      self.nameLabel.transform = .identity
      self.avatarHostingController?.view.transform = .identity
      self.replyIndicator.alpha = 0
    } completion: { _ in
      if shouldTrigger {
        self.delegate?.didSwipeToReply(for: self.message)
      }
      self.resetSwipeState()
    }
  }

  private func resetSwipeState() {
    replyIndicator.isHidden = true
    replyIndicator.alpha = 1
    replyIndicator.reset()
    initialTranslation = 0
    swipeActive = false

    messageView?.transform = .identity
    nameLabel.transform = .identity
    avatarHostingController?.view.transform = .identity
  }

  func setupReplyIndicator() {
    replyIndicator.translatesAutoresizingMaskIntoConstraints = false
    contentView.insertSubview(replyIndicator, belowSubview: messageView ?? UIView())
    replyIndicator.isHidden = true
    replyIndicator.alpha = 1

    NSLayoutConstraint.activate([
      replyIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      replyIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
      replyIndicator.widthAnchor.constraint(equalToConstant: 40),
      replyIndicator.heightAnchor.constraint(equalToConstant: 40),
    ])
  }

  func setupSwipeGestures() {
    panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    panGesture.delegate = self
    contentView.addGestureRecognizer(panGesture)
  }

  func setupContentSize() {
    contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  func setupBaseMessageConstraints() {
    let newMessageView = UIMessageView(fullMessage: message, spaceId: spaceId)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(newMessageView)

    let topConstraint: NSLayoutConstraint = if isThread, fromOtherSender, !outgoing {
      newMessageView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2)
    } else {
      newMessageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: fromOtherSender ? 12 : 2)
    }

    let leadingConstraint: NSLayoutConstraint = if isThread, !outgoing {
      if fromOtherSender, let avatarView = avatarHostingController?.view {
        newMessageView.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: -2)
      } else {
        newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10)
      }
    } else {
      newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
    }

    let trailingConstraint: NSLayoutConstraint = if isThread, !outgoing {
      newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
    } else {
      newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    }
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      topConstraint,
      newMessageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    messageView = newMessageView
  }

  func setupIncomingThreadMessage() {
    if isThread, fromOtherSender, !outgoing {
      contentView.addSubview(nameLabel)

      // Add avatar if we have user info
      if let from = message.senderInfo {
        let avatar = UserAvatar(userInfo: from, size: 32)
        let hostingController = UIHostingController(rootView: avatar)
        avatarHostingController = hostingController
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
          hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
          hostingController.view.widthAnchor.constraint(equalToConstant: 32),
          hostingController.view.heightAnchor.constraint(equalToConstant: 32),
          hostingController.view.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: 2
          ),
        ])
      }

      NSLayoutConstraint.activate([
        nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
        nameLabel.heightAnchor.constraint(equalToConstant: 16),
        nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
      ])
    }
  }

  func resetCell() {
    messageView?.removeFromSuperview()
    nameLabel.removeFromSuperview()
    avatarHostingController?.view.removeFromSuperview()
    avatarHostingController = nil
  }
}
