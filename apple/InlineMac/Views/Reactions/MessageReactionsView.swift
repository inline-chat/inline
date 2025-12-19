import AppKit
import Auth
import InlineKit

final class MessageReactionsView: NSView {
  override var isFlipped: Bool { true }

  private var chipsByEmoji: [String: ReactionChipButton] = [:]
  private var groupsByEmoji: [String: GroupedReaction] = [:]

  private var fullMessage: FullMessage?
  private var currentUserId: Int64? {
    Auth.shared.currentUserId
  }

  private static let animationDuration: TimeInterval = 0.14
  private static let popScaleIn: CGFloat = 0.96
  private static let popScaleOut: CGFloat = 0.96

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hitView = super.hitTest(point)
    var current = hitView
    while let view = current {
      if let button = view as? ReactionChipButton {
        return button
      }
      current = view.superview
    }
    return nil
  }

  func update(
    fullMessage: FullMessage,
    groups: [GroupedReaction],
    layoutItems: [String: MessageSizeCalculator.LayoutPlan],
    animate: Bool = true
  ) {
    self.fullMessage = fullMessage
    groupsByEmoji = Dictionary(uniqueKeysWithValues: groups.map { ($0.emoji, $0) })

    let newEmojis = Set(groupsByEmoji.keys)
    let oldEmojis = Set(chipsByEmoji.keys)

    let removed = oldEmojis.subtracting(newEmojis)
    for emoji in removed {
      guard let chip = chipsByEmoji[emoji] else { continue }
      chipsByEmoji[emoji] = nil
      if animate {
        animateRemove(chip)
      } else {
        chip.removeFromSuperview()
      }
    }

    let orderedEmojis = layoutItems
      .filter { groupsByEmoji[$0.key] != nil }
      .sorted { lhs, rhs in
        if lhs.value.spacing.top != rhs.value.spacing.top { return lhs.value.spacing.top < rhs.value.spacing.top }
        if lhs.value.spacing.left != rhs.value.spacing.left { return lhs.value.spacing.left < rhs.value.spacing.left }
        return lhs.key < rhs.key
      }
      .map(\.key)

    for emoji in orderedEmojis {
      guard let group = groupsByEmoji[emoji] else { continue }
      guard let plan = layoutItems[emoji] else { continue }

      let targetFrame = CGRect(
        x: plan.spacing.left,
        y: plan.spacing.top,
        width: plan.size.width,
        height: plan.size.height
      )

      if let chip = chipsByEmoji[emoji] {
        configure(chip: chip, group: group, fullMessage: fullMessage)

        if chip.frame != targetFrame {
          if animate {
            NSAnimationContext.runAnimationGroup { context in
              context.duration = Self.animationDuration
              context.timingFunction = CAMediaTimingFunction(name: .easeOut)
              chip.animator().frame = targetFrame
            }
          } else {
            chip.frame = targetFrame
          }
        }
      } else {
        let chip = makeChip(emoji: emoji)
        chip.frame = targetFrame
        configure(chip: chip, group: group, fullMessage: fullMessage)
        addSubview(chip)
        chipsByEmoji[emoji] = chip
        if animate {
          animateInsert(chip)
        }
      }
    }
  }

  private func makeChip(emoji: String) -> ReactionChipButton {
    let chip = ReactionChipButton(emoji: emoji)
    chip.target = self
    chip.action = #selector(handleChipClick(_:))
    chip.wantsLayer = true
    chip.alphaValue = 1.0

    chip.contextMenuProvider = { [weak self] in
      self?.menu(forEmoji: emoji)
    }

    return chip
  }

  private func configure(chip: ReactionChipButton, group: GroupedReaction, fullMessage: FullMessage) {
    chip.isOutgoing = fullMessage.message.out == true
    chip.currentUserId = currentUserId
    chip.group = group
  }

  @objc private func handleChipClick(_ sender: ReactionChipButton) {
    guard let fullMessage else { return }
    guard let currentUserId else { return }
    guard let group = groupsByEmoji[sender.emoji] else { return }

    let weReacted = group.reactions.contains { $0.reaction.userId == currentUserId }

    if weReacted {
      Task(priority: .userInitiated) { @MainActor in
        try await Api.realtime.send(.deleteReaction(
          emoji: sender.emoji,
          message: fullMessage.message
        ))
      }
    } else {
      Task(priority: .userInitiated) { @MainActor in
        try await Api.realtime.send(.addReaction(
          emoji: sender.emoji,
          message: fullMessage.message
        ))
      }
    }
  }

  private func menu(forEmoji emoji: String) -> NSMenu? {
    guard let group = groupsByEmoji[emoji] else { return nil }

    let menu = NSMenu()

    let reactions = group.reactions.sorted { $0.reaction.date > $1.reaction.date }
    for reaction in reactions {
      let name: String = if let currentUserId, reaction.reaction.userId == currentUserId {
        "You"
      } else if let user = reaction.userInfo?.user {
        user.displayName
      } else {
        ObjectCache.shared.getUser(id: reaction.reaction.userId)?.user.displayName ?? "Unknown"
      }

      let when = timestampString(for: reaction.reaction.date)
      let item = NSMenuItem(title: "\(name)\t\(when)", action: nil, keyEquivalent: "")
      let userInfo = reaction.userInfo ?? ObjectCache.shared.getUser(id: reaction.reaction.userId)
      if let userInfo {
        item.image = avatarImage(for: userInfo)
      }
      menu.addItem(item)
    }

    return menu
  }

  private func timestampString(for date: Date) -> String {
    let dateOnly = DateFormatter()
    dateOnly.locale = .autoupdatingCurrent
    dateOnly.dateStyle = .medium
    dateOnly.timeStyle = .none
    dateOnly.doesRelativeDateFormatting = true

    let timeOnly = DateFormatter()
    timeOnly.locale = .autoupdatingCurrent
    timeOnly.dateStyle = .none
    timeOnly.timeStyle = .short

    return "\(dateOnly.string(from: date)), \(timeOnly.string(from: date))"
  }

  private func avatarImage(for userInfo: UserInfo) -> NSImage? {
    let size = NSSize(width: 18, height: 18)
    let avatarView = UserAvatarView(userInfo: userInfo, size: size.width)
    avatarView.frame = NSRect(origin: .zero, size: size)
    avatarView.layoutSubtreeIfNeeded()

    guard let rep = avatarView.bitmapImageRepForCachingDisplay(in: avatarView.bounds) else { return nil }
    avatarView.cacheDisplay(in: avatarView.bounds, to: rep)

    let image = NSImage(size: size)
    image.addRepresentation(rep)
    image.isTemplate = false
    return image
  }

  private func animateInsert(_ chip: ReactionChipButton) {
    chip.alphaValue = 0
    setScale(Self.popScaleIn, for: chip)

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      chip.animator().alphaValue = 1
    }

    animateScale(from: Self.popScaleIn, to: 1.0, for: chip, duration: Self.animationDuration)
  }

  private func animateRemove(_ chip: ReactionChipButton) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      chip.animator().alphaValue = 0
    } completionHandler: { [weak chip] in
      chip?.removeFromSuperview()
    }

    animateScale(from: 1.0, to: Self.popScaleOut, for: chip, duration: Self.animationDuration)
  }

  private func setScale(_ scale: CGFloat, for view: NSView) {
    guard let layer = view.layer else { return }
    layer.transform = CATransform3DMakeScale(scale, scale, 1)
  }

  private func animateScale(from: CGFloat, to: CGFloat, for view: NSView, duration: TimeInterval) {
    guard let layer = view.layer else { return }
    let fromTransform = CATransform3DMakeScale(from, from, 1)
    let toTransform = CATransform3DMakeScale(to, to, 1)
    layer.transform = toTransform

    let anim = CABasicAnimation(keyPath: "transform")
    anim.fromValue = fromTransform
    anim.toValue = toTransform
    anim.duration = duration
    anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(anim, forKey: "transform")
  }
}
