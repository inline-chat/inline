import AppKit
import InlineKit
import InlineUI
import SwiftUI

class ChatIconSwiftUIBridge: NSView {
  private var peerType: ChatIcon.PeerType?
  private var size: CGFloat
  private var backgroundOpacity: Double
  private var ignoresSafeArea: Bool
  private var showsBotOnlineIndicator: Bool

  private var hostingView: NSHostingView<AnyView>?

  init(
    _ peerType: ChatIcon.PeerType,
    size: CGFloat,
    backgroundOpacity: Double = 1.0,
    ignoresSafeArea: Bool = false,
    showsBotOnlineIndicator: Bool = false
  ) {
    self.peerType = peerType
    self.size = size
    self.backgroundOpacity = backgroundOpacity
    self.ignoresSafeArea = ignoresSafeArea
    self.showsBotOnlineIndicator = showsBotOnlineIndicator

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

  private func makeRootView(peerType: ChatIcon.PeerType) -> AnyView {
    var botUser: InlineKit.User?
    if showsBotOnlineIndicator, case let .user(userInfo) = peerType {
      botUser = userInfo.user
    }
    let view = ChatIcon(peer: peerType, size: size, backgroundOpacity: backgroundOpacity)
      .botOnlineIndicator(botUser, avatarSize: size)
    return ignoresSafeArea ? AnyView(view.ignoresSafeArea()) : AnyView(view)
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
