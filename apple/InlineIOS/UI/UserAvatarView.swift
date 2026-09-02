import Auth
import InlineKit
import InlineUI
import SwiftUI
import UIKit

final class UserAvatarView: UIView {
  // MARK: - Properties

  private var size: CGFloat = 32
  private var widthConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?
  private var currentRenderSignature: RenderSignature?
  private var hostingController: UIHostingController<UserAvatar>?

  private struct RenderSignature: Equatable {
    let userId: Int64
    let firstName: String?
    let lastName: String?
    let username: String?
    let phoneNumber: String?
    let email: String?
    let avatarIdentity: String?
    let size: CGFloat
  }

  // MARK: - Initialization

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Setup

  private func setupViews() {
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    UIView.performWithoutAnimation {
      layer.cornerRadius = min(bounds.width, bounds.height) / 2
    }
  }

  // MARK: - Configuration

  func configure(with userInfo: UserInfo, size: CGFloat = 32) {
    self.size = size
    configureSize()

    let renderSignature = Self.renderSignature(for: userInfo, size: size)
    guard currentRenderSignature != renderSignature else { return }

    currentRenderSignature = renderSignature
    updateAvatar(with: userInfo)
  }

  // MARK: - Private Configuration Methods

  private func configureSize() {
    if let widthConstraint {
      widthConstraint.constant = size
    } else {
      widthConstraint = widthAnchor.constraint(equalToConstant: size)
      widthConstraint?.isActive = true
    }

    if let heightConstraint {
      heightConstraint.constant = size
    } else {
      heightConstraint = heightAnchor.constraint(equalToConstant: size)
      heightConstraint?.isActive = true
    }
  }

  private func updateAvatar(with userInfo: UserInfo) {
    let rootView = UserAvatar(
      userInfo: userInfo,
      size: size
    )

    if let hostingController {
      hostingController.rootView = rootView
      return
    }

    let controller = UIHostingController(rootView: rootView)
    controller.safeAreaRegions = []
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    controller.view.backgroundColor = .clear
    controller.view.clipsToBounds = true
    controller.view.isUserInteractionEnabled = false

    addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.topAnchor.constraint(equalTo: topAnchor),
      controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      controller.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    hostingController = controller
  }

  func currentImage() -> UIImage? {
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    let renderer = UIGraphicsImageRenderer(bounds: bounds)
    return renderer.image { context in
      layer.render(in: context.cgContext)
    }
  }

  private static func renderSignature(for userInfo: UserInfo, size: CGFloat) -> RenderSignature {
    let user = userInfo.user
    return RenderSignature(
      userId: user.id,
      firstName: user.firstName,
      lastName: user.lastName,
      username: user.username,
      phoneNumber: user.phoneNumber,
      email: user.email,
      avatarIdentity: userInfo.stableAvatarIdentity,
      size: size
    )
  }
}

// MARK: - UIColor Extensions

public extension UIColor {
  func adjustLuminosity(by percentage: CGFloat) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
    return UIColor(
      red: min(r + (1 - r) * percentage, 1.0),
      green: min(g + (1 - g) * percentage, 1.0),
      blue: min(b + (1 - b) * percentage, 1.0),
      alpha: a
    )
  }
}

/// A native status accessory; actor identity comes only from the ACK cursor's sidecar.
final class MessageAcknowledgementView: UIView {
  private let check = UIImageView(
    image: UIImage(
      systemName: "checkmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
    )
  )
  private let countLabel = UILabel()
  private var avatars: [UserAvatarView] = []
  private var actors: [FullAcknowledgement] = []
  private var avatarActors: [FullAcknowledgement] = []

  var onToggle: (() -> Void)?

  init() {
    super.init(frame: .zero)
    layer.cornerRadius = 8
    check.tintColor = .label
    countLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
      for: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
      maximumPointSize: 11
    )
    countLabel.adjustsFontForContentSizeCategory = true
    countLabel.textColor = .label
    countLabel.textAlignment = .center
    countLabel.adjustsFontSizeToFitWidth = true
    countLabel.minimumScaleFactor = 0.75
    addSubview(check)
    addSubview(countLabel)
    isAccessibilityElement = true
    accessibilityTraits = .staticText
    isHidden = true
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ message: FullMessage) {
    actors = message.acknowledgementActors
    avatarActors = actors.count <= 3 ? actors.filter { $0.userInfo != nil } : []
    isHidden = actors.isEmpty
    accessibilityLabel = actors.isEmpty ? nil : message.acknowledgementLabel

    if let action = message.acknowledgementAction(currentUserId: Auth.shared.getCurrentUserId()),
       onToggle != nil
    {
      accessibilityCustomActions = [
        UIAccessibilityCustomAction(
          name: action.clear ? "Remove Ack" : "Ack",
          target: self,
          selector: #selector(performToggleAccessibilityAction)
        ),
      ]
    } else {
      accessibilityCustomActions = nil
    }

    for (index, actor) in avatarActors.prefix(3).enumerated() {
      while avatars.count <= index {
        let avatar = UserAvatarView()
        avatar.isUserInteractionEnabled = false
        avatar.isAccessibilityElement = false
        avatars.append(avatar)
        addSubview(avatar)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          avatar.leftAnchor.constraint(
            equalTo: leftAnchor,
            constant: AcknowledgementLayout.avatarOriginX(at: index)
          ),
          avatar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        ])
      }
      if let userInfo = actor.userInfo {
        avatars[index].configure(with: userInfo, size: AcknowledgementLayout.avatarSize)
      }
    }
    setNeedsLayout()
  }

  @objc private func performToggleAccessibilityAction() -> Bool {
    guard let onToggle else { return false }
    onToggle()
    return true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    check.frame = CGRect(x: 3, y: 3, width: 10, height: 10)

    let shown = AcknowledgementLayout.visibleAvatarCount(
      actorCount: actors.count,
      width: bounds.width,
      availableAvatarCount: avatarActors.count
    )
    for (index, avatar) in avatars.enumerated() {
      avatar.isHidden = index >= shown
    }

    let remaining = max(0, actors.count - shown)
    countLabel.text = remaining > 0 ? (shown == 0 ? "\(remaining)" : "+\(remaining)") : nil
    countLabel.isHidden = remaining == 0
    let countX = AcknowledgementLayout.countOriginX(visibleAvatarCount: shown)
    countLabel.frame = CGRect(
      x: countX,
      y: 1,
      width: max(0, bounds.width - countX - 2),
      height: 14
    )
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
      || previousTraitCollection?.accessibilityContrast != traitCollection.accessibilityContrast
    {
      updateColors()
    }
  }

  private func updateColors() {
    let alpha: CGFloat = traitCollection.accessibilityContrast == .high ? 0.34 : 0.20
    backgroundColor = UIColor.systemBlue.withAlphaComponent(alpha)
    check.tintColor = .label
    countLabel.textColor = .label
  }
}
