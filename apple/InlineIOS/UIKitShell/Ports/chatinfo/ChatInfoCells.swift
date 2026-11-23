import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import UIKit

// Cells for the UIKit chat info (`ChatInfoViewController`) and its member picker.

// MARK: - Header

/// Large avatar or thread icon, name and subtitle, on the grouped background.
@MainActor
final class ChatInfoHeaderCell: UITableViewCell {
  static let reuseIdentifier = "ChatInfoHeaderCell"

  enum Identity: Hashable {
    case user(UserInfo)
    case thread(ThreadIconDescriptor)
  }

  private static let iconSize: CGFloat = 92

  private let iconContainer = UIView()
  private let avatarView = UserAvatarLayerView()
  private let threadIconView = ThreadIconLayerView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private var onIconTap: (@MainActor () -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundConfiguration = .clear()

    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    for view in [avatarView, threadIconView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.isUserInteractionEnabled = false
      iconContainer.addSubview(view)
      NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: iconContainer.topAnchor),
        view.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
        view.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
      ])
    }
    NSLayoutConstraint.activate([
      iconContainer.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconContainer.heightAnchor.constraint(equalToConstant: Self.iconSize),
    ])
    iconContainer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(iconTapped)))

    titleLabel.font = UIFont.preferredFont(forTextStyle: .title2).withWeight(.semibold)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    titleLabel.accessibilityTraits = .header

    subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 0

    let stack = UIStackView(arrangedSubviews: [iconContainer, titleLabel, subtitleLabel])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 4
    stack.setCustomSpacing(12, after: iconContainer)
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    let bottom = stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
    bottom.priority = .init(999)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      bottom,
      stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(identity: Identity, title: String, subtitle: String?, onIconTap: (@MainActor () -> Void)?) {
    switch identity {
    case let .user(userInfo):
      avatarView.isHidden = false
      threadIconView.isHidden = true
      avatarView.configure(with: userInfo, size: Self.iconSize)
    case let .thread(descriptor):
      avatarView.isHidden = true
      threadIconView.isHidden = false
      threadIconView.configure(descriptor, size: .large(Self.iconSize), shape: .circle)
    }
    titleLabel.text = title
    subtitleLabel.text = subtitle
    subtitleLabel.isHidden = subtitle?.isEmpty ?? true
    self.onIconTap = onIconTap
    iconContainer.isUserInteractionEnabled = onIconTap != nil
    iconContainer.isAccessibilityElement = onIconTap != nil
    iconContainer.accessibilityTraits = .button
    iconContainer.accessibilityLabel = onIconTap != nil ? String(localized: "Edit thread") : nil
  }

  @objc private func iconTapped() {
    CompatHaptics.impact(.light)
    onIconTap?()
  }
}

// MARK: - Person

/// Avatar, name ("You" for the viewer), username or "bot", and an owner/admin badge.
@MainActor
final class ChatInfoPersonCell: UITableViewCell {
  static let reuseIdentifier = "ChatInfoPersonCell"

  enum Trailing: Hashable {
    case none
    case disclosure
    /// Selection circle for multi-select pickers.
    case selection(Bool)
    case activity
  }

  private static let avatarSize: CGFloat = 36

  private let avatarView = UserAvatarLayerView()
  private let nameLabel = UILabel()
  private let youLabel = UILabel()
  private let detailLabel = UILabel()
  private let badgeView = UIView()
  private let badgeLabel = UILabel()
  private let textStack = UIStackView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.isUserInteractionEnabled = false

    nameLabel.font = .preferredFont(forTextStyle: .body)
    nameLabel.adjustsFontForContentSizeCategory = true
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    youLabel.text = String(localized: "You")
    youLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
    youLabel.adjustsFontForContentSizeCategory = true
    youLabel.textColor = .secondaryLabel
    youLabel.setContentHuggingPriority(.required, for: .horizontal)
    youLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    detailLabel.font = .preferredFont(forTextStyle: .subheadline)
    detailLabel.adjustsFontForContentSizeCategory = true
    detailLabel.textColor = .secondaryLabel
    detailLabel.lineBreakMode = .byTruncatingTail

    let nameRow = UIStackView(arrangedSubviews: [nameLabel, youLabel])
    nameRow.axis = .horizontal
    nameRow.spacing = 5
    nameRow.alignment = .firstBaseline

