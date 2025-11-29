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

    translatesAutoresizingMaskIntoConstraints = false

    setupView()
    updateAvatar()
  }

  func setupView() {
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
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
    newHostingView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(newHostingView)
    NSLayoutConstraint.activate([
      newHostingView.topAnchor.constraint(equalTo: topAnchor),
      newHostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
      newHostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      newHostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    hostingView = newHostingView
  }

  func update(peerType: ChatIcon.PeerType) {
    guard self.peerType != peerType else { return }
    self.peerType = peerType

    if let hostingView {
      hostingView.rootView = ChatIcon(peer: peerType, size: size)
    } else {
      updateAvatar()
    }
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
  }
}
