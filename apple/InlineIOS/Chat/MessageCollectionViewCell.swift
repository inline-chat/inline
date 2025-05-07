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
  var avatarView: UserAvatarView?
  var avatarSpacerView: UIView?

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

    setupThreadHeaderViewsIfNeeded(fromOtherSender: fromOtherSender)
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

  public func highlightBubble() {
    guard let bubble = messageView?.bubbleView else { return }
    let originalColor = bubble.backgroundColor ?? .systemGray6
    let isEmojiOrSticker = messageView?.isEmojiOnlyMessage == true || messageView?.isSticker == true
    let highlightColor = isEmojiOrSticker ? ThemeManager.shared.selected.accent.withAlphaComponent(0.3) : originalColor
    UIView.animate(withDuration: 0.18, animations: {
      bubble.backgroundColor = highlightColor
    }) { _ in
      UIView.animate(withDuration: 0.5, delay: 0.2, options: [], animations: {
        bubble.backgroundColor = originalColor
      }, completion: nil)
    }
  }

  public func clearHighlight() {
    guard let bubble = messageView?.bubbleView else { return }
    bubble.layer.removeAllAnimations()
    bubble.backgroundColor = messageView?.bubbleColor
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
    avatarView?.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)

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
        self.avatarView?.transform = .identity
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
      self.avatarView?.transform = .identity
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
    avatarView?.transform = .identity
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

  func setupThreadHeaderViewsIfNeeded(fromOtherSender: Bool) {
    guard isThread, !outgoing else { return }

    let avatarSize: CGFloat = 32
    let avatarLeading: CGFloat = 2
    let nameLabelLeading: CGFloat = 6
    let nameLabelTop: CGFloat = 14

    let avatarOrSpacer: UIView
    if fromOtherSender, let from = message.senderInfo {
      let avatar = UserAvatarView()
      avatar.configure(with: from, size: avatarSize)
      avatar.translatesAutoresizingMaskIntoConstraints = false
      avatarView = avatar
      avatarOrSpacer = avatar
    } else {
      let spacer = UIView()
      spacer.translatesAutoresizingMaskIntoConstraints = false
      avatarOrSpacer = spacer
    }
    avatarSpacerView = avatarOrSpacer
    contentView.addSubview(avatarOrSpacer)

    NSLayoutConstraint.activate([
      avatarOrSpacer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
      avatarOrSpacer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: avatarLeading),
      avatarOrSpacer.widthAnchor.constraint(equalToConstant: avatarSize),
      avatarOrSpacer.heightAnchor.constraint(equalToConstant: avatarSize),
    ])

    if fromOtherSender {
      contentView.addSubview(nameLabel)
      NSLayoutConstraint.activate([
        nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: nameLabelTop),
        nameLabel.heightAnchor.constraint(equalToConstant: 16),
        nameLabel.leadingAnchor.constraint(equalTo: avatarOrSpacer.trailingAnchor, constant: nameLabelLeading),
      ])
    }
  }

  func setupBaseMessageConstraints() {
    let newMessageView = UIMessageView(fullMessage: message, spaceId: spaceId)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(newMessageView)

    let topConstraint: NSLayoutConstraint
    let leadingConstraint: NSLayoutConstraint
    let trailingConstraint: NSLayoutConstraint

    if isThread, fromOtherSender, !outgoing {
      topConstraint = newMessageView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2)
      if let avatarOrSpacer = avatarSpacerView {
        leadingConstraint = newMessageView.leadingAnchor.constraint(equalTo: avatarOrSpacer.trailingAnchor, constant: 6)
      } else {
        leadingConstraint = newMessageView.leadingAnchor
          .constraint(equalTo: contentView.leadingAnchor, constant: 44)
      }
      trailingConstraint = newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
    } else {
      topConstraint = newMessageView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: fromOtherSender ? 12 : 2
      )
      var leadingAnchor = contentView.leadingAnchor
      var leadingConstant: CGFloat = 0
      // Add spacer for incoming messages that are not fromOtherSender
      if isThread, !outgoing, !fromOtherSender {
        let avatarSize: CGFloat = 32
        let avatarLeading: CGFloat = 2
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spacer)
        NSLayoutConstraint.activate([
          spacer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
          spacer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: avatarLeading),
          spacer.widthAnchor.constraint(equalToConstant: avatarSize),
          spacer.heightAnchor.constraint(equalToConstant: avatarSize),
        ])
        leadingAnchor = spacer.trailingAnchor
        leadingConstant = 6
      }
      leadingConstraint = newMessageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingConstant)
      trailingConstraint = newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    }
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      topConstraint,
      newMessageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    messageView = newMessageView
  }

  // Add avatar if we have user info
  func resetCell() {
    messageView?.removeFromSuperview()
    if isThread {
      nameLabel.removeFromSuperview()
      avatarView?.removeFromSuperview()
      avatarView = nil
      avatarSpacerView?.removeFromSuperview()
      avatarSpacerView = nil
    }
  }
}

extension UIColor {
  func lighten(by percentage: CGFloat) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
    return UIColor(
      red: min(r + (1 - r) * percentage, 1.0),
      green: min(g + (1 - g) * percentage, 1.0),
      blue: min(b + (1 - b) * percentage, 1.0),
      alpha: a
    )
  }
}
