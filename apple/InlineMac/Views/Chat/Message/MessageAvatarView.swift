import AppKit
import InlineKit
import InlineUI
import SwiftUI

class UserAvatarView: NSView {
  private var user: User?

  private var hostingView: NSHostingView<UserAvatar>?

  init(user: User) {
    self.user = user

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

  func setUser(_ user: User) {
    self.user = user
    updateAvatar()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func updateAvatar() {
    guard let user else { return }

    // Remove existing hosting view
    hostingView?.removeFromSuperview()

    // Create new SwiftUI view
    let swiftUIView = UserAvatar(
      user: user,
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
