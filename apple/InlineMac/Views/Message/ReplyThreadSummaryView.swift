import AppKit
import InlineKit
import InlineMacUI

final class ReplyThreadSummaryView: NSView {
  static let baseHeight: CGFloat = 30
  static let titleExtraHeight: CGFloat = 16

  static func height(hasTitle: Bool) -> CGFloat {
    baseHeight + (hasTitle ? titleExtraHeight : 0)
  }

  private enum Constants {
    static let avatarSize: CGFloat = 16
    static let avatarOverlap: CGFloat = 6
    static let horizontalPadding: CGFloat = 8
    static let contentSpacing: CGFloat = 6
    static let maxAvatars = 3
    static let unreadDotSize: CGFloat = 6
    static let cornerRadius: CGFloat = 8
    static let minWidth: CGFloat = 200
    static let titleTopPadding: CGFloat = 7
    static let titledRowCenterOffset: CGFloat = 8
  }

  var onTap: ((NSEvent.ModifierFlags) -> Void)?
  var menuProvider: (() -> NSMenu?)?

  private var style: EmbeddedMessageView.EmbeddedMessageStyle
  private var avatarViews: [UserAvatarView] = []
  private var hasUnread = false
  private var hasTitle = false
  private var loading = false
  private var trackingAreaRef: NSTrackingArea?
  private var hovering = false {
    didSet { applyStyle() }
  }
  private var pressed = false

  private lazy var avatarsContainer: NSView = {
    let view = NSView()
    return view
  }()

