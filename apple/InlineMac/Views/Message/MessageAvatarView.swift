import AppKit
import InlineKit
import InlineUI
import SwiftUI

class UserAvatarView: NSView {
  var onClick: (() -> Void)?
  var acceptsMouseInteraction = true

  private var userInfo: UserInfo?
  private var size: CGFloat
  private var currentRenderSignature: RenderSignature?
  private var currentBackingScale: CGFloat?
  private var isPressed = false

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
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true

    // Only enable if content rarely changes
    layer?.shouldRasterize = true
    updateLayerScaling()

    // 3. For manual layout, set this to true
    translatesAutoresizingMaskIntoConstraints = true
    PressScaleAnimator.prepare(self)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = acceptsMouseInteraction && bounds.contains(point) ? self : nil
    MessageGestureTrace.trace(
      "MessageAvatarView.hitTest point=\(MessageGestureTrace.point(point)) accepts=\(acceptsMouseInteraction) hit=\(hit != nil)"
    )
    return hit
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(userInfo: UserInfo, size nextSize: CGFloat? = nil) {
    let nextRenderSignature = Self.renderSignature(for: userInfo)
    let resolvedSize = nextSize ?? size
    let sizeChanged = size != resolvedSize
    guard currentRenderSignature != nextRenderSignature || sizeChanged else { return }
    self.userInfo = userInfo
    currentRenderSignature = nextRenderSignature
    if sizeChanged {
      size = resolvedSize
      invalidateIntrinsicContentSize()
    }
    updateAvatar()
  }

  private func updateAvatar() {
    guard let userInfo else { return }

    let rootView = UserAvatar(
      userInfo: userInfo,
      size: size,
      ignoresSafeArea: true,
      displayScale: currentBackingScale ?? backingScale
    )

    if let hostingView {
      hostingView.rootView = rootView
      hostingView.layer?.setNeedsDisplay()
    } else {
      let newHostingView = NSHostingView(rootView: rootView)
      newHostingView.translatesAutoresizingMaskIntoConstraints = true
      newHostingView.wantsLayer = true
      newHostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
      newHostingView.layer?.contentsScale = currentBackingScale ?? backingScale
      newHostingView.frame = bounds
      addSubview(newHostingView)
      hostingView = newHostingView
      updateLayerScaling()
      applyPressedTransform()
    }

    layer?.setNeedsDisplay()
  }

  private var backingScale: CGFloat {
    max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0, 1)
  }

  @discardableResult
  private func updateLayerScaling() -> Bool {
    let scale = backingScale
    let scaleChanged = currentBackingScale != scale
    currentBackingScale = scale
    layer?.contentsScale = scale
    layer?.rasterizationScale = scale
    hostingView?.layer?.contentsScale = scale
    return scaleChanged
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
    if updateLayerScaling() {
      updateAvatar()
    }
  }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.debug(
      "MessageAvatarView.mouseDown type=\(event.type.rawValue) clicks=\(event.clickCount) point=\(MessageGestureTrace.point(convert(event.locationInWindow, from: nil))) accepts=\(acceptsMouseInteraction)"
    )
    guard acceptsMouseInteraction else {
      MessageGestureTrace.debug("MessageAvatarView.mouseDown forwardingToSuper reason=disabled")
      super.mouseDown(with: event)
      return
    }
    guard event.type == .leftMouseDown else {
      MessageGestureTrace.debug("MessageAvatarView.mouseDown forwardingToSuper reason=eventType")
      super.mouseDown(with: event)
      return
    }

    setPressed(true)
    guard let window else {
      MessageGestureTrace.debug("MessageAvatarView.mouseDown noWindow")
      setPressed(false)
      return
    }

    while let next = window.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp],
      until: .distantFuture,
      inMode: .eventTracking,
      dequeue: true
    ) {
      let isInside = bounds.contains(convert(next.locationInWindow, from: nil))
      switch next.type {
      case .leftMouseDragged:
        MessageGestureTrace.trace(
          "MessageAvatarView.mouseDragged inside=\(isInside) point=\(MessageGestureTrace.point(convert(next.locationInWindow, from: nil)))"
        )
        setPressed(isInside)
      case .leftMouseUp:
        setPressed(false)
        if isInside {
          MessageGestureTrace.debug("MessageAvatarView.mouseUp action=onClick")
          onClick?()
        } else {
          MessageGestureTrace.debug("MessageAvatarView.mouseUp cancelledOutside")
        }
        return
      default:
        break
      }
    }

    MessageGestureTrace.debug("MessageAvatarView.mouseDown trackingEndedWithoutMouseUp")
    setPressed(false)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let scaleChanged = updateLayerScaling()
    if window == nil {
      setPressed(false)
    } else {
      if scaleChanged {
        updateAvatar()
      }
      PressScaleAnimator.prepare(self)
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if updateLayerScaling() {
      updateAvatar()
    }
  }

  private func setPressed(_ pressed: Bool) {
    guard isPressed != pressed else { return }
    isPressed = pressed

    applyPressedTransform()
  }

  private func applyPressedTransform() {
    PressScaleAnimator.setPressed(isPressed, on: self)
  }
}
