import InlineKit
import UIKit

final class ReplyThreadSummaryView: UIControl {
  private enum Constants {
    static let height: CGFloat = 32
    static let minWidth: CGFloat = 170
    static let avatarSize: CGFloat = 18
    static let avatarOverlap: CGFloat = 7
    static let horizontalPadding: CGFloat = 9
    static let contentSpacing: CGFloat = 7
    static let maxAvatars = 3
    static let unreadDotSize: CGFloat = 7
    static let cornerRadius: CGFloat = 9
  }

  var onTap: (() -> Void)?

  private var outgoing = false
  private var avatarViews: [UserAvatarView] = []
  private var avatarsWidthConstraint: NSLayoutConstraint?
  private var avatarsToLabelSpacingConstraint: NSLayoutConstraint?
  private var unreadDotLeadingConstraint: NSLayoutConstraint?
  private var unreadDotWidthConstraint: NSLayoutConstraint?
  private var spinnerWidthConstraint: NSLayoutConstraint?
  private var loading = false

  private let avatarsContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let replyCountLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.adjustsFontForContentSizeCategory = true
    label.lineBreakMode = .byTruncatingTail
    label.numberOfLines = 1
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }()

  private let unreadDotView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.cornerRadius = Constants.unreadDotSize / 2
    return view
  }()

  private let spinnerView: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = true
    return spinner
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet {
      applyStyle()
    }
  }

  func configure(
    replyCount: Int,
    recentAuthors: [UserInfo],
    hasUnread: Bool,
    outgoing: Bool
  ) {
    self.outgoing = outgoing
    replyCountLabel.text = replyCount == 1 ? "1 reply" : "\(replyCount) replies"
    unreadDotView.isHidden = !hasUnread
    unreadDotLeadingConstraint?.constant = hasUnread ? Constants.contentSpacing : 0
    unreadDotWidthConstraint?.constant = hasUnread ? Constants.unreadDotSize : 0
    updateAvatars(authors: recentAuthors)
    accessibilityLabel = hasUnread ? "\(replyCountLabel.text ?? ""), unread" : replyCountLabel.text
    accessibilityHint = "Opens thread"
    applyStyle()
  }

  func setLoading(_ loading: Bool) {
    guard self.loading != loading else { return }
    self.loading = loading
    spinnerWidthConstraint?.constant = loading ? 16 : 0
    isUserInteractionEnabled = !loading
    if loading {
      spinnerView.startAnimating()
    } else {
      spinnerView.stopAnimating()
    }
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    layer.cornerRadius = Constants.cornerRadius
    layer.masksToBounds = true
    isAccessibilityElement = true
    accessibilityTraits = [.button]

    addSubview(avatarsContainer)
    addSubview(replyCountLabel)
    addSubview(unreadDotView)
    addSubview(spinnerView)
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)

    avatarsWidthConstraint = avatarsContainer.widthAnchor.constraint(equalToConstant: 0)
    avatarsToLabelSpacingConstraint = replyCountLabel.leadingAnchor.constraint(
      equalTo: avatarsContainer.trailingAnchor,
      constant: 0
    )
    unreadDotLeadingConstraint = unreadDotView.leadingAnchor.constraint(
      equalTo: replyCountLabel.trailingAnchor,
      constant: 0
    )
    unreadDotWidthConstraint = unreadDotView.widthAnchor.constraint(equalToConstant: 0)
    spinnerWidthConstraint = spinnerView.widthAnchor.constraint(equalToConstant: 0)
    let minWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: Constants.minWidth)
    minWidthConstraint.priority = .defaultHigh

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: Constants.height),
      minWidthConstraint,

      avatarsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Constants.horizontalPadding),
      avatarsContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatarsContainer.heightAnchor.constraint(equalToConstant: Constants.avatarSize),
      avatarsWidthConstraint!,

      avatarsToLabelSpacingConstraint!,
      replyCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      replyCountLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 5),
      replyCountLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),

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
      spinnerWidthConstraint!,
      spinnerView.heightAnchor.constraint(equalToConstant: 16),

      replyCountLabel.trailingAnchor.constraint(lessThanOrEqualTo: spinnerView.leadingAnchor, constant: -4),
    ])

    applyStyle()
  }

  private func updateAvatars(authors: [UserInfo]) {
    avatarViews.forEach { $0.removeFromSuperview() }
    avatarViews.removeAll()

    let visibleAuthors = Array(authors.prefix(Constants.maxAvatars))
    for (index, author) in visibleAuthors.enumerated() {
      let avatar = UserAvatarView()
      avatar.translatesAutoresizingMaskIntoConstraints = false
      avatar.configure(with: author, size: Constants.avatarSize)
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
      ])
    }

    let visibleCount = visibleAuthors.count
    avatarsContainer.isHidden = visibleCount == 0
    avatarsToLabelSpacingConstraint?.constant = visibleCount == 0 ? 0 : Constants.contentSpacing

    let avatarsWidth: CGFloat = if visibleCount == 0 {
      0
    } else {
      Constants.avatarSize + CGFloat(visibleCount - 1) * (Constants.avatarSize - Constants.avatarOverlap)
    }
    avatarsWidthConstraint?.constant = avatarsWidth
  }

  private func applyStyle() {
    let pressed = isHighlighted
    let backgroundBase: UIColor = outgoing ? .white : .label
    backgroundColor = backgroundBase.withAlphaComponent(outgoing ? (pressed ? 0.18 : 0.12) : (pressed ? 0.08 : 0.055))

    replyCountLabel.textColor = outgoing ? .white : (ThemeManager.shared.selected.primaryTextColor ?? .label)
    unreadDotView.backgroundColor = outgoing ? UIColor.white.withAlphaComponent(0.88) : ThemeManager.shared.selected.accent
    spinnerView.color = outgoing ? .white : ThemeManager.shared.selected.accent
  }

  @objc private func handleTap() {
    onTap?()
  }
}
