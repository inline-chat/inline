import InlineCompatUI
import InlineKit
import InlineUI
import Translation
import UIKit

/// One home row: identity, title, timestamp, preview (or live typing activity) and badges.
/// Same metrics as the SwiftUI `ExperimentalChatListRow` for compact, standard and large.
final class ChatListCell: UICollectionViewListCell {
  static let reuseIdentifier = "ChatListCell"

  struct Metrics {
    let avatarSize: CGFloat
    let identitySize: CGFloat
    let threadIconSize: ThreadIconSize
    let threadIconShape: ThreadIconShape
    let iconContentScale: CGFloat
    let minimumHeight: CGFloat
    let spacing: CGFloat
    let previewLines: Int

    static func forLayout(_ mode: ChatListLayoutMode) -> Metrics {
      switch mode {
      case .compact:
        Metrics(avatarSize: 30, identitySize: 32, threadIconSize: .regular(32), threadIconShape: .none,
                iconContentScale: 1.15, minimumHeight: 44, spacing: 12, previewLines: 0)
      case .standard:
        Metrics(avatarSize: 44, identitySize: 44, threadIconSize: .large(44), threadIconShape: .circle,
                iconContentScale: 0.96, minimumHeight: 52, spacing: 10, previewLines: 1)
      case .large:
        Metrics(avatarSize: 56, identitySize: 56, threadIconSize: .large(56), threadIconShape: .circle,
                iconContentScale: 0.88, minimumHeight: 72, spacing: 12, previewLines: 2)
      }
    }
  }

  private let avatarView = UserAvatarLayerView()
  private let threadIconView = ThreadIconLayerView()
  private let identityContainer = UIView()
  private let titleLabel = UILabel()
  private let timestampLabel = UILabel()
  private let previewLabel = UILabel()
  private let activityLabel = UILabel()
  private let unreadBadge = BadgeLabel()
  private let activityBadge = UIImageView()
  private let dotView = UIView()
  private let pinView = UIImageView(image: UIImage(systemName: "pin.fill"))
  private var identityWidth: NSLayoutConstraint!
  private var identityHeight: NSLayoutConstraint!
  private var minimumHeight: NSLayoutConstraint!
  private var rowStack: UIStackView!
  private var textStack: UIStackView!
  private var titleRow: UIStackView!
  private var previewRow: UIStackView!