  private lazy var titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.isHidden = true
    return label
  }()

  private lazy var replyCountLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
  }()

  private lazy var unreadDotView: NSView = {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.cornerRadius = Constants.unreadDotSize / 2
    return view
  }()

  private lazy var spinnerView: NSProgressIndicator = {
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.isHidden = true
    return spinner
  }()

  init(style: EmbeddedMessageView.EmbeddedMessageStyle) {
    self.style = style
    super.init(frame: .zero)
    setupView()
    installTrackingAreaIfNeeded()
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

  func update(
    kind: MessageThreadCard.Kind,
    messageCount: Int,
    recentAuthors: [UserInfo],
    hasUnread: Bool,
    title: String?
  ) {
    updateTitle(title)
    let countText: String
    switch kind {
    case .reply:
      countText = messageCount == 1 ? "1 reply" : "\(messageCount) replies"
    case .subthread:
      let count = messageCount == 1 ? "1 message" : "\(messageCount) messages"
      countText = "Subthread · \(count)"
    }
    replyCountLabel.stringValue = countText
    self.hasUnread = hasUnread
    unreadDotView.isHidden = !hasUnread
    updateAvatars(authors: recentAuthors)
    applyStyle()
    needsLayout = true
  }

  func setLoading(_ loading: Bool) {
    guard self.loading != loading else { return }
    self.loading = loading
    spinnerView.isHidden = !loading
    needsLayout = true
    if loading {
      spinnerView.startAnimation(nil)
    } else {
      spinnerView.stopAnimation(nil)
    }
  }

  func clear() {
    updateTitle(nil)
    replyCountLabel.stringValue = ""
    hasUnread = false
    unreadDotView.isHidden = true
    updateAvatars(authors: [])
    setLoading(false)
    hovering = false
    setPressed(false)
    isHidden = true
  }

  private func setupView() {
    // Placed by frame (message rows' `layoutParts`), and lays out its parts by frame (`layoutParts` here).
    translatesAutoresizingMaskIntoConstraints = true
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = Constants.cornerRadius
    layer?.borderWidth = 0
    PressScaleAnimator.prepare(self)

    addSubview(titleLabel)
    addSubview(avatarsContainer)
    addSubview(replyCountLabel)
    addSubview(unreadDotView)
    addSubview(spinnerView)

    applyStyle()
  }

  private func updateTitle(_ title: String?) {
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextHasTitle = title?.isEmpty == false
    hasTitle = nextHasTitle
    titleLabel.stringValue = nextHasTitle ? (title ?? "") : ""
    titleLabel.isHidden = !nextHasTitle
    replyCountLabel.font = .systemFont(
      ofSize: nextHasTitle ? NSFont.smallSystemFontSize : NSFont.systemFontSize
    )
    needsLayout = true
  }

  private func updateAvatars(authors: [UserInfo]) {
    avatarViews.forEach { $0.removeFromSuperview() }
    avatarViews.removeAll()

    for author in authors.prefix(Constants.maxAvatars) {
      let avatar = UserAvatarView(userInfo: author, size: Constants.avatarSize)
      avatarsContainer.addSubview(avatar)
      avatarViews.append(avatar)
    }
    avatarsContainer.isHidden = avatarViews.isEmpty
    needsLayout = true
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { needsLayout = true }
  }

  override func layout() {
    super.layout()
    layoutParts()
  }

  /// The constraints' geometry, by frame: an optional title on top; then a row (lower by 8 pt under a title) of
  /// overlapping avatars, the count (shrinking first), the unread dot after it, and the spinner at the trailing edge.
  /// Message rows place this view by frame, so none of it joins the window's layout engine.
  private func layoutParts() {
    let size = bounds.size
    guard size.width > 0, size.height > 0 else { return }
    let padding = Constants.horizontalPadding
    let mirrored = userInterfaceLayoutDirection == .rightToLeft
    func place(_ view: NSView, in container: NSView, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) {
      let containerSize = container.bounds.size
      let width = max(0, width), height = max(0, height)
      let alignmentRect = NSRect(
        x: mirrored ? containerSize.width - x - width : x,
        y: containerSize.height - top - height,
        width: width,
        height: height
      )
      let frame = container.backingAlignedRect(
        view.frame(forAlignmentRect: alignmentRect), options: .alignAllEdgesNearest
      )
      if view.frame != frame { view.frame = frame }
    }

    if hasTitle {
      let title = titleLabel.intrinsicContentSize
      place(
        titleLabel, in: self, x: padding, top: Constants.titleTopPadding,
        width: min(title.width, size.width - 2 * padding), height: title.height
      )
    }

    let rowCenter = size.height / 2 + (hasTitle ? Constants.titledRowCenterOffset : 0)
    let avatarCount = CGFloat(avatarViews.count)
    let avatarsWidth = avatarViews.isEmpty
      ? 0 : Constants.avatarSize + (avatarCount - 1) * (Constants.avatarSize - Constants.avatarOverlap)
    place(
      avatarsContainer, in: self, x: padding, top: rowCenter - Constants.avatarSize / 2,
      width: avatarsWidth, height: Constants.avatarSize
    )
    for (index, avatar) in avatarViews.enumerated() {
      place(
        avatar, in: avatarsContainer, x: CGFloat(index) * (Constants.avatarSize - Constants.avatarOverlap), top: 0,
        width: Constants.avatarSize, height: Constants.avatarSize
      )
    }

    let spinnerWidth: CGFloat = loading ? 12 : 0
    let spinnerX = size.width - padding - spinnerWidth
    place(spinnerView, in: self, x: spinnerX, top: rowCenter - 6, width: spinnerWidth, height: 12)

    let dotLeading = hasUnread ? Constants.contentSpacing : 0
    let dotWidth = hasUnread ? Constants.unreadDotSize : 0
    let countX = padding + avatarsWidth + (avatarViews.isEmpty ? 0 : Constants.contentSpacing)
    let count = replyCountLabel.intrinsicContentSize
    // The count gives way first: the dot keeps 6 pt from the spinner, the count 6 pt from the dot.
    let countWidth = min(count.width, spinnerX - Constants.contentSpacing - dotWidth - dotLeading - countX)
    place(replyCountLabel, in: self, x: countX, top: rowCenter - count.height / 2, width: countWidth, height: count.height)
    place(
      unreadDotView, in: self, x: countX + max(0, countWidth) + dotLeading, top: rowCenter - Constants.unreadDotSize / 2,
      width: dotWidth, height: Constants.unreadDotSize
    )
  }

  private func applyStyle() {
    let baseAlpha: CGFloat
    let hoverAlpha: CGFloat
    let pressedAlpha: CGFloat
    let bgColor: NSColor

    switch style {
    case .colored:
      titleLabel.textColor = .labelColor
      replyCountLabel.textColor = hasTitle ? .secondaryLabelColor : .labelColor
      unreadDotView.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
      bgColor = .labelColor
      baseAlpha = 0.055
      hoverAlpha = 0.08
      pressedAlpha = 0.11
      spinnerView.appearance = nil
    case .white:
      titleLabel.textColor = NSColor.white.withAlphaComponent(0.96)
      replyCountLabel.textColor = NSColor.white.withAlphaComponent(hasTitle ? 0.72 : 0.96)
      unreadDotView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.8).cgColor
      bgColor = .white
      baseAlpha = 0.1
      hoverAlpha = 0.14
      pressedAlpha = 0.18
      spinnerView.appearance = NSAppearance(named: .darkAqua)
    }

    let alpha = pressed ? pressedAlpha : (hovering ? hoverAlpha : baseAlpha)
    layer?.backgroundColor = bgColor.withAlphaComponent(alpha).cgColor
  }

  private func setPressed(_ pressed: Bool) {
    guard self.pressed != pressed else { return }
    self.pressed = pressed
    applyStyle()
    PressScaleAnimator.setPressed(pressed, on: self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      setPressed(false)
    } else {
      layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0
      PressScaleAnimator.prepare(self)
    }
  }

  /// `.inVisibleRect` follows the view's bounds, so the area is added once instead of being
  /// rebuilt on every tracking pass.
  private func installTrackingAreaIfNeeded() {
    guard trackingAreaRef == nil else { return }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingAreaRef = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard onTap != nil else { return }
    hovering = true
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    hovering = false
    setPressed(false)
  }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.debug(
      "ReplyThreadSummaryView.mouseDown type=\(event.type.rawValue) clicks=\(event.clickCount) point=\(MessageGestureTrace.point(convert(event.locationInWindow, from: nil))) hasTap=\(onTap != nil)"
    )
    guard onTap != nil, event.type == .leftMouseDown else {
      MessageGestureTrace.debug("ReplyThreadSummaryView.mouseDown forwardingToSuper")
      super.mouseDown(with: event)
      return
    }

    setPressed(true)
    guard let window else {
      MessageGestureTrace.debug("ReplyThreadSummaryView.mouseDown noWindow")
      setPressed(false)
      return
    }

    while let next = window.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp],
      until: .distantFuture,
      inMode: .eventTracking,
      dequeue: true
    ) {
      let isInside = bounds.contains(convert(next.locationInWindow, from: nil))
      switch next.type {
      case .leftMouseDragged:
        MessageGestureTrace.trace(
          "ReplyThreadSummaryView.mouseDragged inside=\(isInside) point=\(MessageGestureTrace.point(convert(next.locationInWindow, from: nil)))"
        )
        setPressed(isInside)
      case .leftMouseUp:
        setPressed(false)
        if isInside {
          MessageGestureTrace.debug("ReplyThreadSummaryView.mouseUp action=onTap modifiers=\(next.modifierFlags.rawValue)")
          onTap?(next.modifierFlags)
        } else {
          MessageGestureTrace.debug("ReplyThreadSummaryView.mouseUp cancelledOutside")
        }
        return
      default:
        break
      }
    }

    MessageGestureTrace.debug("ReplyThreadSummaryView.mouseDown trackingEndedWithoutMouseUp")
    setPressed(false)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let menu = menuProvider?() else { return super.menu(for: event) }
    return ContextMenu.intercept(menu, for: event, in: self)
  }

  override func rightMouseDown(with event: NSEvent) {
    guard let menu = menuProvider?() else {
      super.rightMouseDown(with: event)
      return
    }

    ContextMenu.popUp(menu, with: event, for: self)
  }

  override var acceptsFirstResponder: Bool {
    onTap != nil
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49, let onTap {
      onTap(event.modifierFlags)
      return
    }
    super.keyDown(with: event)
  }

  override func isAccessibilityElement() -> Bool {
    true
  }

  override func accessibilityRole() -> NSAccessibility.Role? {
    .button
  }

  override func accessibilityLabel() -> String? {
    [titleLabel.stringValue, replyCountLabel.stringValue, unreadDotView.isHidden ? nil : "Unread"]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }

  override func accessibilityPerformPress() -> Bool {
    guard let onTap else { return false }
    onTap([])
    return true
  }
}
