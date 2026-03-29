import InlineKit
import UIKit

final class ReplyThreadAvatarClusterView: UIView {
  private enum Metrics {
    static let avatarSize: CGFloat = 18
    static let avatarOverlap: CGFloat = 6
    static let maxVisibleAvatars = 3
    static let animationDuration: TimeInterval = 0.28
  }

  private var orderedUserIds: [Int64] = []
  private var avatarViewsByUserId: [Int64: UserAvatarView] = [:]

  static func width(forVisibleUserCount count: Int) -> CGFloat {
    let visibleCount = min(max(count, 0), Metrics.maxVisibleAvatars)
    guard visibleCount > 0 else { return 0 }

    return Metrics.avatarSize
      + CGFloat(max(visibleCount - 1, 0)) * (Metrics.avatarSize - Metrics.avatarOverlap)
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: Self.width(forVisibleUserCount: orderedUserIds.count), height: Metrics.avatarSize)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = false
    clipsToBounds = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    applyLayout(animated: false, removedAvatarViews: [])
  }

  func setUsers(_ users: [UserInfo], animated: Bool) {
    let visibleUsers = Array(users.prefix(Metrics.maxVisibleAvatars))
    let newUserIds = visibleUsers.map(\.id)
    let removedIds = Set(orderedUserIds).subtracting(newUserIds)
    let removedAvatarViews = removedIds.compactMap { avatarViewsByUserId[$0] }

    for userInfo in visibleUsers where avatarViewsByUserId[userInfo.id] == nil {
      let avatarView = UserAvatarView()
      avatarView.configure(with: userInfo, size: Metrics.avatarSize)
      avatarView.alpha = 0
      avatarView.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
      addSubview(avatarView)
      avatarViewsByUserId[userInfo.id] = avatarView
    }

    for userInfo in visibleUsers {
      avatarViewsByUserId[userInfo.id]?.configure(with: userInfo, size: Metrics.avatarSize)
    }

    orderedUserIds = newUserIds
    invalidateIntrinsicContentSize()
    setNeedsLayout()
    applyLayout(animated: animated, removedAvatarViews: removedAvatarViews)
  }

  private func applyLayout(animated: Bool, removedAvatarViews: [UserAvatarView]) {
    let animations = {
      for (index, userId) in self.orderedUserIds.enumerated() {
        guard let avatarView = self.avatarViewsByUserId[userId] else { continue }
        avatarView.frame = self.frameForAvatar(at: index)
        avatarView.alpha = 1
        avatarView.transform = .identity
      }

      for avatarView in removedAvatarViews {
        avatarView.alpha = 0
        avatarView.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
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
      animations()
      completion()
      return
    }

    let animator = UIViewPropertyAnimator(duration: Metrics.animationDuration, dampingRatio: 0.84, animations: animations)
    animator.addCompletion { _ in
      completion()
    }
    animator.startAnimation()
  }

  private func frameForAvatar(at index: Int) -> CGRect {
    let x = CGFloat(index) * (Metrics.avatarSize - Metrics.avatarOverlap)
    return CGRect(x: x, y: 0, width: Metrics.avatarSize, height: Metrics.avatarSize)
  }
}
