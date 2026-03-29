import Combine
import InlineKit
import InlineProtocol
import InlineUI
import UIKit

final class ReplyThreadFooterView: UIControl {
  private enum Metrics {
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
    static let unreadDotSize: CGFloat = 6
    static let interItemSpacing: CGFloat = 8
  }

  private let outgoing: Bool
  private let separatorView = UIView()
  private let unreadDotView = UIView()
  private let avatarClusterView = ReplyThreadAvatarClusterView()
  private let replyCountLabel = UILabel()
  private let chevronImageView = UIImageView(image: UIImage(systemName: "chevron.right"))

  private var avatarWidthConstraint: NSLayoutConstraint!
  private var unreadDotWidthConstraint: NSLayoutConstraint!
  private var minimumWidthConstraint: NSLayoutConstraint!
  private var usersCancellable: AnyCancellable?
  private var usersViewModel: ReplyThreadUsersViewModel?
  private var threadChatId: Int64 = 0
  private var animateNextUserUpdate = false
  private var hasReceivedInitialUsersValue = false
  private var expectedRecentUserCount = 0

  var onTap: ((Int64) -> Void)?

  init(outgoing: Bool) {
    self.outgoing = outgoing
    super.init(frame: .zero)
    setupViews()
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet {
      alpha = isHighlighted ? 0.72 : 1
    }
  }

  func configure(replies: MessageReplies, animated: Bool) {
    threadChatId = replies.chatID
    animateNextUserUpdate = animated
    expectedRecentUserCount = replies.recentReplierUserIds.count

    let replyCount = Int(replies.replyCount)
    replyCountLabel.text = replyCount == 1 ? "1 reply" : "\(replyCount) replies"
    replyCountLabel.font = .systemFont(ofSize: 13, weight: replies.hasUnread_p ? .semibold : .medium)
    replyCountLabel.textColor = textColor(hasUnread: replies.hasUnread_p)

    chevronImageView.tintColor = replyCountLabel.textColor.withAlphaComponent(0.78)

    unreadDotView.isHidden = !replies.hasUnread_p
    unreadDotWidthConstraint.constant = replies.hasUnread_p ? Metrics.unreadDotSize : 0
    unreadDotView.backgroundColor = unreadColor
    avatarWidthConstraint.constant = ReplyThreadAvatarClusterView.width(
      forVisibleUserCount: replies.recentReplierUserIds.count
    )
    minimumWidthConstraint.constant = minimumWidth(for: replies)

    accessibilityLabel = accessibilitySummary(replyCount: replyCount, hasUnread: replies.hasUnread_p)

    updateUsers(userIds: replies.recentReplierUserIds, animated: animated)
    setNeedsLayout()
    layoutIfNeeded()
  }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    isAccessibilityElement = true
    accessibilityTraits = [.button]

    separatorView.translatesAutoresizingMaskIntoConstraints = false
    separatorView.backgroundColor = separatorColor
    addSubview(separatorView)

    unreadDotView.translatesAutoresizingMaskIntoConstraints = false
    unreadDotView.layer.cornerRadius = Metrics.unreadDotSize / 2
    addSubview(unreadDotView)

