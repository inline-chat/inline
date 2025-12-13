import AppKit
import Auth
import InlineKit
import Logger
import QuartzCore
import RealtimeV2

enum ReactionPillMetrics {
  static let padding: CGFloat = 6
  static let spacing: CGFloat = 4
  static let height: CGFloat = 28
  static let emojiFontSize: CGFloat = 14
  static let textFontSize: CGFloat = 12
  static let avatarSize: CGFloat = 20
  static let avatarOverlap: CGFloat = 4
  static let maxAvatars: Int = 3
  static let emojiWidthAdjustment: CGFloat = -2

  static func size(group: GroupedReaction) -> CGSize {
    let measuredEmojiWidth = group.emoji.size(withAttributes: [.font: NSFont.systemFont(ofSize: emojiFontSize)]).width
    let emojiWidth = measuredEmojiWidth

    // Number variant width
    let countWidth = "\(group.reactions.count)".size(withAttributes: [.font: NSFont.systemFont(ofSize: textFontSize)])
      .width
    let widthCount = emojiWidth + countWidth + spacing + padding * 2

    // Avatar variant width (up to maxAvatars avatars)
    let avatarCount = min(maxAvatars, group.reactions.count)
    let avatarsWidth = avatarCount > 0 ? avatarSize + CGFloat(avatarCount - 1) * (avatarSize - avatarOverlap) : 0
    let widthAvatar = emojiWidth + spacing + avatarsWidth + padding * 2

    let finalWidth = max(widthCount, widthAvatar)
    return CGSize(width: ceil(finalWidth), height: height)
  }
}

struct ReactionPillContent {
  var emoji: String
  var isOutgoing: Bool
  var weReacted: Bool
  var count: Int
  var showsAvatars: Bool
  var avatarUsers: [(userId: Int64, user: User?)]
  var tooltip: String
}

private final class ReactionSubviewsSortContext {
  let indicesByViewId: [ObjectIdentifier: Int]
  init(indicesByViewId: [ObjectIdentifier: Int]) { self.indicesByViewId = indicesByViewId }
}

private func compareReactionSubviews(_ a: NSView, _ b: NSView, _ context: UnsafeMutableRawPointer?) -> ComparisonResult {
  guard let context else { return .orderedSame }
  let indicesByViewId = Unmanaged<ReactionSubviewsSortContext>.fromOpaque(context).takeUnretainedValue().indicesByViewId
  guard let ai = indicesByViewId[ObjectIdentifier(a)], let bi = indicesByViewId[ObjectIdentifier(b)] else { return .orderedSame }
  if ai == bi { return .orderedSame }
  return ai < bi ? .orderedAscending : .orderedDescending
}

@MainActor
final class MessageReactionsView: NSView {
  private let log = Log.scoped("MessageReactionsView", enableTracing: false)

  // Keep these in sync with `MessageListAppKit.applyUpdate` row-height animations.
  private static let messageListRowAnimationDuration: TimeInterval = 0.15
  private static let messageListRowTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

  private var reactions: [GroupedReaction] = []
  private var plans: [String: MessageSizeCalculator.LayoutPlan] = [:]
  private var fullMessage: FullMessage?
  private var currentUserId: Int64? = Auth.shared.currentUserId

  private var pillViewsByEmoji: [String: ReactionPillView] = [:]
  private var emojisAppearing: Set<String> = []
  private var emojisBeingRemoved: Set<String> = []
  private var isAnimatingLayout = false

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(
    reactions: [GroupedReaction],
    plans: [String: MessageSizeCalculator.LayoutPlan],
    fullMessage: FullMessage?,
    animated: Bool
  ) {
    currentUserId = Auth.shared.currentUserId
    self.fullMessage = fullMessage
    self.plans = plans

    let nextOrder = reactions.map(\.emoji)
    let nextSet = Set(nextOrder)
    let prevSet = Set(self.reactions.map(\.emoji))

    // Update existing + add new
    for group in reactions {
      let emoji = group.emoji
      let content = makeContent(for: group, currentUserId: currentUserId)
      let onClick: () -> Void = { [weak self] in
        guard let self else { return }
        self.toggleReaction(emoji: emoji)
      }

      if let view = pillViewsByEmoji[group.emoji] {
        view.update(content: content, animated: animated, onClick: onClick)
      } else {
        let view = ReactionPillView()
        view.update(content: content, animated: false, onClick: onClick)
        pillViewsByEmoji[group.emoji] = view
        addSubview(view)

        // Start hidden for the appear animation.
        if animated {
          emojisAppearing.insert(emoji)
          prepareForAppear(view)
        }
      }
    }

    // Remove missing
    let removed = prevSet.subtracting(nextSet)
    for emoji in removed {
      guard let view = pillViewsByEmoji[emoji], emojisBeingRemoved.contains(emoji) == false else { continue }
      emojisBeingRemoved.insert(emoji)
      animateRemove(view: view, emoji: emoji, animated: animated)
    }

    self.reactions = reactions

    // Keep the z-order stable with the incoming order (not strictly necessary but helps hit testing).
    reorderSubviews(to: nextOrder)

    applyLayout(animated: animated)
  }

