import Combine
import InlineKit
import UIKit

final class ReplyThreadFooterView: UIControl {
  struct LayoutMetrics {
    static let height: CGFloat = 28
    static let horizontalPadding: CGFloat = 10
    static let contentSpacing: CGFloat = 7
    static let unreadDotSize: CGFloat = 6
    static let avatarSize: CGFloat = 20
    static let avatarOverlap: CGFloat = 6
    static let maxAvatars = 3
    static let chevronWidth: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    static let labelFont: UIFont = .systemFont(ofSize: 12, weight: .medium)
  }

  static func title(for replyCount: Int) -> String {
    replyCount == 1 ? "1 reply" : "\(replyCount) replies"
  }

  static func width(replyCount: Int, hasUnread: Bool, avatarCount: Int) -> CGFloat {
    let boundedAvatarCount = min(max(avatarCount, 0), LayoutMetrics.maxAvatars)
    let titleWidth = ceil((title(for: replyCount) as NSString).size(withAttributes: [
      .font: LayoutMetrics.labelFont,
    ]).width)

    var width = LayoutMetrics.horizontalPadding * 2

    if hasUnread {
      width += LayoutMetrics.unreadDotSize
      width += LayoutMetrics.contentSpacing
    }

    if boundedAvatarCount > 0 {
      width += LayoutMetrics.avatarSize
      if boundedAvatarCount > 1 {
        width += CGFloat(boundedAvatarCount - 1) * (LayoutMetrics.avatarSize - LayoutMetrics.avatarOverlap)
      }
      width += LayoutMetrics.contentSpacing
    }

    width += titleWidth
    width += LayoutMetrics.contentSpacing
    width += LayoutMetrics.chevronWidth
    return ceil(width)
  }

  var onTap: (() -> Void)?

  private let backgroundView = UIView()
  private let stackView = UIStackView()
  private let unreadDotView = UIView()
  private let avatarsContainerView = UIView()
  private let label = UILabel()
  private let chevronImageView = UIImageView(image: UIImage(systemName: "chevron.right"))

  private var avatarViews: [Int64: UserAvatarView] = [:]
  private var avatarConstraints: [NSLayoutConstraint] = []
  private var avatarContainerWidthConstraint: NSLayoutConstraint?
  private var userSubscriptions: Set<AnyCancellable> = []
  private var userFetchTasks: [Task<Void, Never>] = []
  private var currentUserIds: [Int64] = []
  private var currentReplyCount = 0
  private var currentAvatarCount = 0
  private var currentHasUnread = false

  override var intrinsicContentSize: CGSize {
    CGSize(
      width: Self.width(
        replyCount: currentReplyCount,
        hasUnread: currentHasUnread,
        avatarCount: currentAvatarCount
      ),
      height: LayoutMetrics.height
    )
  }

  override var isHighlighted: Bool {
    didSet {
      updateAppearance(animated: false)
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    userFetchTasks.forEach { $0.cancel() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    backgroundView.layer.cornerRadius = LayoutMetrics.cornerRadius
    backgroundView.layer.cornerCurve = .continuous
    unreadDotView.layer.cornerRadius = LayoutMetrics.unreadDotSize / 2
  }

  func configure(replyCount: Int, hasUnread: Bool, recentReplierUserIds: [Int64]) {
    currentReplyCount = replyCount
    currentHasUnread = hasUnread
    label.text = Self.title(for: replyCount)
    label.textColor = hasUnread ? .label : .secondaryLabel

    unreadDotView.isHidden = !hasUnread

    let avatarUserIds = Array(recentReplierUserIds.prefix(LayoutMetrics.maxAvatars))
    currentAvatarCount = avatarUserIds.count
    updateAvatars(userIds: avatarUserIds)
    invalidateIntrinsicContentSize()
    updateAppearance(animated: false)
  }

  func reset() {
    userSubscriptions.removeAll()
    userFetchTasks.forEach { $0.cancel() }
    userFetchTasks.removeAll()
    currentUserIds = []
    currentAvatarCount = 0
    clearAvatarViews()
    invalidateIntrinsicContentSize()
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.isUserInteractionEnabled = false
    addSubview(backgroundView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.alignment = .center
    stackView.spacing = LayoutMetrics.contentSpacing
    stackView.isUserInteractionEnabled = false
    backgroundView.addSubview(stackView)

    unreadDotView.translatesAutoresizingMaskIntoConstraints = false
    unreadDotView.backgroundColor = ThemeManager.shared.selected.accent
    unreadDotView.isUserInteractionEnabled = false
    NSLayoutConstraint.activate([
      unreadDotView.widthAnchor.constraint(equalToConstant: LayoutMetrics.unreadDotSize),
      unreadDotView.heightAnchor.constraint(equalToConstant: LayoutMetrics.unreadDotSize),
    ])

    avatarsContainerView.translatesAutoresizingMaskIntoConstraints = false
    avatarsContainerView.isUserInteractionEnabled = false
    avatarContainerWidthConstraint = avatarsContainerView.widthAnchor.constraint(equalToConstant: 0)
    avatarContainerWidthConstraint?.isActive = true
    NSLayoutConstraint.activate([
      avatarsContainerView.heightAnchor.constraint(equalToConstant: LayoutMetrics.avatarSize),
    ])

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = LayoutMetrics.labelFont
    label.numberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    chevronImageView.translatesAutoresizingMaskIntoConstraints = false
    chevronImageView.tintColor = .secondaryLabel
    chevronImageView.contentMode = .scaleAspectFit
    NSLayoutConstraint.activate([
      chevronImageView.widthAnchor.constraint(equalToConstant: LayoutMetrics.chevronWidth),
    ])

    stackView.addArrangedSubview(unreadDotView)
    stackView.addArrangedSubview(avatarsContainerView)
    stackView.addArrangedSubview(label)
    stackView.addArrangedSubview(chevronImageView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: LayoutMetrics.height),

      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: LayoutMetrics.horizontalPadding),
      stackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -LayoutMetrics.horizontalPadding),
      stackView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
    ])

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  @objc private func handleTap() {
    onTap?()
  }

