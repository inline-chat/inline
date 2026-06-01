import AppKit
import InlineKit

final class ReactionChipButton: NSButton {
  let emoji: String

  var group: GroupedReaction? {
    didSet {
      if oldValue != group {
        updateContent()
      }
    }
  }

  var isOutgoing: Bool = false {
    didSet { updateColors() }
  }

  var forceIncomingStyle: Bool = false {
    didSet { updateColors() }
  }

  var neutralStyle: Bool = false {
    didSet { updateColors() }
  }

  var backgroundOverride: (primary: NSColor, secondary: NSColor)? {
    didSet { updateColors() }
  }

  var foregroundOverride: NSColor? {
    didSet { updateColors() }
  }

  var currentUserId: Int64? {
    didSet { updateColors() }
  }

  var contextMenuProvider: (() -> NSMenu?)?

  private var avatarViews: [UserAvatarView] = []
  private var isPressed = false

  private let emojiLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = true
    label.isEditable = false
    label.isBordered = false
    label.backgroundColor = .clear
    label.font = .systemFont(ofSize: ReactionChipMetrics.emojiFontSize)
    label.lineBreakMode = .byClipping
    return label
  }()

  private let countLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = true
    label.isEditable = false
    label.isBordered = false
    label.backgroundColor = .clear
    label.font = .systemFont(ofSize: ReactionChipMetrics.textFontSize)
    label.lineBreakMode = .byClipping
    label.alignment = .center
    return label
  }()

  static let transparentOutgoingBackgrounds: (primary: NSColor, secondary: NSColor) = {
    let primary = NSColor(name: "transparentOutgoingReactionPrimary") { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 39 / 255, green: 38 / 255, blue: 46 / 255, alpha: 1.0)
        : NSColor(calibratedRed: 205 / 255, green: 208 / 255, blue: 208 / 255, alpha: 1.0)
    }
    let secondary = NSColor(name: "transparentOutgoingReactionSecondary") { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 49 / 255, green: 48 / 255, blue: 57 / 255, alpha: 1.0)
        : NSColor(calibratedRed: 215 / 255, green: 218 / 255, blue: 218 / 255, alpha: 1.0)
    }
    return (primary: primary, secondary: secondary)
  }()
  static let transparentOutgoingForeground: NSColor = .labelColor

  init(emoji: String) {
    self.emoji = emoji
    super.init(frame: .zero)

    wantsLayer = true
    layer?.masksToBounds = true
    PressScaleAnimator.prepare(self)

    isBordered = false
    title = ""
    setButtonType(.momentaryChange)
    focusRingType = .none

    addSubview(emojiLabel)
    addSubview(countLabel)

    emojiLabel.stringValue = emoji
    countLabel.isHidden = true
    updateContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()

    layer?.cornerRadius = bounds.height / 2

    emojiLabel.sizeToFit()
    let emojiSize = emojiLabel.intrinsicContentSize
    let emojiY = floor((bounds.height - emojiSize.height) / 2)
    emojiLabel.frame = CGRect(
      x: ReactionChipMetrics.padding,
      y: emojiY,
      width: ceil(emojiSize.width),
      height: ceil(emojiSize.height)
    )

    let x = ReactionChipMetrics.padding + ceil(emojiSize.width) + ReactionChipMetrics.spacing

    if countLabel.isHidden {
      for (index, avatarView) in avatarViews.enumerated() {
        let avatarX = x + CGFloat(index) * (ReactionChipMetrics.avatarSize - ReactionChipMetrics.avatarOverlap)
        let avatarY = floor((bounds.height - ReactionChipMetrics.avatarSize) / 2)
        avatarView.frame = CGRect(
          x: avatarX,
          y: avatarY,
          width: ReactionChipMetrics.avatarSize,
          height: ReactionChipMetrics.avatarSize
        )
      }
    } else {
      countLabel.sizeToFit()
      let countSize = countLabel.intrinsicContentSize
      let count = group?.reactions.count ?? Int(countLabel.stringValue) ?? 0
      let countWidth = max(ceil(countSize.width), ReactionChipMetrics.countWidth(for: count))
      let countY = floor((bounds.height - countSize.height) / 2)
      countLabel.frame = CGRect(
        x: x,
        y: countY,
        width: countWidth,
        height: ceil(countSize.height)
      )
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    contextMenuProvider?() ?? super.menu(for: event)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func highlight(_ flag: Bool) {
    super.highlight(flag)
    setPressed(flag)
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

  override func mouseDown(with event: NSEvent) {
    guard event.type == .leftMouseDown else {
      super.mouseDown(with: event)
      return
    }

    setPressed(true)
    guard let window else {
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
        setPressed(isInside)
      case .leftMouseUp:
        setPressed(false)
        if isInside {
          sendAction(action, to: target)
        }
        return
      default:
        break
      }
    }

    setPressed(false)
  }

  private var weReacted: Bool {
    guard let group, let currentUserId else { return false }
    return group.reactions.contains { $0.reaction.userId == currentUserId }
  }

  private func setPressed(_ pressed: Bool) {
    guard isPressed != pressed else { return }
    isPressed = pressed
    PressScaleAnimator.setPressed(pressed, on: self)
  }

  private func updateContent() {
    guard let group else {
      toolTip = nil
      return
    }

    toolTip = group.reactions.compactMap { reaction in
      if let currentUserId, reaction.reaction.userId == currentUserId {
        return "You"
      }

      if let user = reaction.userInfo?.user {
        return user.displayName
      }

      return ObjectCache.shared.getUser(id: reaction.reaction.userId)?.user.displayName
    }.joined(separator: ", ")

    let shouldShowAvatars = ReactionChipMetrics.showsAvatars(for: group.reactions.count)
    rebuildContent(shouldShowAvatars: shouldShowAvatars, group: group)
    updateColors()
    needsLayout = true
  }

  private func rebuildContent(shouldShowAvatars: Bool, group: GroupedReaction) {
    avatarViews.forEach { $0.removeFromSuperview() }
    avatarViews.removeAll()

    if shouldShowAvatars {
      countLabel.isHidden = true

      for fullReaction in group.reactions.prefix(ReactionChipMetrics.maxAvatars) {
        let userInfo = fullReaction.userInfo ?? ObjectCache.shared.getUser(id: fullReaction.reaction.userId)
        let avatarView = UserAvatarView(userInfo: userInfo ?? .deleted, size: ReactionChipMetrics.avatarSize)
        avatarView.translatesAutoresizingMaskIntoConstraints = true
        avatarView.acceptsMouseInteraction = false
        addSubview(avatarView)
        avatarViews.append(avatarView)
      }
    } else {
      countLabel.isHidden = false
      countLabel.stringValue = "\(group.reactions.count)"
    }
  }

  private func updateColors() {
    let background = backgroundColor
    layer?.backgroundColor = background.cgColor
    countLabel.textColor = foregroundColor
  }

  private var isDarkMode: Bool {
    effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  private var backgroundColor: NSColor {
    if let override = backgroundOverride {
      return weReacted ? override.primary : override.secondary
    }
    if neutralStyle {
      let base = NSColor.controlAccentColor
      return base.withAlphaComponent(weReacted ? 0.22 : 0.12)
    }
    if forceIncomingStyle {
      let base: NSColor = isDarkMode ? .white : .controlAccentColor
      return weReacted ? base.withAlphaComponent(0.9) : base.withAlphaComponent(0.2)
    }
    let base: NSColor = if isDarkMode {
      .white
    } else {
      isOutgoing ? .white : .controlAccentColor
    }

    return weReacted ? base.withAlphaComponent(0.9) : base.withAlphaComponent(0.2)
  }

  private var foregroundColor: NSColor {
    if let override = foregroundOverride {
      return override
    }
    if neutralStyle {
      return weReacted ? .labelColor : .controlAccentColor
    }
    if forceIncomingStyle {
      if isDarkMode {
        return weReacted ? .controlAccentColor : .white
      }
      return weReacted ? .white : .controlAccentColor
    }
    if isDarkMode {
      return weReacted ? .controlAccentColor : .white
    }

    if isOutgoing {
      return weReacted ? .controlAccentColor : .white
    }

    return weReacted ? .white : .controlAccentColor
  }
}