    textStack.axis = .vertical
    textStack.spacing = 1
    textStack.addArrangedSubview(nameRow)
    textStack.addArrangedSubview(detailLabel)
    textStack.translatesAutoresizingMaskIntoConstraints = false

    badgeLabel.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
    badgeLabel.adjustsFontForContentSizeCategory = true
    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
    badgeView.translatesAutoresizingMaskIntoConstraints = false
    badgeView.layer.cornerCurve = .continuous
    badgeView.addSubview(badgeLabel)
    badgeView.setContentHuggingPriority(.required, for: .horizontal)
    badgeView.setContentCompressionResistancePriority(.required, for: .horizontal)

    contentView.addSubview(avatarView)
    contentView.addSubview(textStack)
    contentView.addSubview(badgeView)

    let margins = contentView.layoutMarginsGuide
    let minHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52)
    minHeight.priority = .init(999)
    NSLayoutConstraint.activate([
      avatarView.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
      avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
      avatarView.heightAnchor.constraint(equalToConstant: Self.avatarSize),
      avatarView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),

      textStack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
      textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
      textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),

      badgeView.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 8),
      badgeView.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
      badgeView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 2),
      badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -2),
      badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 7),
      badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -7),

      minHeight,
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    badgeView.layer.cornerRadius = badgeView.bounds.height / 2
    // Separators start under the name, as in Contacts.
    let inset = textStack.frame.minX
    if separatorInset.left != inset {
      separatorInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
    }
  }

  func configure(
    userInfo: UserInfo,
    isMe: Bool,
    detail: String?,
    role: MemberRole?,
    trailing: Trailing,
    isEnabled: Bool = true
  ) {
    avatarView.configure(with: userInfo, size: Self.avatarSize)
    nameLabel.text = userInfo.user.displayName
    youLabel.isHidden = !isMe
    detailLabel.text = detail
    detailLabel.isHidden = detail?.isEmpty ?? true

    switch role {
    case .owner:
      badgeView.isHidden = false
      badgeLabel.text = String(localized: "owner")
      badgeLabel.textColor = .systemPurple
      badgeView.backgroundColor = UIColor.systemPurple.withAlphaComponent(0.14)
    case .admin:
      badgeView.isHidden = false
      badgeLabel.text = String(localized: "admin")
      badgeLabel.textColor = .systemGreen
      badgeView.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.14)
    default:
      badgeView.isHidden = true
      badgeLabel.text = nil
    }

    accessoryView = nil
    accessoryType = .none
    switch trailing {
    case .none:
      break
    case .disclosure:
      accessoryType = .disclosureIndicator
    case let .selection(isSelected):
      let image = UIImageView(image: UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle"))
      image.tintColor = isSelected ? tintColor : .tertiaryLabel
      image.preferredSymbolConfiguration = .init(textStyle: .title3)
      image.sizeToFit()
      accessoryView = image
    case .activity:
      let spinner = UIActivityIndicatorView(style: .medium)
      spinner.startAnimating()
      accessoryView = spinner
    }
    contentView.alpha = isEnabled ? 1 : 0.5

    accessibilityLabel = [
      userInfo.user.displayName,
      isMe ? String(localized: "You") : nil,
      detail,
      badgeView.isHidden ? nil : badgeLabel.text,
    ].compactMap { $0 }.joined(separator: ", ")
  }
}

// MARK: - Field

/// "username" above "@sam", like Contacts. Tinted when tapping does something.
@MainActor
final class ChatInfoFieldCell: UITableViewCell {
  static let reuseIdentifier = "ChatInfoFieldCell"

  func configure(label: String, value: String, isAction: Bool) {
    var content = UIListContentConfiguration.subtitleCell()
    content.text = label
    content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
    content.textProperties.color = .secondaryLabel
    content.secondaryText = value
    content.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
    content.secondaryTextProperties.color = isAction ? .tintColor : .label
    content.secondaryTextProperties.numberOfLines = 0
    content.textToSecondaryTextVerticalPadding = 2
    contentConfiguration = content
    accessoryType = .none
    accessibilityTraits = isAction ? .button : .staticText
  }
}
