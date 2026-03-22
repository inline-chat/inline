import AppKit
import InlineKit
import InlineUI
import SwiftUI

class UserAvatarView: NSView {
  private var userInfo: UserInfo?
  private var size: CGFloat
  private var currentRenderSignature: RenderSignature?

  private var hostingView: NSHostingView<UserAvatar>?

  private struct RenderSignature: Equatable {
    let userId: Int64
    let firstName: String?
    let lastName: String?
    let username: String?
    let phoneNumber: String?
    let email: String?
    let avatarIdentity: String?
  }

  init(userInfo: UserInfo, size: CGFloat = Theme.messageAvatarSize) {
    self.userInfo = userInfo
    self.size = size
    currentRenderSignature = Self.renderSignature(for: userInfo)

    super.init(frame: NSRect(
      x: 0,
      y: 0,
      width: size,
      height: size
    ))

    setupView()
    updateAvatar()
  }

  func setupView() {
    // Layer optimization
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    layer?.drawsAsynchronously = true

    // Only enable if content rarely changes
    layer?.shouldRasterize = true
    layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0

    // 3. For manual layout, set this to true
    translatesAutoresizingMaskIntoConstraints = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(userInfo: UserInfo) {
    let nextRenderSignature = Self.renderSignature(for: userInfo)
    guard currentRenderSignature != nextRenderSignature else { return }
    self.userInfo = userInfo
    currentRenderSignature = nextRenderSignature
    updateAvatar()
  }

  private func updateAvatar() {
    guard let userInfo else { return }

    let rootView = UserAvatar(
      userInfo: userInfo,
      size: size,
      ignoresSafeArea: true
    )

    if let hostingView {
      hostingView.rootView = rootView
    } else {
      let newHostingView = NSHostingView(rootView: rootView)
      newHostingView.translatesAutoresizingMaskIntoConstraints = true
      newHostingView.frame = bounds
      addSubview(newHostingView)
      hostingView = newHostingView
    }
  }

  private static func renderSignature(for userInfo: UserInfo) -> RenderSignature {
    let user = userInfo.user
    return RenderSignature(
      userId: user.id,
      firstName: user.firstName,
      lastName: user.lastName,
      username: user.username,
      phoneNumber: user.phoneNumber,
      email: user.email,
      avatarIdentity: userInfo.stableAvatarIdentity
    )
  }

  override var intrinsicContentSize: NSSize {
    // 6. Provide intrinsic size
    NSSize(
      width: size,
      height: size
    )
  }

  override func layout() {
    super.layout()

    // 7. Update hosting view frame during layout
    hostingView?.frame = bounds
  }
}
