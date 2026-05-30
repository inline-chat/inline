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
      size: size,
      ignoresSafeArea: true
    )

    if let hostingController {
      hostingController.rootView = rootView
      return
    }

    let controller = UIHostingController(rootView: rootView)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    controller.view.backgroundColor = .clear
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
