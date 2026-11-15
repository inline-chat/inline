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
  }

  private var messageView: MessageView?
  private var legacyView: UIMessageView?
  private var legacyConstraints: [NSLayoutConstraint] = []
  private var label: UILabel?
  private var pill: UIView?
  private var rules: [UIView] = []
  private var style = LabelStyle.plain

  /// The message view this row shows, when it shows one.
  var shownMessageView: MessageView? { messageView.flatMap { $0.isHidden ? nil : $0 } }
  /// The older message view this row shows for a kind the production view does not support.
  var shownLegacyView: UIMessageView? { legacyView }

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
    let top: CGFloat = isService ? 0 : (grouping.isFirstInGroup ? 6 : 1)
    legacyConstraints = [
      view.topAnchor.constraint(equalTo: topAnchor, constant: top),
      view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8 + avatarLane),
      view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
    ]
    NSLayoutConstraint.activate(legacyConstraints)
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

  func showLabel(_ text: String, style: LabelStyle, theme: IOSThemeSnapshot) {
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
    label.isHidden = false
    label.text = text
    switch style {
      case .pill: label.font = .preferredFont(forTextStyle: .footnote)
      // As `MessageListSeparatorCell` draws it.
      case .line: label.font = .systemFont(ofSize: 12, weight: .semibold)
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
    if style == .pill {
      let pill = pill ?? {
        let pill = UIView()
        insertSubview(pill, belowSubview: label)
        self.pill = pill
        return pill
      }()
      pill.isHidden = false
      pill.backgroundColor = theme.chatCanvas.uiColor.withAlphaComponent(0.85)
    } else {
      pill?.isHidden = true
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let label, !label.isHidden else { return }
    let size = label.sizeThatFits(CGSize(width: bounds.width - 32, height: bounds.height))
    label.frame = CGRect(
      x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height
    )
    if let pill, !pill.isHidden {
      pill.frame = label.frame.insetBy(dx: -10, dy: -5)
      pill.layer.cornerRadius = pill.bounds.height / 2
    }
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
  }
}
