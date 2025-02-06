import AppKit
import InlineKit
import InlineUI
import SwiftUI

class UserAvatarView: NSView {
  private var userInfo: UserInfo?

  private var user: User? {
    userInfo?.user
  }

  private var hostingView: NSHostingView<UserAvatar>?

  init(userInfo: UserInfo) {
    self.userInfo = userInfo

    super.init(frame: NSRect(
      x: 0,
      y: 0,
      width: Theme.messageAvatarSize,
      height: Theme.messageAvatarSize
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

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func updateAvatar() {
    guard let userInfo else { return }

    // Remove existing hosting view
    hostingView?.removeFromSuperview()

    // Create new SwiftUI view
    let swiftUIView = UserAvatar(
      userInfo: userInfo,
      size: Theme.messageAvatarSize,
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
      width: Theme.messageAvatarSize,
      height: Theme.messageAvatarSize
    )
  }

  override func layout() {
    super.layout()

    // 7. Update hosting view frame during layout
    hostingView?.frame = bounds
  }
}
