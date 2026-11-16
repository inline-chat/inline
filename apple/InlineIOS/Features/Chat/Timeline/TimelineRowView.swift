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
    /// A quiet line under the newest message with a moon, as `StatusNoticeCell` draws it.
    case notice
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
      updateReplyAction()
    }
  }
  private var replyAction: UIAccessibilityCustomAction?
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

  // Message actions button
  /// What the row's actions button does. It shows when the user gave the hold another action, so
  /// the message's menu stays one tap away, as `MessageCell` shows it.
  enum MessageActions {
    /// Opens the list's own message menu for this row.
    case open(() -> Void)
    /// UIKit's pull-down menu, while the list uses the system menu.
    case menu(() -> UIMenu)
  }

  var messageActions: MessageActions? {
    didSet { updateActionsButton() }
  }

  private var actionsButton: TimelineMessageActionsButton?

  /// Whether a point in this row is on the actions button, which keeps its own touches.
  func isActionsButton(at point: CGPoint) -> Bool {
    guard let actionsButton, !actionsButton.isHidden else { return false }
    return actionsButton.bounds.contains(actionsButton.convert(point, from: self))
  }

  private func updateActionsButton() {
    guard let messageActions else {
      actionsButton?.isHidden = true
      return
    }
    let button = actionsButton ?? {
      let button = TimelineMessageActionsButton(type: .system)
      button.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(
        pointSize: 17, weight: .medium
      )), for: .normal)
      button.tintColor = .secondaryLabel
      button.accessibilityLabel = "Message actions"
      button.accessibilityIdentifier = "messageActions"
      button.addAction(UIAction { [weak self] _ in
        guard case let .open(open)? = self?.messageActions else { return }
        open()
      }, for: .primaryActionTriggered)
      // The menu is read on each open, so a reused row or an update never shows old actions.
      button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
        guard case let .menu(menu)? = self?.messageActions else { return completion([]) }
        completion(menu().children)
      }])
      addSubview(button)
      actionsButton = button
      return button
    }()
    var showsMenu = false
    if case .menu = messageActions { showsMenu = true }
    button.showsMenuAsPrimaryAction = showsMenu
    setNeedsLayout()
  }

  /// On the empty side of the bubble, its bottom with the bubble's, a 44 pt target where the gutter
  /// allows, as `MessageCell` places it.
  private func layoutActionsButton() {
    guard let actionsButton, messageActions != nil else { return }
    // The message view's bubble-sized container also holds a bubbleless (large emoji) message.
    let bubbleView: UIView? = shownMessageView?.bubbleContentView ?? legacyView.map { legacy in
      legacy.fullMessage.message.isServiceMessage ? legacy.serviceContainerView : legacy.bubbleView
    }
    guard let bubbleView else {
      actionsButton.isHidden = true
      return
    }
    let outgoing = (shownMessageView?.content?.message ?? legacyView?.fullMessage)?.message.out == true
    let bubble = bubbleView.convert(bubbleView.bounds, to: self)
    let gutter = outgoing ? bubble.minX : bounds.width - bubble.maxX
    let width = min(44, max(0, gutter))
    let height = min(44, bounds.height)
    actionsButton.frame = CGRect(
      x: outgoing ? bubble.minX - width : bubble.maxX,
      y: min(max(0, bubble.maxY - height), max(0, bounds.height - height)),
      width: width,
      height: height
    )
    actionsButton.isHidden = width < 1
    bringSubviewToFront(actionsButton)
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

  /// Lays the continuous bubble gradient over the list's whole height: the bubble shows the slice
  /// of it where it is on screen, following the row's motion on the render server.
  func followScreen(_ screen: TimelineRowScreen) {
    if let messageView, !messageView.isHidden, let target = messageView.continuousGradient(in: self) {
      messageView.updateContinuousBubbleGradient(
        bubbleMinY: screen.y + target.frame.minY, bubbleHeight: target.frame.height, viewportHeight: screen.height
      )
      Self.follow(screen, target)
    } else if let legacyView, let target = legacyView.continuousGradient(in: self) {
      legacyView.updateContinuousBubbleGradient(
        bubbleMinY: screen.y + target.frame.minY, bubbleHeight: target.frame.height, viewportHeight: screen.height
      )
      Self.follow(screen, target)
    }
  }

  /// The gradient's ends are in unit coordinates of the bubble: a point of the row's travel moves
  /// both by `-1 / height`.
  private static func follow(_ screen: TimelineRowScreen, _ target: (layer: CALayer, frame: CGRect)) {
    guard target.frame.height > 1 else { return }
    let scale = -1 / target.frame.height
    for keyPath in ["startPoint", "endPoint"] {
      screen.follow(target.layer, keyPath: keyPath) { NSValue(cgPoint: CGPoint(x: 0, y: $0 * scale)) }
    }
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
  /// What the older view was built for, so a change it can take in place reaches it in place.
  private struct LegacyShown {
    var message: FullMessage
    var grouping: ChatRowGrouping
    var isThreadAnchor: Bool
    var width: CGFloat
    var theme: IOSThemeSnapshot
    var spaceId: Int64?
    /// The host's environment (text size, translation on or off): a new one rebuilds the view.
    var environment: UInt64
  }

  private var legacyShown: LegacyShown?

  func showLegacy(
    _ message: FullMessage, grouping: ChatRowGrouping, isThreadAnchor: Bool, width: CGFloat,
    theme: IOSThemeSnapshot, spaceId: Int64?, environment: UInt64 = 0
  ) {
    if updateLegacyInPlace(
      message, grouping: grouping, isThreadAnchor: isThreadAnchor, width: width, theme: theme, spaceId: spaceId,
      environment: environment
    ) {
      return
    }
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
    legacyShown = LegacyShown(
      message: message, grouping: grouping, isThreadAnchor: isThreadAnchor, width: width, theme: theme,
      spaceId: spaceId, environment: environment
    )
  }

  /// As the collection view's cell: the send's acknowledgement, acknowledgements, reactions (the changed
  /// one pops) and an outgoing bubble's tail change in place and animate; anything else rebuilds.
  private func updateLegacyInPlace(
    _ message: FullMessage, grouping: ChatRowGrouping, isThreadAnchor: Bool, width: CGFloat,
    theme: IOSThemeSnapshot, spaceId: Int64?, environment: UInt64
  ) -> Bool {
    guard let view = legacyView, let shown = legacyShown, !view.isHidden, shown.message.id == message.id,
          shown.isThreadAnchor == isThreadAnchor, abs(shown.width - width) <= 0.5, shown.theme == theme,
          shown.spaceId == spaceId, shown.environment == environment,
          shown.message.displayText == message.displayText,
          shown.message.message.out == message.message.out
    else { return false }
    let current = shown.message
    if shown.grouping == grouping {
      if current == message {
        // Nothing the view shows changed.
      } else if current.isDeliveryAcknowledgementUpdate(to: message) {
        view.updateDeliveryAcknowledgement(to: message)
      } else if current.isAcknowledgementOnlyUpdate(to: message), view.canUpdateAcknowledgementInPlace(to: message) {
        view.updateAcknowledgement(to: message)
      } else if current.isReactionOnlyUpdate(to: message), view.canUpdateReactionsInPlace(to: message) {
        view.updateReactions(to: message, animatedEmoji: current.changedReactionEmoji(to: message))
      } else {
        return false
      }
    } else {
      // Only the tail: the same message ends or stops ending a group, with no avatar or name to move.
      var tailOnly = shown.grouping
      tailOnly.isLastInGroup = grouping.isLastInGroup
      let isService = message.message.isServiceMessage
      guard current == message, tailOnly == grouping, !isService,
            message.message.out == true || !grouping.showsAvatar
      else { return false }
      let outgoing = message.message.out == true
      view.updateBubbleTail(side: grouping.isLastInGroup ? (outgoing ? .trailing : .leading) : .none, animated: true)
    }
    legacyShown?.message = message
    legacyShown?.grouping = grouping
    return true
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
      case .notice: label.font = .systemFont(ofSize: 12)
    }
    label.adjustsFontForContentSizeCategory = style != .notice
    label.textColor = .secondaryLabel
    label.accessibilityLabel = nil
    if style == .notice {
      let line = NSMutableAttributedString()
      if let moon = UIImage(
        systemName: "moon.fill", withConfiguration: UIImage.SymbolConfiguration(font: .systemFont(ofSize: 10))
      )?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
        line.append(NSAttributedString(attachment: NSTextAttachment(image: moon)))
        line.addAttribute(.kern, value: 4, range: NSRange(location: 0, length: line.length))
      }
      line.append(NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 12)]))
      label.attributedText = line
      label.accessibilityLabel = text
    }
    if style == .line, rules.isEmpty {
      rules = (0 ..< 2).map { _ in
        let rule = UIView()
        rule.backgroundColor = .separator
        addSubview(rule)
        return rule
      }
    }
    for rule in rules { rule.isHidden = style != .line }
    // A pill takes its own tap; the label is hidden behind it.
    onLabelTap = style == .pill ? nil : onTap
    label.isUserInteractionEnabled = onLabelTap != nil
    if onLabelTap != nil, labelTap == nil {
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
      pill.onTap = onTap
    } else {
      pill?.isHidden = true
      pill?.onTap = nil
    }
    setNeedsLayout()
  }

  @objc private func handleLabelTap() {
    onLabelTap?()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutActionsButton()
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

  static let focusHighlightFadeIn: TimeInterval = 0.18
  static let focusHighlightHold: TimeInterval = 1.0

  /// The highlight of the message a jump landed on, on its bubble (and media) as the collection view's
  /// cell draws it: an outgoing bubble lightens, an incoming one takes the primary colour. A row shown
  /// again while the highlight runs gets what is left of it, without the fade in.
  func highlightBubble(outgoing: Bool, theme: IOSThemeSnapshot, hold: TimeInterval, fadeIn: Bool) {
    let color = outgoing
      ? theme.outgoingBubble.uiColor.lighten(by: 0.3)
      : theme.primary.uiColor.withAlphaComponent(0.4)
    let fade = fadeIn ? Self.focusHighlightFadeIn : 0
    if let messageView = shownMessageView {
      messageView.bubbleView.highlight(color: color, fadeIn: fade, hold: hold)
    } else if let legacyView {
      legacyView.bubbleView.highlight(color: color, fadeIn: fade, hold: hold)
      legacyView.highlightMediaOverlay()
    }
  }

  /// A row reused for another message, or another row highlighted, must not carry this highlight.
  func clearHighlight() {
    messageView?.bubbleView.clearHighlight()
    legacyView?.bubbleView.clearHighlight()
    legacyView?.clearMediaHighlight()
  }

  func prepareForReuse() {
    accessibilityElementsHidden = false
    isMenuSourceHidden = false
    isSendTargetHidden = false
    replyMessage = nil
    messageActions = nil
    onAvatarTap = nil
    onLabelTap = nil
    label?.isUserInteractionEnabled = false
    removeLegacy()
    messageView?.onAvatarTap = nil
    messageView?.onPhotoTap = nil
    messageView?.onReactionsMenu = nil
    messageView?.onContentStateChange = nil
    messageView?.onRevealLineChange = nil
    clearHighlight()
    layer.removeAllAnimations()
  }

  private func removeLegacy() {
    legacyShown = nil
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

  /// VoiceOver's stand-in for the swipe. Custom actions on a container reach the elements inside it, so
  /// the bubble's text offers it too.
  private func updateReplyAction() {
    guard replyMessage != nil else {
      accessibilityCustomActions = nil
      return
    }
    let action = replyAction ?? UIAccessibilityCustomAction(name: "Reply") { [weak self] _ in
      guard let message = self?.replyMessage else { return false }
      ChatState.shared.setReplyingMessageId(peer: message.message.peerId, id: message.message.messageId)
      return true
    }
    replyAction = action
    if accessibilityCustomActions?.first !== action { accessibilityCustomActions = [action] }
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
    guard replyMessage != nil, !isActionsButton(at: gesture.location(in: self)) else { return false }
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

/// The row's message actions button; the container's tap that puts the keyboard away leaves it alone.
final class TimelineMessageActionsButton: UIButton {}
