import AppKit
import Combine
import InlineKit
import Logger

class SidebarSenderView: NSStackView {
  private var userInfo: UserInfo

  // MARK: - UI props

  static let avatarSize: CGFloat = 13
  static let height: CGFloat = 16

  var user: User {
    userInfo.user
  }

  init(userInfo: UserInfo) {
    self.userInfo = userInfo
    super.init(frame: .zero)
    setup()
  }

  private func setup() {
    orientation = .horizontal
    spacing = 2
    alignment = .centerY
    translatesAutoresizingMaskIntoConstraints = false

    addArrangedSubview(avatarView)
    addArrangedSubview(nameLabel)
    configure(with: userInfo)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The avatar view
  lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView(
      userInfo: userInfo,
      size: Self.avatarSize
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// The title label
  lazy var nameLabel: NSTextField = {
    let view = NSTextField()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isEditable = false
    view.isBordered = false
    view.backgroundColor = .clear
    view.font = .systemFont(ofSize: 12)
    view.textColor = .secondaryLabelColor
    view.lineBreakMode = .byTruncatingTail
    view.maximumNumberOfLines = 1
    return view
  }()

  /// The sender view

  func configure(with userInfo: UserInfo) {
    self.userInfo = userInfo

    // Update avatar
    avatarView.removeFromSuperview()
    avatarView = UserAvatarView(
      userInfo: userInfo,
      size: Self.avatarSize
    )
    avatarView.translatesAutoresizingMaskIntoConstraints = false
    insertArrangedSubview(avatarView, at: 0)

    // Update name
    nameLabel.stringValue = user.firstName ??
      user.lastName ??
      user.username ??
      user.phoneNumber ??
      user.email ?? ""
  }
}
