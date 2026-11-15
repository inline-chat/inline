import InlineIOSUI
import InlineKit
import InlineMessageLayout
import UIKit

/// One row of the timeline. A message is shown by the production `MessageView`; the kinds that
/// view does not support yet are shown by the older `UIMessageView`, measured with Auto Layout;
/// separators and notices are a label.
@MainActor
final class TimelineRowView: UIView {
  enum LabelStyle {
    /// A day: a small pill in the middle.
    case pill
    /// The unread line: text with a rule either side.
    case line
    case plain
    /// Tappable text, as the line without its rules (the collapsed-history row).
    case action
  }

  private var messageView: MessageView?
  private var legacyView: UIMessageView?
  private var legacyConstraints: [NSLayoutConstraint] = []
  /// The sender's name and avatar around an older view, as `MessageCell` draws them.
  private var legacyName: UILabel?
  private var legacyAvatar: UserAvatarView?
  private var labelTap: UITapGestureRecognizer?
  private var onLabelTap: (() -> Void)?
  /// The sender's avatar was tapped on a row shown by the older view.
  var onAvatarTap: (() -> Void)?
  private var label: UILabel?
  /// A day row: the plain style of the list's date badge.
  private var pill: TimelineDatePill?
  private var rules: [UIView] = []
  private var style = LabelStyle.plain

  // Swipe to reply
  /// The message a horizontal swipe on this row replies to; nil when the row can't be replied to.
  var replyMessage: FullMessage? {
    didSet {
      if replyMessage != nil { installSwipe() }
      swipe?.isEnabled = replyMessage != nil
      if replyMessage == nil { resetSwipe() }
    }
  }
  private var swipe: UIPanGestureRecognizer?
  private var swipeDirection = INUserSettings.current.messageGestures.swipeToReplyDirection
  private var swipeStart: CGFloat = 0
  private var swipeArmed = false
  private lazy var replyIndicator: ReplyIndicatorView = {
    let view = ReplyIndicatorView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
    view.isHidden = true
    addSubview(view)
    return view
  }()
  private static let swipeDistance: CGFloat = 80
  private static let replyIndicatorInset: CGFloat = 37

  /// The message view this row shows, when it shows one.
  var shownMessageView: MessageView? { messageView.flatMap { $0.isHidden ? nil : $0 } }
  /// The older message view this row shows for a kind the production view does not support.
  var shownLegacyView: UIMessageView? { legacyView }

  /// A sent message's row while its bubble is still flying in from the composer.
  var isSendTargetHidden = false {
    didSet { alpha = isSendTargetHidden ? 0 : 1 }
  }

  /// The bubble the context menu lifts out of the row, hidden while the menu draws it.
  var isMenuSourceHidden = false {
    didSet { updateMenuSourceVisibility() }
  }

  private func updateMenuSourceVisibility() {
    messageView?.bubbleContentView.isHidden = isMenuSourceHidden
    guard let legacyView else { return }
    let source: UIView = legacyView.fullMessage.message.isServiceMessage
      ? legacyView.serviceContainerView : legacyView.bubbleView
    source.isHidden = isMenuSourceHidden
  }

  /// The sender's avatar beside the message, where the row shows one: the view, and its bottom and
  /// height at rest in the row. The list keeps it in sight while the group is (sticky avatar).
  var pinnedAvatar: (view: UIView, bottom: CGFloat, height: CGFloat)? {
    if let messageView, !messageView.isHidden, let avatar = messageView.avatarView, !avatar.isHidden {
      let frame = avatar.untransformedFrame
      return (avatar, messageView.untransformedFrame.minY + frame.maxY, frame.height)
    }
    if let legacyAvatar {
      // Pinned to the row's bottom by its constraints.
      return (legacyAvatar, bounds.height, 28)
    }
    return nil
  }

  /// Where the bubble starts, the top of a group for its avatar.
  var bubbleTop: CGFloat {
    if let messageView, !messageView.isHidden { return messageView.bubbleContentView.frame.minY }
    if legacyView != nil { return legacyConstraints.first?.constant ?? 0 }
    return 0
  }