  override func layout() {
    super.layout()
    guard isAnimatingLayout == false else { return }
    applyLayout(animated: false)
  }

  private func reorderSubviews(to order: [String]) {
    // `sortSubviews` keeps existing view instances.
    var indicesByViewId: [ObjectIdentifier: Int] = [:]
    indicesByViewId.reserveCapacity(order.count)
    for (index, emoji) in order.enumerated() {
      guard let view = pillViewsByEmoji[emoji] else { continue }
      indicesByViewId[ObjectIdentifier(view)] = index
    }

    let context = ReactionSubviewsSortContext(indicesByViewId: indicesByViewId)
    let contextPtr = Unmanaged.passUnretained(context).toOpaque()
    withExtendedLifetime(context) {
      sortSubviews(compareReactionSubviews, context: contextPtr)
    }
  }

  private func applyLayout(animated: Bool) {
    let frames = makeTargetFrames()

    guard animated else {
      for (emoji, frame) in frames {
        guard let view = pillViewsByEmoji[emoji], emojisBeingRemoved.contains(emoji) == false else { continue }
        view.frame = frame
        if view.alphaValue != 1 { view.alphaValue = 1 }
      }
      return
    }

    let duration = Self.messageListRowAnimationDuration
    isAnimatingLayout = true

    NSAnimationContext.runAnimationGroup { [weak self] context in
      guard let self else { return }
      context.duration = duration
      context.timingFunction = Self.messageListRowTimingFunction

      for (emoji, frame) in frames {
        guard let view = pillViewsByEmoji[emoji], emojisBeingRemoved.contains(emoji) == false else { continue }

        view.animator().frame = frame

        if emojisAppearing.contains(emoji) {
          emojisAppearing.remove(emoji)
          animateAppear(view, duration: duration)
        }
      }
    } completionHandler: { [weak self] in
      self?.isAnimatingLayout = false
    }
  }

  private func prepareForAppear(_ view: NSView) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 0
    layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
    CATransaction.commit()
  }

  private func animateAppear(_ view: NSView, duration: TimeInterval) {
    guard let layer = view.layer else { return }

    // Set final state without implicit animations.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    CATransaction.commit()

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1

    let transform = CABasicAnimation(keyPath: "transform")
    transform.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.92, 0.92, 1))
    transform.toValue = NSValue(caTransform3D: CATransform3DIdentity)

    let group = CAAnimationGroup()
    group.animations = [opacity, transform]
    group.duration = duration
    group.timingFunction = Self.messageListRowTimingFunction
    group.isRemovedOnCompletion = true

    layer.add(group, forKey: "reactionAppear")
  }

  private func makeTargetFrames() -> [String: CGRect] {
    if plans.isEmpty {
      // Fallback: compute locally (shouldn't happen in normal flow, but keeps the view resilient).
      let maxWidth = max(0, bounds.width)
      let computed = ReactionLayout.compute(reactions: reactions, maxWidth: maxWidth)
      return computed.frames
    }

    var result: [String: CGRect] = [:]
    for group in reactions {
      guard let plan = plans[group.emoji] else { continue }
      result[group.emoji] = CGRect(
        x: plan.spacing.left,
        y: plan.spacing.top,
        width: plan.size.width,
        height: plan.size.height
      )
    }
    return result
  }

  private func makeContent(for group: GroupedReaction, currentUserId: Int64?) -> ReactionPillContent {
    let isOutgoing = fullMessage?.message.out ?? false
    let weReacted = currentUserId.map { userId in
      group.reactions.contains { $0.reaction.userId == userId }
    } ?? false

    let count = group.reactions.count
    let showsAvatars = count <= ReactionPillMetrics.maxAvatars
    let avatarReactions = group.reactions.prefix(ReactionPillMetrics.maxAvatars)
    let avatarUsers: [(userId: Int64, user: User?)] = avatarReactions.map { fullReaction in
      let userId = fullReaction.reaction.userId
      let user = fullReaction.userInfo?.user ?? ObjectCache.shared.getUser(id: userId)?.user
      return (userId, user)
    }

    let tooltip = group.reactions.compactMap { reaction in
      if let currentUserId, reaction.reaction.userId == currentUserId { return "You" }
      return ObjectCache.shared.getUser(id: reaction.reaction.userId)?.user.displayName
    }.joined(separator: ", ")

    return ReactionPillContent(
      emoji: group.emoji,
      isOutgoing: isOutgoing,
      weReacted: weReacted,
      count: count,
      showsAvatars: showsAvatars,
      avatarUsers: avatarUsers,
      tooltip: tooltip
    )
  }

  private func toggleReaction(emoji: String) {
    guard let fullMessage else { return }
    guard let currentUserId else { return }

    let weReacted = reactions.first(where: { $0.emoji == emoji })?.reactions.contains(where: { $0.reaction.userId == currentUserId }) ?? false

    Task(priority: .userInitiated) { @MainActor in
      if weReacted {
        try await Api.realtime.send(.deleteReaction(
          emoji: emoji,
          message: fullMessage.message
        ))
      } else {
        try await Api.realtime.send(.addReaction(
          emoji: emoji,
          message: fullMessage.message
        ))
      }
    }
  }

  private func animateRemove(view: ReactionPillView, emoji: String, animated: Bool) {
    guard animated else {
      view.removeFromSuperview()
      pillViewsByEmoji[emoji] = nil
      emojisBeingRemoved.remove(emoji)
      return
    }

    let duration = Self.messageListRowAnimationDuration

    if let layer = view.layer {
      // Final state (no implicit animations).
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.opacity = 0
      layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
      CATransaction.commit()

      let opacity = CABasicAnimation(keyPath: "opacity")
      opacity.fromValue = 1
      opacity.toValue = 0

      let transform = CABasicAnimation(keyPath: "transform")
      transform.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
      transform.toValue = NSValue(caTransform3D: CATransform3DMakeScale(0.92, 0.92, 1))

      let group = CAAnimationGroup()
      group.animations = [opacity, transform]
      group.duration = duration
      group.timingFunction = Self.messageListRowTimingFunction
      group.isRemovedOnCompletion = true
      layer.add(group, forKey: "reactionDisappear")
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = Self.messageListRowTimingFunction
        view.animator().alphaValue = 0
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
      guard let self else { return }
      view.removeFromSuperview()
      self.pillViewsByEmoji[emoji] = nil
      self.emojisBeingRemoved.remove(emoji)
      self.log.trace("Removed reaction pill \(emoji)")
    }
  }
}

