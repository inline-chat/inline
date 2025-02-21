import AppKit
import InlineKit
import InlineUI
import SwiftUI

class UserAvatarView: NSView {
  private var userInfo: UserInfo?

  private var user: User? {
    userInfo?.user
  }

  private var size: CGFloat

  private var hostingView: NSHostingView<UserAvatar>?

  init(userInfo: UserInfo, size: CGFloat = Theme.messageAvatarSize) {
    self.userInfo = userInfo
    self.size = size

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
    layerContentsRedrawPolicy = .onSetNeedsDisplay
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

  private func updateAvatar() {
    guard let userInfo else { return }

    // Remove existing hosting view
    hostingView?.removeFromSuperview()

    // Create new SwiftUI view
    let swiftUIView = UserAvatar(
      userInfo: userInfo,
      size: size,
      ignoresSafeArea: true
    )
    let newHostingView = NSHostingView(rootView: swiftUIView)

    // 4. For manual layout, set this to true
    newHostingView.translatesAutoresizingMaskIntoConstraints = true

    // 5. Set initial frame
    newHostingView.frame = bounds

    addSubview(newHostingView)
    hostingView = newHostingView
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
