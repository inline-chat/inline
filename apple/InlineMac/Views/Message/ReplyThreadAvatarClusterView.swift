import AppKit
import InlineKit

enum ReplyThreadFooterMetrics {
  static let horizontalInset: CGFloat = 12
  static let verticalInset: CGFloat = 8
  static let unreadDotSize: CGFloat = 6
  static let interItemSpacing: CGFloat = 8
  static let avatarSize: CGFloat = 18
  static let avatarOverlap: CGFloat = 6
  static let maxVisibleAvatars = 3
  static let footerHeight: CGFloat = 35
  static let animationDuration: TimeInterval = 0.22
}

final class ReplyThreadAvatarClusterView: NSView {
  private var orderedUserIds: [Int64] = []
  private var avatarViewsByUserId: [Int64: UserAvatarView] = [:]

  static func width(forVisibleUserCount count: Int) -> CGFloat {
    let visibleCount = min(max(count, 0), ReplyThreadFooterMetrics.maxVisibleAvatars)
    guard visibleCount > 0 else { return 0 }

    return ReplyThreadFooterMetrics.avatarSize
      + CGFloat(max(visibleCount - 1, 0))
      * (ReplyThreadFooterMetrics.avatarSize - ReplyThreadFooterMetrics.avatarOverlap)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: Self.width(forVisibleUserCount: orderedUserIds.count),
      height: ReplyThreadFooterMetrics.avatarSize
    )
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    applyLayout(animated: false, removedAvatarViews: [])
  }

  func setUsers(_ users: [UserInfo], animated: Bool) {
    let visibleUsers = Array(users.prefix(ReplyThreadFooterMetrics.maxVisibleAvatars))
    let newUserIds = visibleUsers.map(\.id)
    let removedIds = Set(orderedUserIds).subtracting(newUserIds)
    let removedAvatarViews = removedIds.compactMap { avatarViewsByUserId[$0] }

    for userInfo in visibleUsers where avatarViewsByUserId[userInfo.id] == nil {
      let avatarView = UserAvatarView(userInfo: userInfo, size: ReplyThreadFooterMetrics.avatarSize)
      avatarView.alphaValue = 0
      avatarView.wantsLayer = true
      avatarView.layer?.cornerRadius = ReplyThreadFooterMetrics.avatarSize / 2
      addSubview(avatarView)
      avatarViewsByUserId[userInfo.id] = avatarView
    }

    for userInfo in visibleUsers {
      avatarViewsByUserId[userInfo.id]?.update(userInfo: userInfo)
    }

    orderedUserIds = newUserIds
    invalidateIntrinsicContentSize()
    needsLayout = true
    applyLayout(animated: animated, removedAvatarViews: removedAvatarViews)
  }

  private func applyLayout(animated: Bool, removedAvatarViews: [UserAvatarView]) {
    let updates = {
      for (index, userId) in self.orderedUserIds.enumerated() {
        guard let avatarView = self.avatarViewsByUserId[userId] else { continue }
        avatarView.layer?.zPosition = CGFloat(self.orderedUserIds.count - index)
        avatarView.frame = self.frameForAvatar(at: index)
        avatarView.alphaValue = 1
      }

      for avatarView in removedAvatarViews {
        avatarView.alphaValue = 0
      }
    }

    let completion = {
      for avatarView in removedAvatarViews {
        avatarView.removeFromSuperview()
      }

      let remainingIds = Set(self.orderedUserIds)
      self.avatarViewsByUserId = self.avatarViewsByUserId.filter { remainingIds.contains($0.key) }
    }

    guard animated else {
      updates()
      completion()
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = ReplyThreadFooterMetrics.animationDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)

      for (index, userId) in self.orderedUserIds.enumerated() {
        guard let avatarView = self.avatarViewsByUserId[userId] else { continue }
        avatarView.layer?.zPosition = CGFloat(self.orderedUserIds.count - index)
        avatarView.animator().frame = self.frameForAvatar(at: index)
        avatarView.animator().alphaValue = 1
      }

      for avatarView in removedAvatarViews {
        avatarView.animator().alphaValue = 0
      }
    } completionHandler: {
      completion()
    }
  }

  private func frameForAvatar(at index: Int) -> CGRect {
    let x = CGFloat(index) * (ReplyThreadFooterMetrics.avatarSize - ReplyThreadFooterMetrics.avatarOverlap)
    let y = max(0, (bounds.height - ReplyThreadFooterMetrics.avatarSize) / 2)
    return CGRect(x: x, y: y, width: ReplyThreadFooterMetrics.avatarSize, height: ReplyThreadFooterMetrics.avatarSize)
  }
}
