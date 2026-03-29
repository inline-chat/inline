import AppKit
import Combine
import InlineKit
import InlineProtocol

final class ReplyThreadFooterView: NSControl {
  static let preferredHeight = ReplyThreadFooterMetrics.footerHeight

  private let outgoing: Bool
  private let separatorView = NSView()
  private let unreadDotView = NSView()
  private let avatarClusterView = ReplyThreadAvatarClusterView()
  private let replyCountLabel = NSTextField(labelWithString: "")
  private let chevronImageView = NSImageView()

  private var avatarWidthConstraint: NSLayoutConstraint!
  private var unreadDotWidthConstraint: NSLayoutConstraint!
  private var minimumWidthConstraint: NSLayoutConstraint!
  private var usersViewModel: ReplyThreadUsersViewModel?
  private var usersCancellable: AnyCancellable?
  private var threadChatId: Int64 = 0
  private var animateNextUserUpdate = false
  private var hasReceivedInitialUsersValue = false
  private var expectedRecentUserCount = 0

  var onTap: ((Int64) -> Void)?

  init(outgoing: Bool) {
    self.outgoing = outgoing
    super.init(frame: .zero)
    setupViews()
    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(clickGesture)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    addCursorRect(bounds, cursor: .pointingHand)
  }

  func configure(replies: MessageReplies, animated: Bool) {
    threadChatId = replies.chatID
    animateNextUserUpdate = animated
    expectedRecentUserCount = replies.recentReplierUserIds.count

    let replyCount = Int(replies.replyCount)
    replyCountLabel.stringValue = replyCount == 1 ? "1 reply" : "\(replyCount) replies"
    replyCountLabel.font = .systemFont(ofSize: 13, weight: replies.hasUnread_p ? .semibold : .medium)
    replyCountLabel.textColor = textColor(hasUnread: replies.hasUnread_p)

    chevronImageView.contentTintColor = (replyCountLabel.textColor ?? textColor(hasUnread: replies.hasUnread_p))
      .withAlphaComponent(0.78)

    unreadDotView.isHidden = !replies.hasUnread_p
    unreadDotWidthConstraint.constant = replies.hasUnread_p ? ReplyThreadFooterMetrics.unreadDotSize : 0
    unreadDotView.layer?.backgroundColor = unreadColor.cgColor
    avatarWidthConstraint.constant = ReplyThreadAvatarClusterView.width(
      forVisibleUserCount: replies.recentReplierUserIds.count
    )
    minimumWidthConstraint.constant = minimumWidth(for: replies)

    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(accessibilitySummary(replyCount: replyCount, hasUnread: replies.hasUnread_p))

    updateUsers(userIds: replies.recentReplierUserIds, animated: animated)

    guard animated else {
      needsLayout = true
      return
    }

    replyCountLabel.alphaValue = 0.72
    unreadDotView.alphaValue = 0.72
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      self.replyCountLabel.animator().alphaValue = 1
      self.unreadDotView.animator().alphaValue = 1
      self.layoutSubtreeIfNeeded()
    }
  }

  private func setupViews() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true

    separatorView.translatesAutoresizingMaskIntoConstraints = false
    separatorView.wantsLayer = true
    separatorView.layer?.backgroundColor = separatorColor.cgColor
    addSubview(separatorView)

    unreadDotView.translatesAutoresizingMaskIntoConstraints = false
    unreadDotView.wantsLayer = true
    unreadDotView.layer?.cornerRadius = ReplyThreadFooterMetrics.unreadDotSize / 2
    addSubview(unreadDotView)

    addSubview(avatarClusterView)

    replyCountLabel.translatesAutoresizingMaskIntoConstraints = false
    replyCountLabel.lineBreakMode = .byTruncatingTail
    replyCountLabel.maximumNumberOfLines = 1
    replyCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(replyCountLabel)

    chevronImageView.translatesAutoresizingMaskIntoConstraints = false
    chevronImageView.image = NSImage(
      systemSymbolName: "chevron.right",
      accessibilityDescription: "Open reply thread"
    )
    chevronImageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    addSubview(chevronImageView)

    unreadDotWidthConstraint = unreadDotView.widthAnchor.constraint(equalToConstant: 0)
    avatarWidthConstraint = avatarClusterView.widthAnchor.constraint(equalToConstant: 0)
    minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)

    NSLayoutConstraint.activate([
      minimumWidthConstraint,
      separatorView.topAnchor.constraint(equalTo: topAnchor),
      separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
      separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
      separatorView.heightAnchor.constraint(equalToConstant: 1),

      unreadDotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ReplyThreadFooterMetrics.horizontalInset),
      unreadDotView.centerYAnchor.constraint(equalTo: centerYAnchor),
      unreadDotWidthConstraint,
      unreadDotView.heightAnchor.constraint(equalToConstant: ReplyThreadFooterMetrics.unreadDotSize),

      avatarClusterView.leadingAnchor.constraint(
        equalTo: unreadDotView.trailingAnchor,
        constant: ReplyThreadFooterMetrics.interItemSpacing
      ),
      avatarClusterView.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatarWidthConstraint,
      avatarClusterView.heightAnchor.constraint(equalToConstant: ReplyThreadFooterMetrics.avatarSize),

      replyCountLabel.leadingAnchor.constraint(
        equalTo: avatarClusterView.trailingAnchor,
        constant: ReplyThreadFooterMetrics.interItemSpacing
      ),
      replyCountLabel.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: ReplyThreadFooterMetrics.verticalInset),
      replyCountLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ReplyThreadFooterMetrics.verticalInset),

      chevronImageView.leadingAnchor.constraint(
        greaterThanOrEqualTo: replyCountLabel.trailingAnchor,
        constant: ReplyThreadFooterMetrics.interItemSpacing
      ),
      chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ReplyThreadFooterMetrics.horizontalInset),
      chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 10),
      chevronImageView.heightAnchor.constraint(equalToConstant: 12),
    ])
  }

  private func updateUsers(userIds: [Int64], animated: Bool) {
    expectedRecentUserCount = userIds.count
    avatarWidthConstraint.constant = ReplyThreadAvatarClusterView.width(forVisibleUserCount: userIds.count)

    if let usersViewModel {
      animateNextUserUpdate = animated
      usersViewModel.update(userIds: userIds)
      return
    }

    let usersViewModel = ReplyThreadUsersViewModel(userIds: userIds)
    self.usersViewModel = usersViewModel
    hasReceivedInitialUsersValue = false
    usersCancellable = usersViewModel.$users
      .receive(on: RunLoop.main)
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

        guard shouldAnimate else {
          self.layoutSubtreeIfNeeded()
          return
        }

        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.2
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          self.layoutSubtreeIfNeeded()
        }
      }
  }

  private func textColor(hasUnread: Bool) -> NSColor {
    if outgoing {
      return .white
    }
    return hasUnread ? .controlAccentColor : .labelColor
  }

  private var unreadColor: NSColor {
    outgoing ? .white : .controlAccentColor
  }

  private var separatorColor: NSColor {
    if outgoing {
      return .white.withAlphaComponent(0.16)
    }
    return .labelColor.withAlphaComponent(0.08)
  }

  private func accessibilitySummary(replyCount: Int, hasUnread: Bool) -> String {
    let replyText = replyCount == 1 ? "1 reply" : "\(replyCount) replies"
    if hasUnread {
      return "Open reply thread, \(replyText), unread"
    }
    return "Open reply thread, \(replyText)"
  }

  private func minimumWidth(for replies: MessageReplies) -> CGFloat {
    let unreadWidth = replies.hasUnread_p ? ReplyThreadFooterMetrics.unreadDotSize : 0
    let avatarWidth = ReplyThreadAvatarClusterView.width(forVisibleUserCount: replies.recentReplierUserIds.count)
    let font = NSFont.systemFont(ofSize: 13, weight: replies.hasUnread_p ? .semibold : .medium)
    let labelText = Int(replies.replyCount) == 1 ? "1 reply" : "\(replies.replyCount) replies"
    let labelWidth = ceil((labelText as NSString).size(withAttributes: [.font: font]).width)

    return ReplyThreadFooterMetrics.horizontalInset
      + unreadWidth
      + ReplyThreadFooterMetrics.interItemSpacing
      + avatarWidth
      + ReplyThreadFooterMetrics.interItemSpacing
      + labelWidth
      + ReplyThreadFooterMetrics.interItemSpacing
      + 10
      + ReplyThreadFooterMetrics.horizontalInset
  }

  @objc private func handleTap() {
    guard threadChatId > 0 else { return }
    onTap?(threadChatId)
  }
}