  /// The production message view, filling the row. The caller applies a plan to it.
  func showMessage() -> MessageView {
    removeLegacy()
    label?.isHidden = true
    pill?.isHidden = true
    for rule in rules { rule.isHidden = true }
    if let messageView {
      messageView.isHidden = false
      return messageView
    }
    let view = MessageView()
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    insertSubview(view, at: 0)
    messageView = view
    return view
  }

  /// A message kind the production view does not support: the older view, pinned as its cell
  /// pins it.
  func showLegacy(
    _ message: FullMessage, grouping: ChatRowGrouping, isThreadAnchor: Bool, width: CGFloat,
    theme: IOSThemeSnapshot, spaceId: Int64?
  ) {
    removeLegacy()
    messageView?.isHidden = true
    label?.isHidden = true
    pill?.isHidden = true
    for rule in rules { rule.isHidden = true }
    let outgoing = message.message.out == true
    let isService = message.message.isServiceMessage
    let tail: MessageBubbleTailSide = grouping.isLastInGroup && !isService ? (outgoing ? .trailing : .leading) : .none
    let avatarLane: CGFloat = grouping.showsAvatar ? 31 : 0
    let view = UIMessageView(
      fullMessage: message,
      spaceId: spaceId,
      displayMode: isThreadAnchor ? .threadAnchor : .normal,
      bubbleTailSide: tail,
      maximumBubbleContentWidth: min(600, (width - 16 - avatarLane) * 0.9),
      theme: theme
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    addSubview(view)
    legacyView = view
    updateMenuSourceVisibility()
    var top: CGFloat = isService ? 0 : (grouping.isFirstInGroup ? 6 : 1)
    var constraints: [NSLayoutConstraint] = []
    if !isService, !outgoing, grouping.showsSenderName {
      let name = UILabel()
      name.font = ChatTypography.font(13, weight: .medium, style: .caption1, compatibleWith: traitCollection)
      name.textColor = .secondaryLabel
      name.text = message.from?.firstName ?? "USER"
      name.translatesAutoresizingMaskIntoConstraints = false
      addSubview(name)
      legacyName = name
      let height = max(16, ceil(name.font.lineHeight))
      constraints += [
        name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
        name.heightAnchor.constraint(equalToConstant: height),
        // 9 pt after the avatar, as `MessageCell` places it; the lane adds 3 pt of gap to the avatar.
        name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 + max(0, avatarLane - 3) + 9),
        name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      ]
      top = height + 9
    }
    if !isService, !outgoing, grouping.showsAvatar, grouping.isLastInGroup || isThreadAnchor,
       let sender = message.senderInfo
    {
      let avatar = UserAvatarView()
      avatar.configure(with: sender, size: 28)
      avatar.translatesAutoresizingMaskIntoConstraints = false
      avatar.isUserInteractionEnabled = true
      avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap)))
      addSubview(avatar)
      legacyAvatar = avatar
      constraints += [
        avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
        avatar.bottomAnchor.constraint(equalTo: bottomAnchor),
        avatar.widthAnchor.constraint(equalToConstant: 28),
        avatar.heightAnchor.constraint(equalToConstant: 28),
      ]
    }
    // The view's top first: the height measure reads it.
    legacyConstraints = [
      view.topAnchor.constraint(equalTo: topAnchor, constant: top),
      view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 + avatarLane),
      view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    ] + constraints
    NSLayoutConstraint.activate(legacyConstraints)
  }

  @objc private func handleAvatarTap() {
    onAvatarTap?()
  }

  /// The height the older view needs at this width, with the row's top spacing.
  func legacyHeight(width: CGFloat) -> CGFloat {
    guard let legacyView else { return 0 }
    let top = legacyConstraints.first?.constant ?? 0
    let fitted = legacyView.systemLayoutSizeFitting(
      CGSize(width: width - 16, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
    )
    return ceil(fitted.height + top)
  }

  func showLabel(_ text: String, style: LabelStyle, theme: IOSThemeSnapshot, onTap: (() -> Void)? = nil) {
    removeLegacy()
    messageView?.isHidden = true
    self.style = style
    let label = label ?? {
      let label = UILabel()
      label.textAlignment = .center
      label.adjustsFontForContentSizeCategory = true
      addSubview(label)
      self.label = label
      return label
    }()
    label.isHidden = style == .pill
    label.text = text
    switch style {
      case .pill: label.font = .preferredFont(forTextStyle: .footnote)
      // As `MessageListSeparatorCell` draws it.
      case .line, .action: label.font = .systemFont(ofSize: 12, weight: .semibold)
      case .plain: label.font = .preferredFont(forTextStyle: .caption1)
    }
    label.textColor = .secondaryLabel
    if style == .line, rules.isEmpty {
      rules = (0 ..< 2).map { _ in
        let rule = UIView()
        rule.backgroundColor = .separator
        addSubview(rule)
        return rule
      }
    }
    for rule in rules { rule.isHidden = style != .line }
    onLabelTap = onTap
    label.isUserInteractionEnabled = onTap != nil
    if onTap != nil, labelTap == nil {
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleLabelTap))
      label.addGestureRecognizer(tap)
      labelTap = tap
    }
    if style == .pill {
      let pill = pill ?? {
        let pill = TimelineDatePill(floating: false)
        addSubview(pill)
        self.pill = pill
        return pill
      }()
      pill.isHidden = false
      pill.configure(title: text)
    } else {
      pill?.isHidden = true
    }
    setNeedsLayout()
  }

  @objc private func handleLabelTap() {
    onLabelTap?()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if let pill, !pill.isHidden { pill.frame = bounds }
    guard let label, !label.isHidden else { return }
    let size = label.sizeThatFits(CGSize(width: bounds.width - 32, height: bounds.height))
    label.frame = CGRect(
      x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height
    )
    if rules.count == 2, !rules[0].isHidden {
      let hairline = 1 / max(1, traitCollection.displayScale)
      let y = label.frame.midY - hairline / 2
      rules[0].frame = CGRect(x: 16, y: y, width: max(0, label.frame.minX - 10 - 16), height: hairline)
      rules[1].frame = CGRect(
        x: label.frame.maxX + 10, y: y, width: max(0, bounds.width - 16 - label.frame.maxX - 10), height: hairline
      )
    }
  }

  /// A short highlight for the row a jump landed on.
  func flash(theme: IOSThemeSnapshot) {
    let overlay = UIView(frame: bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.isUserInteractionEnabled = false
    overlay.backgroundColor = theme.primary.uiColor.withAlphaComponent(0.18)
    overlay.alpha = 0
    addSubview(overlay)
    UIView.animate(withDuration: 0.18, animations: { overlay.alpha = 1 }) { _ in
      UIView.animate(withDuration: 0.4, delay: 1.0, options: [], animations: { overlay.alpha = 0 }) { _ in
        overlay.removeFromSuperview()
      }
    }
  }

  func prepareForReuse() {
    isMenuSourceHidden = false
    isSendTargetHidden = false
    replyMessage = nil
    onAvatarTap = nil
    onLabelTap = nil
    label?.isUserInteractionEnabled = false
    removeLegacy()
    messageView?.onAvatarTap = nil
    messageView?.onPhotoTap = nil
    messageView?.onReactionsMenu = nil
    messageView?.onContentStateChange = nil
    messageView?.onRevealLineChange = nil
    layer.removeAllAnimations()
  }

  private func removeLegacy() {
    NSLayoutConstraint.deactivate(legacyConstraints)
    legacyConstraints = []
    legacyView?.removeFromSuperview()
    legacyView = nil
    legacyName?.removeFromSuperview()
    legacyName = nil
    legacyAvatar?.removeFromSuperview()
    legacyAvatar = nil
  }

  // MARK: - Swipe to reply

  private func installSwipe() {
    guard swipe == nil else { return }
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
    pan.delegate = self
    addGestureRecognizer(pan)
    swipe = pan
  }

  /// The views that slide with the finger.
  private var swipedViews: [UIView] {
    [messageView.flatMap { $0.isHidden ? nil : $0 }, legacyView, legacyName].compactMap(\.self)
  }

  @objc private func handleSwipe(_ pan: UIPanGestureRecognizer) {
    guard let message = replyMessage else {
      resetSwipe()
      return
    }
    let translation = pan.translation(in: self)
    switch pan.state {
      case .began:
        swipeDirection = INUserSettings.current.messageGestures.swipeToReplyDirection
        swipeStart = translation.x
        replyIndicator.center = CGPoint(
          x: swipeDirection.revealsLeftEdge ? Self.replyIndicatorInset : bounds.width - Self.replyIndicatorInset,
          y: bounds.midY
        )
        replyIndicator.isHidden = false
        replyIndicator.alpha = 1
        replyIndicator.reset()
      case .changed:
        let offset = translation.x - swipeStart
        guard swipeDirection.accepts(offset) else {
          for view in swipedViews { view.transform = .identity }
          replyIndicator.updateProgress(0)
          swipeArmed = false
          return
        }
        let progress = min(abs(offset) / Self.swipeDistance, 1)
        let shift = swipeDirection.horizontalSign * Self.swipeDistance * progress
        for view in swipedViews { view.transform = CGAffineTransform(translationX: shift, y: 0) }
        replyIndicator.updateProgress(progress)
        let armed = progress > 0.7
        if armed, !swipeArmed {
          let feedback = UIImpactFeedbackGenerator(style: .medium)
          feedback.prepare()
          feedback.impactOccurred()
        }
        swipeArmed = armed
      case .ended, .cancelled:
        let offset = translation.x - swipeStart
        let velocity = pan.velocity(in: self).x
        let progress = min(abs(offset) / Self.swipeDistance, 1)
        let replies = pan.state == .ended && swipeDirection.accepts(offset)
          && (progress > 0.7 || (abs(velocity) > 600 && swipeDirection.accepts(velocity)))
        if replies {
          ChatState.shared.setReplyingMessageId(peer: message.message.peerId, id: message.message.messageId)
        }
        let views = swipedViews
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
          for view in views { view.transform = .identity }
          self.replyIndicator.alpha = 0
        } completion: { [weak self] _ in
          self?.resetSwipe()
        }
      default:
        resetSwipe()
    }
  }

  private func resetSwipe() {
    guard swipe != nil else { return }
    for view in swipedViews { view.transform = .identity }
    replyIndicator.isHidden = true
    replyIndicator.alpha = 1
    replyIndicator.reset()
    swipeStart = 0
    swipeArmed = false
  }
}

extension TimelineRowView: UIGestureRecognizerDelegate {
  override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
    guard gesture === swipe else { return super.gestureRecognizerShouldBegin(gesture) }
    guard replyMessage != nil else { return false }
    // Code blocks and tables scroll sideways under the finger.
    if let messageView = shownMessageView, messageView.scrollsHorizontally(at: gesture.location(in: messageView)) {
      return false
    }
    let velocity = (gesture as? UIPanGestureRecognizer)?.velocity(in: self) ?? .zero
    // Nearly horizontal only (within 24°), in the direction the user picked.
    guard abs(velocity.x) > abs(velocity.y), abs(velocity.y) <= abs(velocity.x) * 0.4452286853 else { return false }
    return INUserSettings.current.messageGestures.swipeToReplyDirection.accepts(velocity.x)
  }

  func gestureRecognizer(
    _ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
  ) -> Bool {
    false
  }

  // A reply swipe on a message that can be replied to owns the touch; the back swipe proceeds only
  // when it is rejected.
  func gestureRecognizer(
    _ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
  ) -> Bool {
    gesture === swipe && other is UIScreenEdgePanGestureRecognizer
  }
}
