import AppKit
import SwiftUI

class ChatIconSwiftUIBridge: NSView {
  private var peerType: ChatIcon.PeerType?
  private var size: CGFloat

  private var hostingView: NSHostingView<ChatIcon>?

  init(_ peerType: ChatIcon.PeerType, size: CGFloat) {
    self.peerType = peerType
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
    guard let peerType else { return }

    // Remove existing hosting view
    hostingView?.removeFromSuperview()

    // Create new SwiftUI view
    let swiftUIView = ChatIcon(
      peer: peerType,
      size: size
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