    avatarClusterView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatarClusterView)

    replyCountLabel.translatesAutoresizingMaskIntoConstraints = false
    replyCountLabel.lineBreakMode = .byTruncatingTail
    replyCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(replyCountLabel)

    chevronImageView.translatesAutoresizingMaskIntoConstraints = false
    chevronImageView.contentMode = .scaleAspectFit
    chevronImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    addSubview(chevronImageView)

    unreadDotWidthConstraint = unreadDotView.widthAnchor.constraint(equalToConstant: 0)
    avatarWidthConstraint = avatarClusterView.widthAnchor.constraint(equalToConstant: 0)
    minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    NSLayoutConstraint.activate([
      minimumWidthConstraint,
      separatorView.topAnchor.constraint(equalTo: topAnchor),
      separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
      separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
      separatorView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

      unreadDotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
      unreadDotView.centerYAnchor.constraint(equalTo: centerYAnchor),
      unreadDotWidthConstraint,
      unreadDotView.heightAnchor.constraint(equalToConstant: Metrics.unreadDotSize),

      avatarClusterView.leadingAnchor.constraint(equalTo: unreadDotView.trailingAnchor, constant: Metrics.interItemSpacing),
      avatarClusterView.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatarWidthConstraint,
      avatarClusterView.heightAnchor.constraint(equalToConstant: 18),

      replyCountLabel.leadingAnchor.constraint(equalTo: avatarClusterView.trailingAnchor, constant: Metrics.interItemSpacing),
      replyCountLabel.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: Metrics.verticalInset),
      replyCountLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalInset),

      chevronImageView.leadingAnchor.constraint(greaterThanOrEqualTo: replyCountLabel.trailingAnchor, constant: Metrics.interItemSpacing),
      chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalInset),
      chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 10),
      chevronImageView.heightAnchor.constraint(equalToConstant: 12),
    ])
  }

  private func updateUsers(userIds: [Int64], animated: Bool) {
    expectedRecentUserCount = userIds.count
    avatarWidthConstraint.constant = ReplyThreadAvatarClusterView.width(forVisibleUserCount: userIds.count)

    Task { @MainActor [weak self] in
      guard let self else { return }

      if let usersViewModel = self.usersViewModel {
        self.animateNextUserUpdate = animated
        usersViewModel.update(userIds: userIds)
        return
      }

      let usersViewModel = ReplyThreadUsersViewModel(userIds: userIds)
      self.usersViewModel = usersViewModel
      self.hasReceivedInitialUsersValue = false
      self.usersCancellable = usersViewModel.$users
        .receive(on: DispatchQueue.main)
        .sink { [weak self] users in
          guard let self else { return }
          let isInitialEmission = self.hasReceivedInitialUsersValue == false
          self.hasReceivedInitialUsersValue = true
          let shouldAnimate = isInitialEmission ? false : self.animateNextUserUpdate
          self.avatarClusterView.setUsers(users, animated: shouldAnimate)
          self.avatarWidthConstraint.constant = ReplyThreadAvatarClusterView.width(
            forVisibleUserCount: users.isEmpty ? self.expectedRecentUserCount : users.count
          )
          self.animateNextUserUpdate = true
          if shouldAnimate {
            UIView.animate(withDuration: 0.22) {
              self.layoutIfNeeded()
            }
          } else {
            self.layoutIfNeeded()
          }
        }
    }
  }

  private func textColor(hasUnread: Bool) -> UIColor {
    if outgoing {
      return .white
    }
    return hasUnread ? ThemeManager.shared.selected.accent : (ThemeManager.shared.selected.primaryTextColor ?? .label)
  }

  private var unreadColor: UIColor {
    outgoing ? .white : ThemeManager.shared.selected.accent
  }

  private var separatorColor: UIColor {
    if outgoing {
      return UIColor.white.withAlphaComponent(0.16)
    }
    return UIColor.label.withAlphaComponent(0.08)
  }

  private func accessibilitySummary(replyCount: Int, hasUnread: Bool) -> String {
    let replyText = replyCount == 1 ? "1 reply" : "\(replyCount) replies"
    if hasUnread {
      return "Open reply thread, \(replyText), unread"
    }
    return "Open reply thread, \(replyText)"
  }

  private func minimumWidth(for replies: MessageReplies) -> CGFloat {
    let unreadWidth = replies.hasUnread_p ? Metrics.unreadDotSize : 0
    let avatarWidth = ReplyThreadAvatarClusterView.width(forVisibleUserCount: replies.recentReplierUserIds.count)
    let font = UIFont.systemFont(ofSize: 13, weight: replies.hasUnread_p ? .semibold : .medium)
    let labelText = Int(replies.replyCount) == 1 ? "1 reply" : "\(replies.replyCount) replies"
    let labelWidth = ceil((labelText as NSString).size(withAttributes: [.font: font]).width)

    return Metrics.horizontalInset
      + unreadWidth
      + Metrics.interItemSpacing
      + avatarWidth
      + Metrics.interItemSpacing
      + labelWidth
      + Metrics.interItemSpacing
      + 10
      + Metrics.horizontalInset
  }

  @objc private func handleTap() {
    guard threadChatId > 0 else { return }
    onTap?(threadChatId)
  }
}
