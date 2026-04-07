import AppKit
import InlineKit

final class ReplyThreadSummaryView: NSView {
  private enum Constants {
    static let avatarSize: CGFloat = 16
    static let avatarOverlap: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
    static let contentSpacing: CGFloat = 6
    static let maxAvatars = 3
    static let unreadDotSize: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    static let minWidth: CGFloat = 200
    static let borderWidth: CGFloat = 1
  }

  var onTap: (() -> Void)?

  private var style: EmbeddedMessageView.EmbeddedMessageStyle
  private var avatarViews: [UserAvatarView] = []
  private var avatarsWidthConstraint: NSLayoutConstraint?
  private var minWidthConstraint: NSLayoutConstraint?
  private var unreadDotLeadingConstraint: NSLayoutConstraint?
  private var unreadDotWidthConstraint: NSLayoutConstraint?
  private var loading = false
  private var trackingAreaRef: NSTrackingArea?
  private var hovering = false {
    didSet { applyStyle() }
  }
  private var pressed = false {
    didSet { applyStyle() }
  }

  private lazy var avatarsContainer: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var replyCountLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var unreadDotView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.cornerRadius = Constants.unreadDotSize / 2
    return view
  }()

  private lazy var spinnerView: NSProgressIndicator = {
    let spinner = NSProgressIndicator()
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.isHidden = true
    return spinner
  }()

  private lazy var tapGesture: NSClickGestureRecognizer = {
    let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    gesture.numberOfClicksRequired = 1
    gesture.buttonMask = 0x1
    return gesture
  }()

  init(style: EmbeddedMessageView.EmbeddedMessageStyle) {
    self.style = style
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var wantsUpdateLayer: Bool {
    true
  }

  func setStyle(_ style: EmbeddedMessageView.EmbeddedMessageStyle) {
    guard self.style != style else { return }
    self.style = style
    applyStyle()
  }

  func update(replyCount: Int, recentAuthors: [UserInfo], hasUnread: Bool) {
    let countText = replyCount == 1 ? "1 reply" : "\(replyCount) replies"
    replyCountLabel.stringValue = countText
    unreadDotView.isHidden = !hasUnread
    unreadDotLeadingConstraint?.constant = hasUnread ? Constants.contentSpacing : 0
    unreadDotWidthConstraint?.constant = hasUnread ? Constants.unreadDotSize : 0
    updateAvatars(authors: recentAuthors)
    applyStyle()
  }

  func setLoading(_ loading: Bool) {
    guard self.loading != loading else { return }
    self.loading = loading
    spinnerView.isHidden = !loading
    if loading {
      spinnerView.startAnimation(nil)
    } else {
      spinnerView.stopAnimation(nil)
    }
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = Constants.cornerRadius
    layer?.borderWidth = Constants.borderWidth

    addSubview(avatarsContainer)
    addSubview(replyCountLabel)
    addSubview(unreadDotView)
    addSubview(spinnerView)
    addGestureRecognizer(tapGesture)

    avatarsWidthConstraint = avatarsContainer.widthAnchor.constraint(equalToConstant: 0)
    minWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: Constants.minWidth)
    minWidthConstraint?.priority = .defaultHigh

    unreadDotLeadingConstraint = unreadDotView.leadingAnchor.constraint(
      equalTo: replyCountLabel.trailingAnchor,
      constant: Constants.contentSpacing
    )
    unreadDotWidthConstraint = unreadDotView.widthAnchor.constraint(equalToConstant: Constants.unreadDotSize)

    NSLayoutConstraint.activate([
      minWidthConstraint!,

      avatarsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalPadding),
      avatarsContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatarsContainer.heightAnchor.constraint(equalToConstant: Constants.avatarSize),
      avatarsWidthConstraint!,

      replyCountLabel.leadingAnchor.constraint(
        equalTo: avatarsContainer.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      replyCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      unreadDotLeadingConstraint!,
      unreadDotView.centerYAnchor.constraint(equalTo: centerYAnchor),
      unreadDotWidthConstraint!,
      unreadDotView.heightAnchor.constraint(equalToConstant: Constants.unreadDotSize),

      spinnerView.leadingAnchor.constraint(
        greaterThanOrEqualTo: unreadDotView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      spinnerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Constants.horizontalPadding),
      spinnerView.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinnerView.widthAnchor.constraint(equalToConstant: 12),
      spinnerView.heightAnchor.constraint(equalToConstant: 12),

      replyCountLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinnerView.leadingAnchor, constant: -6),
    ])

    applyStyle()
  }

  private func updateAvatars(authors: [UserInfo]) {
    avatarViews.forEach { $0.removeFromSuperview() }
    avatarViews.removeAll()

    let visibleAuthors = Array(authors.prefix(Constants.maxAvatars))
    for (index, author) in visibleAuthors.enumerated() {
      let avatar = UserAvatarView(userInfo: author, size: Constants.avatarSize)
      avatar.translatesAutoresizingMaskIntoConstraints = false
      avatarsContainer.addSubview(avatar)
      avatarViews.append(avatar)

      let leading: NSLayoutConstraint = if index == 0 {
        avatar.leadingAnchor.constraint(equalTo: avatarsContainer.leadingAnchor)
      } else {
        avatar.leadingAnchor.constraint(
          equalTo: avatarViews[index - 1].trailingAnchor,
          constant: -Constants.avatarOverlap
        )
      }

      NSLayoutConstraint.activate([
        leading,
        avatar.centerYAnchor.constraint(equalTo: avatarsContainer.centerYAnchor),
        avatar.widthAnchor.constraint(equalToConstant: Constants.avatarSize),
        avatar.heightAnchor.constraint(equalToConstant: Constants.avatarSize),
      ])
    }

    let visibleCount = visibleAuthors.count
    let avatarsWidth: CGFloat = if visibleCount == 0 {
      0
    } else {
      Constants.avatarSize + CGFloat(visibleCount - 1) * (Constants.avatarSize - Constants.avatarOverlap)
    }
    avatarsWidthConstraint?.constant = avatarsWidth
  }

  private func applyStyle() {
    let baseAlpha: CGFloat
    let hoverAlpha: CGFloat
    let pressedAlpha: CGFloat
    let bgColor: NSColor
    let borderColor: NSColor

    switch style {
    case .colored:
      replyCountLabel.textColor = .labelColor
      unreadDotView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
      bgColor = .controlAccentColor
      baseAlpha = 0.08
      hoverAlpha = 0.12
      pressedAlpha = 0.17
      borderColor = NSColor.separatorColor.withAlphaComponent(0.35)
      spinnerView.appearance = nil
    case .white:
      replyCountLabel.textColor = NSColor.white.withAlphaComponent(0.96)
      unreadDotView.layer?.backgroundColor = NSColor.white.cgColor
      bgColor = .white
      baseAlpha = 0.09
      hoverAlpha = 0.14
      pressedAlpha = 0.2
      borderColor = NSColor.white.withAlphaComponent(0.2)
      spinnerView.appearance = NSAppearance(named: .darkAqua)
    }

    let alpha = pressed ? pressedAlpha : (hovering ? hoverAlpha : baseAlpha)
    layer?.backgroundColor = bgColor.withAlphaComponent(alpha).cgColor
    layer?.borderColor = borderColor.cgColor
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaRef {
      removeTrackingArea(trackingAreaRef)
    }

    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard onTap != nil else { return }
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard onTap != nil else { return }
    hovering = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    hovering = false
    pressed = false
  }

  @objc private func handleTap(_: NSClickGestureRecognizer) {
    guard onTap != nil else { return }
    pressed = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self else { return }
      self.pressed = self.hovering
    }
    onTap?()
  }
}