// MARK: - Reaction Pill

@MainActor
final class ReactionPillView: NSView {
  private var isOutgoing = false
  private var weReacted = false
  private var onClick: (() -> Void)?
  // Keep these in sync with `MessageListAppKit.applyUpdate` row-height animations.
  private static let messageListRowAnimationDuration: TimeInterval = 0.15
  private static let messageListRowTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

  private let emojiLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.isSelectable = false
    label.isEditable = false
    label.isBezeled = false
    label.drawsBackground = false
    label.font = .systemFont(ofSize: ReactionPillMetrics.emojiFontSize)
    return label
  }()

  private let countLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.isSelectable = false
    label.isEditable = false
    label.isBezeled = false
    label.drawsBackground = false
    label.font = .systemFont(ofSize: ReactionPillMetrics.textFontSize)
    return label
  }()

  private var avatarViews: [UserAvatarImageView] = []
  private var clickRecognizer: NSClickGestureRecognizer?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    wantsLayer = true
    layer?.cornerRadius = ReactionPillMetrics.height / 2
    layer?.masksToBounds = true

    addSubview(emojiLabel)
    addSubview(countLabel)
    countLabel.isHidden = true

    let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
    recognizer.numberOfClicksRequired = 1
    recognizer.delaysPrimaryMouseButtonEvents = false
    addGestureRecognizer(recognizer)
    clickRecognizer = recognizer
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Make the whole pill clickable (including avatars/labels) by preventing subviews from capturing clicks.
    bounds.contains(point) ? self : nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  func update(content: ReactionPillContent, animated: Bool, onClick: @escaping () -> Void) {
    isOutgoing = content.isOutgoing
    weReacted = content.weReacted
    self.onClick = onClick

    emojiLabel.stringValue = content.emoji
    toolTip = content.tooltip

    rebuildAvatarOrCountViews(content: content, animated: animated)
    updateColors()
    needsLayout = true
  }

  override func layout() {
    super.layout()

    let bounds = bounds
    let centerY = { (h: CGFloat) in (bounds.height - h) / 2 }

    let emojiFont = emojiLabel.font ?? .systemFont(ofSize: ReactionPillMetrics.emojiFontSize)
    var emojiSize = emojiLabel.stringValue.size(withAttributes: [.font: emojiFont])
    emojiSize.width = max(0, ceil(emojiSize.width + ReactionPillMetrics.emojiWidthAdjustment))
    emojiSize.height = ceil(emojiSize.height)
    emojiLabel.frame = CGRect(
      x: ReactionPillMetrics.padding,
      y: centerY(emojiSize.height),
      width: emojiSize.width,
      height: emojiSize.height
    )

    var x = ReactionPillMetrics.padding + emojiSize.width + ReactionPillMetrics.spacing

    if countLabel.isHidden == false {
      countLabel.sizeToFit()
      let size = countLabel.frame.size
      countLabel.frame = CGRect(x: x, y: centerY(size.height), width: size.width, height: size.height)
    } else {
      let y = centerY(ReactionPillMetrics.avatarSize)
      for (index, avatar) in avatarViews.enumerated() {
        let dx = CGFloat(index) * (ReactionPillMetrics.avatarSize - ReactionPillMetrics.avatarOverlap)
        avatar.frame = CGRect(x: x + dx, y: y, width: ReactionPillMetrics.avatarSize, height: ReactionPillMetrics.avatarSize)
      }
    }
  }

  private func rebuildAvatarOrCountViews(content: ReactionPillContent, animated: Bool) {
    if content.showsAvatars {
      countLabel.isHidden = true

      let userIds = content.avatarUsers.map(\.userId)
      let existing = Dictionary(uniqueKeysWithValues: avatarViews.compactMap { view -> (Int64, UserAvatarImageView)? in
        guard let userId = view.userId else { return nil }
        return (userId, view)
      })

      var nextViews: [UserAvatarImageView] = []
      nextViews.reserveCapacity(userIds.count)

      for (userId, user) in content.avatarUsers {
        let view: UserAvatarImageView
        if let existingView = existing[userId] {
          view = existingView
        } else {
          view = UserAvatarImageView(size: ReactionPillMetrics.avatarSize)
          addSubview(view)
          if animated {
            view.alphaValue = 0
          }
        }

        view.update(userId: userId, user: user)
        nextViews.append(view)
      }

      // Remove views not needed
      let nextIds = Set(userIds)
      for old in avatarViews where (old.userId.map { nextIds.contains($0) } ?? false) == false {
        old.removeFromSuperview()
      }

      avatarViews = nextViews

      if animated {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = Self.messageListRowAnimationDuration
          context.timingFunction = Self.messageListRowTimingFunction
          for view in avatarViews where view.alphaValue == 0 {
            view.animator().alphaValue = 1
          }
        }
      } else {
        for view in avatarViews { view.alphaValue = 1 }
      }
    } else {
      for avatar in avatarViews {
        avatar.removeFromSuperview()
      }
      avatarViews.removeAll()

      countLabel.stringValue = "\(content.count)"
      countLabel.isHidden = false
    }
  }

  private func updateColors() {
    let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    let accent = NSColor.controlAccentColor
    let baseBackground: NSColor = {
      if isDark {
        return NSColor.white
      }
      return isOutgoing ? NSColor.white : accent
    }()

    let background = baseBackground.withAlphaComponent(weReacted ? 0.9 : 0.2)
    layer?.backgroundColor = background.cgColor

    let foreground: NSColor = {
      if isDark {
        return weReacted ? accent : NSColor.white
      }
      if isOutgoing {
        return weReacted ? accent : NSColor.white
      }
      return weReacted ? NSColor.white : accent
    }()

    countLabel.textColor = foreground
  }

  @objc private func handleClick() {
    onClick?()
  }
}

