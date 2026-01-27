import AppKit
import SwiftUI

final class SidebarChatIconSwiftUIBridge: NSView {
  private var peerType: ChatIcon.PeerType?
  private var size: CGFloat
  private var ignoresSafeArea: Bool

  private var hostingView: NSHostingView<AnyView>?

  init(_ peerType: ChatIcon.PeerType, size: CGFloat, ignoresSafeArea: Bool = false) {
    self.peerType = peerType
    self.size = size
    self.ignoresSafeArea = ignoresSafeArea

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

    hostingView?.removeFromSuperview()

    let swiftUIView = makeRootView(peerType: peerType)
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
      hostingView.rootView = makeRootView(peerType: peerType)
    } else {
      updateAvatar()
    }
  }

  func update(size: CGFloat) {
    guard self.size != size else { return }
    self.size = size
    invalidateIntrinsicContentSize()
    if let peerType, let hostingView {
      hostingView.rootView = makeRootView(peerType: peerType)
    } else {
      updateAvatar()
    }
  }

  private func makeRootView(peerType: ChatIcon.PeerType) -> AnyView {
    let view = SidebarChatIcon(peer: peerType, size: size)
    return ignoresSafeArea ? AnyView(view.ignoresSafeArea()) : AnyView(view)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(
      width: size,
      height: size
    )
  }

  override func layout() {
    super.layout()
  }
}