  private func updateAvatars(userIds: [Int64]) {
    guard userIds != currentUserIds else { return }

    userSubscriptions.removeAll()
    userFetchTasks.forEach { $0.cancel() }
    userFetchTasks.removeAll()
    currentUserIds = userIds

    clearAvatarViews()

    guard !userIds.isEmpty else {
      avatarsContainerView.isHidden = true
      avatarContainerWidthConstraint?.constant = 0
      return
    }

    avatarsContainerView.isHidden = false

    var previousView: UserAvatarView?
    for (index, userId) in userIds.enumerated() {
      let avatarView = UserAvatarView()
      avatarView.translatesAutoresizingMaskIntoConstraints = false
      avatarView.layer.borderWidth = 1
      avatarView.layer.borderColor = UIColor.systemBackground.cgColor
      avatarView.layer.masksToBounds = true
      avatarView.configure(with: ObjectCache.shared.getUser(id: userId) ?? .deleted, size: LayoutMetrics.avatarSize)
      avatarsContainerView.addSubview(avatarView)
      avatarViews[userId] = avatarView

      var constraints: [NSLayoutConstraint] = [
        avatarView.topAnchor.constraint(equalTo: avatarsContainerView.topAnchor),
        avatarView.widthAnchor.constraint(equalToConstant: LayoutMetrics.avatarSize),
        avatarView.heightAnchor.constraint(equalToConstant: LayoutMetrics.avatarSize),
      ]

      if let previousView {
        constraints.append(
          avatarView.leadingAnchor.constraint(
            equalTo: previousView.leadingAnchor,
            constant: LayoutMetrics.avatarSize - LayoutMetrics.avatarOverlap
          )
        )
      } else {
        constraints.append(avatarView.leadingAnchor.constraint(equalTo: avatarsContainerView.leadingAnchor))
      }

      if index == userIds.count - 1 {
        constraints.append(avatarView.trailingAnchor.constraint(equalTo: avatarsContainerView.trailingAnchor))
      }

      NSLayoutConstraint.activate(constraints)
      avatarConstraints.append(contentsOf: constraints)
      previousView = avatarView

      ObjectCache.shared
        .getUserPublisher(id: userId)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] userInfo in
          guard let self else { return }
          guard self.currentUserIds.contains(userId) else { return }
          guard let avatarView = self.avatarViews[userId], let userInfo else { return }
          avatarView.configure(with: userInfo, size: LayoutMetrics.avatarSize)
        }
        .store(in: &userSubscriptions)

      if ObjectCache.shared.getUser(id: userId) == nil {
        userFetchTasks.append(Task { @MainActor in
          try? await DataManager.shared.getUser(id: userId)
        })
      }
    }

    let width = LayoutMetrics.avatarSize + CGFloat(max(userIds.count - 1, 0)) * (LayoutMetrics.avatarSize - LayoutMetrics.avatarOverlap)
    avatarContainerWidthConstraint?.constant = width
  }

  private func clearAvatarViews() {
    NSLayoutConstraint.deactivate(avatarConstraints)
    avatarConstraints.removeAll()
    avatarViews.values.forEach { $0.removeFromSuperview() }
    avatarViews.removeAll()
  }

  private func updateAppearance(animated: Bool) {
    let accent = ThemeManager.shared.selected.accent
    let baseAlpha: CGFloat = currentHasUnread ? 0.12 : 0.06
    let highlightAlpha: CGFloat = currentHasUnread ? 0.18 : 0.1
    let backgroundColor = accent.withAlphaComponent(isHighlighted ? highlightAlpha : baseAlpha)

    if animated {
      UIView.animate(withDuration: 0.12) {
        self.backgroundView.backgroundColor = backgroundColor
      }
    } else {
      backgroundView.backgroundColor = backgroundColor
    }
  }
}