// MARK: - Fallback Layout

enum ReactionLayout {
  struct Result {
    var size: CGSize
    var frames: [String: CGRect]
  }

  static func compute(reactions: [GroupedReaction], maxWidth: CGFloat, spacing: CGFloat = 6) -> Result {
    var frames: [String: CGRect] = [:]
    var currentLine = 0
    var currentLineWidth: CGFloat = 0 // used width on current line, without trailing spacing
    var maxLineWidth: CGFloat = 0

    for group in reactions {
      let size = ReactionPillMetrics.size(group: group)
      var x: CGFloat = currentLineWidth == 0 ? 0 : (currentLineWidth + spacing)
      if x + size.width > maxWidth, currentLineWidth > 0 {
        currentLine += 1
        currentLineWidth = 0
        x = 0
      }

      let frame = CGRect(
        x: x,
        y: CGFloat(currentLine) * (size.height + spacing),
        width: size.width,
        height: size.height
      )
      frames[group.emoji] = frame

      currentLineWidth = x + size.width
      maxLineWidth = max(maxLineWidth, currentLineWidth)
    }

    let height = CGFloat(currentLine + 1) * ReactionPillMetrics.height + CGFloat(currentLine) * spacing
    return Result(size: CGSize(width: maxLineWidth, height: height), frames: frames)
  }
}