  private var activityToken: CompatObservationToken?
  private(set) var item: ChatListItemSnapshot?
  /// Lit while the chat is opening or open (the router's path), like Telegram's tapped row.
  var isLit = false {
    didSet { if oldValue != isLit { setNeedsUpdateConfiguration() } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUp() {
    identityContainer.translatesAutoresizingMaskIntoConstraints = false
    for view in [avatarView, threadIconView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      identityContainer.addSubview(view)
      NSLayoutConstraint.activate([
        view.centerXAnchor.constraint(equalTo: identityContainer.centerXAnchor),
        view.centerYAnchor.constraint(equalTo: identityContainer.centerYAnchor),
        view.widthAnchor.constraint(equalTo: identityContainer.widthAnchor),
        view.heightAnchor.constraint(equalTo: identityContainer.heightAnchor),
      ])
    }
    identityWidth = identityContainer.widthAnchor.constraint(equalToConstant: 44)
    identityHeight = identityContainer.heightAnchor.constraint(equalToConstant: 44)
    identityWidth.isActive = true
    identityHeight.isActive = true

    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

    timestampLabel.font = .preferredFont(forTextStyle: .footnote)
    timestampLabel.adjustsFontForContentSizeCategory = true
    timestampLabel.textColor = .tertiaryLabel
    timestampLabel.textAlignment = .right
    timestampLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    timestampLabel.setContentHuggingPriority(.required, for: .horizontal)

    pinView.tintColor = .tertiaryLabel
    pinView.preferredSymbolConfiguration = .init(textStyle: .caption2)
    pinView.setContentHuggingPriority(.required, for: .horizontal)

    previewLabel.font = .preferredFont(forTextStyle: .subheadline)
    previewLabel.adjustsFontForContentSizeCategory = true
    previewLabel.textColor = .secondaryLabel
    previewLabel.lineBreakMode = .byTruncatingTail
    previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    activityLabel.font = .preferredFont(forTextStyle: .subheadline)
    activityLabel.adjustsFontForContentSizeCategory = true
    activityLabel.textColor = .tintColor
    activityLabel.isHidden = true

    activityBadge.contentMode = .center
    activityBadge.tintColor = .white
    activityBadge.layer.cornerRadius = 9.5
    activityBadge.clipsToBounds = true
    activityBadge.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      activityBadge.widthAnchor.constraint(equalToConstant: 19),
      activityBadge.heightAnchor.constraint(equalToConstant: 19),
    ])

    dotView.layer.cornerRadius = 3.5
    dotView.translatesAutoresizingMaskIntoConstraints = false

    titleRow = UIStackView(arrangedSubviews: [titleLabel, pinView, timestampLabel])
    titleRow.axis = .horizontal
    titleRow.alignment = .firstBaseline
    titleRow.spacing = 7

    let badges = UIStackView(arrangedSubviews: [activityBadge, unreadBadge])
    badges.axis = .horizontal
    badges.spacing = 5
    badges.setContentHuggingPriority(.required, for: .horizontal)
    badges.setContentCompressionResistancePriority(.required, for: .horizontal)

    let previewStack = UIStackView(arrangedSubviews: [previewLabel, activityLabel])
    previewStack.axis = .vertical
    previewRow = UIStackView(arrangedSubviews: [previewStack, badges])
    previewRow.axis = .horizontal
    previewRow.alignment = .center
    previewRow.spacing = 8

    textStack = UIStackView(arrangedSubviews: [titleRow, previewRow])
    textStack.axis = .vertical
    textStack.spacing = 1

    rowStack = UIStackView(arrangedSubviews: [identityContainer, textStack])
    rowStack.axis = .horizontal
    rowStack.alignment = .center
    rowStack.spacing = 10
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(rowStack)
    contentView.addSubview(dotView)

    let inset = Theme.Layout.screenEdgeOpticalInset
    minimumHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: inset),
      rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -inset),
      rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
      rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
      minimumHeight,
      dotView.widthAnchor.constraint(equalToConstant: 7),
      dotView.heightAnchor.constraint(equalToConstant: 7),
      dotView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      dotView.trailingAnchor.constraint(equalTo: rowStack.leadingAnchor, constant: -6),
    ])
    accessories = []
    indentationWidth = 0
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    activityToken?.cancel()
    activityToken = nil
    isLit = false
  }

  func configure(
    _ item: ChatListItemSnapshot,
    layout: ChatListLayoutMode,
    badgeStyle: ExperimentalHomeUnreadBadgeStyle,
    verticalInset: CGFloat
  ) {
    self.item = item
    let metrics = Metrics.forLayout(layout)
    identityWidth.constant = metrics.identitySize
    identityHeight.constant = metrics.identitySize
    minimumHeight.constant = metrics.minimumHeight
    rowStack.spacing = metrics.spacing
    rowStack.alignment = .center
    for constraint in contentView.constraints where constraint.firstItem === rowStack {
      if constraint.firstAttribute == .top { constraint.constant = verticalInset }
      if constraint.firstAttribute == .bottom { constraint.constant = -verticalInset }
    }

    switch item.identity {
    case let .user(descriptor):
      avatarView.isHidden = false
      threadIconView.isHidden = true
      avatarView.configure(
        userID: descriptor.userID,
        firstName: descriptor.firstName,
        lastName: descriptor.lastName,
        email: descriptor.email,
        username: descriptor.username,
        stableAvatarIdentity: descriptor.stableAvatarIdentity,
        remoteURL: descriptor.remoteURL,
        localURL: descriptor.localURL,
        size: metrics.avatarSize
      )
    case let .thread(descriptor):
      showThreadIcon(ThreadIconDescriptor(
        emoji: descriptor.emoji, title: descriptor.title,
        isReplyThread: descriptor.isReplyThread, accessibilityLabel: descriptor.title
      ), metrics: metrics)
    case nil:
      showThreadIcon(ThreadIconDescriptor(emoji: nil, title: item.title), metrics: metrics)
    }

    let titleStyle: UIFont.TextStyle = layout == .compact ? .body : .callout
    titleLabel.font = .preferredFont(forTextStyle: titleStyle).withWeight(item.isUnread ? .semibold : .medium)
    titleLabel.textColor = layout == .compact ? UIColor.label.withAlphaComponent(0.88) : .label
    titleLabel.text = item.title

    let preview = resolvedPreview(for: item)
    let showsPreview = metrics.previewLines > 0
    previewRow.isHidden = !showsPreview
    previewLabel.numberOfLines = metrics.previewLines
    previewLabel.attributedText = preview.map { previewText(sender: resolvedSender(item), text: $0, layout: layout) }
    timestampLabel.text = layout != .compact && preview != nil ? item.timestampText : nil
    timestampLabel.isHidden = timestampLabel.text == nil
    pinView.isHidden = true

    let numbered = badgeStyle == .numbered && item.isUnread
    unreadBadge.text = "\(max(item.unreadCount, 1))"
    unreadBadge.backgroundColor = item.isProminent ? .tintColor : .systemGray2
    unreadBadge.textColor = item.isProminent ? .white : .systemBackground
    unreadBadge.isHidden = !numbered
    if let badge = item.activityBadge {
      activityBadge.isHidden = false
      activityBadge.image = UIImage(
        systemName: badge == .mention ? "at" : "heart.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: badge == .mention ? 10.5 : 9, weight: .bold)
      )
      activityBadge.backgroundColor = badge == .reaction
        ? (item.isProminent ? .systemPink : .systemGray2)
        : .tintColor
    } else {
      activityBadge.isHidden = true
    }
    if layout == .compact {
      // Compact rows carry their badges on the title line.
      titleRow.addArrangedSubview(activityBadge)
      titleRow.addArrangedSubview(unreadBadge)
    } else if let badges = previewRow.arrangedSubviews.last as? UIStackView, activityBadge.superview !== badges {
      badges.addArrangedSubview(activityBadge)
      badges.addArrangedSubview(unreadBadge)
    }

    dotView.isHidden = !(badgeStyle == .dot && item.isUnread)
    dotView.backgroundColor = item.isProminent ? .tintColor : .secondaryLabel

    observeActivity(for: item.peer)
    accessibilityLabel = accessibilityText(for: item, preview: preview)
    accessibilityTraits = .button
    isAccessibilityElement = true
  }

  private func showThreadIcon(_ descriptor: ThreadIconDescriptor, metrics: Metrics) {
    avatarView.isHidden = true
    threadIconView.isHidden = false
    threadIconView.configure(
      descriptor,
      size: metrics.threadIconSize,
      shape: metrics.threadIconShape,
      symbolColor: .mutedPrimary,
      contentScaleMultiplier: metrics.iconContentScale
    )
  }

  /// Live typing / uploading activity replaces the preview while it lasts.
  private func observeActivity(for peer: Peer) {
    activityToken?.cancel()
    let state = ComposeActions.shared.activityState(for: peer)
    activityToken = observe { [weak self, state] in
      guard let self else { return }
      let presentation = state.presentation
      activityLabel.text = presentation?.text
      let showsActivity = presentation != nil && !previewRow.isHidden
      if activityLabel.isHidden == showsActivity {
        UIView.transition(with: previewRow, duration: 0.18, options: .transitionCrossDissolve) {
          self.activityLabel.isHidden = !showsActivity
          self.previewLabel.isHidden = showsActivity
        }
      }
    }
  }

  private func resolvedPreview(for item: ChatListItemSnapshot) -> String? {
    let translated = TranslationState.shared.isTranslationEnabled(for: item.peer)
    let source = translated ? (item.translatedPreviewText ?? item.previewText) : item.previewText
    let trimmed = source?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  private func resolvedSender(_ item: ChatListItemSnapshot) -> String? {
    let sender = item.previewSenderName?.trimmingCharacters(in: .whitespacesAndNewlines)
    return sender?.isEmpty == false ? sender : nil
  }

  private func previewText(sender: String?, text: String, layout: ChatListLayoutMode) -> NSAttributedString {
    let font = UIFont.preferredFont(forTextStyle: .subheadline)
    let result = NSMutableAttributedString()
    if let sender {
      let separator = layout == .large ? "\n" : ": "
      result.append(NSAttributedString(string: sender + separator, attributes: [
        .font: font.withWeight(.medium),
        .foregroundColor: UIColor.label.withAlphaComponent(0.70),
      ]))
    }
    result.append(NSAttributedString(string: text, attributes: [
      .font: layout == .large && sender != nil ? font.withSize(font.pointSize - 1) : font,
      .foregroundColor: UIColor.secondaryLabel,
    ]))
    return result
  }

  private func accessibilityText(for item: ChatListItemSnapshot, preview: String?) -> String {
    var parts = [item.title]
    if let preview {
      if let sender = resolvedSender(item) { parts.append("\(sender): \(preview)") } else { parts.append(preview) }
    }
    if let time = item.timestampText { parts.append(time) }
    if let badge = item.activityBadge { parts.append(badge.accessibilityLabel.lowercased()) }
    if item.isUnread { parts.append(item.unreadCount > 0 ? "\(item.unreadCount) unread" : "unread") }
    if item.isPinned { parts.append("pinned") }
    return parts.joined(separator: ", ")
  }

  // MARK: Highlight

  override func updateConfiguration(using state: UICellConfigurationState) {
    var background = UIBackgroundConfiguration.listPlainCell()
    let lit = state.isHighlighted || state.isSelected || isLit
    background.backgroundColor = .clear
    background.customView = HighlightView.shared(for: self, isLit: lit)
    backgroundConfiguration = background
  }
}

/// Rounded, inset row highlight that fades out on release, like Telegram's chat list.
private final class HighlightView: UIView {
  private let fill = UIView()

  static func shared(for cell: UICollectionViewCell, isLit: Bool) -> HighlightView {
    let view = (cell.backgroundConfiguration?.customView as? HighlightView) ?? HighlightView()
    view.setLit(isLit)
    return view
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    fill.backgroundColor = .systemFill
    fill.layer.cornerRadius = 14
    fill.layer.cornerCurve = .continuous
    fill.alpha = 0
    addSubview(fill)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    fill.frame = bounds.insetBy(dx: 8, dy: 0)
  }

  func setLit(_ lit: Bool) {
    if lit {
      fill.layer.removeAllAnimations()
      fill.alpha = 1
    } else if fill.alpha > 0 {
      UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
        self.fill.alpha = 0
      }
    }
  }
}

/// Capsule count badge with monospaced digits.
final class BadgeLabel: UILabel {
  override init(frame: CGRect) {
    super.init(frame: frame)
    font = UIFont.monospacedDigitSystemFont(
      ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold
    )
    textAlignment = .center
    layer.cornerRadius = 9.5
    clipsToBounds = true
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(width: max(19, size.width + 12), height: 19)
  }
}
