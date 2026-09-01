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
    layerContentsRedrawPolicy = .never
    layer?.drawsAsynchronously = true

    // Only enable if content rarely changes
    layer?.shouldRasterize = true
    layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0

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
      ignoresSafeArea: true
    )

    if let hostingView {
      hostingView.rootView = rootView
    } else {
      let newHostingView = NSHostingView(rootView: rootView)
      newHostingView.translatesAutoresizingMaskIntoConstraints = true
      newHostingView.wantsLayer = true
      newHostingView.frame = bounds
      addSubview(newHostingView)
      hostingView = newHostingView
      applyPressedTransform()
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
    if window == nil {
      setPressed(false)
    } else {
      layer?.rasterizationScale = window?.backingScaleFactor ?? 2.0
      PressScaleAnimator.prepare(self)
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

/// Explicit acknowledgement status. This leaf never sends a read receipt or an emoji reaction.
final class MessageAcknowledgementView: NSView {
  private let check = NSImageView()
  private let countLabel = NSTextField(labelWithString: "")
  private var avatars: [UserAvatarView] = []
  private var actors: [FullAcknowledgement] = []
  private var avatarActors: [FullAcknowledgement] = []
  private var animationGeneration: UInt = 0
  private(set) var isAnimatingRemoval = false
  private(set) var isRTL = false
  var onToggle: (() -> Void)?
  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
    check.symbolConfiguration = .init(pointSize: 10, weight: .bold)
    countLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    countLabel.alignment = .center
    countLabel.lineBreakMode = .byClipping
    addSubview(check)
    addSubview(countLabel)
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    isHidden = true
    updateColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_: NSPoint) -> NSView? {
    // The pill is status, not a separate mouse target. The message owns double-click.
    nil
  }

  func configure(
    _ message: FullMessage,
    fallbackRTL: Bool,
    action: AcknowledgementAction?,
    animated: Bool = false
  ) {
    animationGeneration &+= 1
    let generation = animationGeneration
    layer?.removeAllAnimations()

    let wasVisible = !isHidden
    let nextActors = message.acknowledgementActors
    let nextAvatarActors = nextActors.filter { $0.userInfo != nil }
    let isVisible = !nextActors.isEmpty
    let shouldAnimateRemoval = animated
      && wasVisible
      && !isVisible
      && window != nil
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    if !shouldAnimateRemoval {
      actors = nextActors
      avatarActors = nextAvatarActors
    }
    isRTL = AcknowledgementLayout.isRTL(message.displayText, fallback: fallbackRTL)
    setAccessibilityLabel(isVisible ? message.acknowledgementLabel : nil)
    toolTip = isVisible ? message.acknowledgementLabel : nil

    if let action, onToggle != nil {
      setAccessibilityCustomActions([
        NSAccessibilityCustomAction(
          name: action.clear ? "Remove Ack" : "Ack"
        ) { [weak self] in
          guard let onToggle = self?.onToggle else { return false }
          onToggle()
          return true
        },
      ])
    } else {
      setAccessibilityCustomActions(nil)
    }

    for (index, actor) in avatarActors.prefix(3).enumerated() {
      guard let userInfo = actor.userInfo else { continue }
      while avatars.count <= index {
        let avatar = UserAvatarView(userInfo: userInfo, size: 12)
        avatar.acceptsMouseInteraction = false
        avatar.setAccessibilityElement(false)
        avatars.append(avatar)
        addSubview(avatar)
      }
      avatars[index].update(userInfo: userInfo, size: 12)
    }
    for avatar in avatars.dropFirst(min(3, avatarActors.count)) {
      avatar.isHidden = true
    }

    if shouldAnimateRemoval {
      isAnimatingRemoval = true
      isHidden = false
      alphaValue = 1
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.14
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().alphaValue = 0
      } completionHandler: { [weak self] in
        guard let self, self.animationGeneration == generation else { return }
        self.actors = nextActors
        self.avatarActors = nextAvatarActors
        self.isAnimatingRemoval = false
        self.isHidden = true
        self.alphaValue = 1
        self.needsLayout = true
      }
      return
    }

    isAnimatingRemoval = false
    isHidden = !isVisible
    alphaValue = 1
    if animated, !wasVisible, isVisible, window != nil,
       !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    {
      alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animator().alphaValue = 1
      }
    }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    check.frame = CGRect(x: 3, y: 3, width: 10, height: 10)
    let shown = AcknowledgementLayout.visibleAvatarCount(
      actorCount: actors.count,
      width: bounds.width,
      availableAvatarCount: avatarActors.count
    )
    for (index, avatar) in avatars.enumerated() {
      avatar.isHidden = index >= shown
      avatar.frame = CGRect(x: 14 + CGFloat(index) * 14, y: 2, width: 12, height: 12)
    }
    let remaining = max(0, actors.count - shown)
    countLabel.stringValue = remaining > 0 ? (shown == 0 ? "\(remaining)" : "+\(remaining)") : ""
    countLabel.isHidden = remaining == 0
    countLabel.frame = CGRect(
      x: 14 + CGFloat(shown) * 14,
      y: 1,
      width: max(0, bounds.width - 16 - CGFloat(shown) * 14),
      height: 14
    )
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    let alpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.34 : 0.20
    layer?.backgroundColor = NSColor.controlAccentColor
      .withAlphaComponent(alpha)
      .resolvedColor(with: effectiveAppearance)
      .cgColor
    check.contentTintColor = .labelColor
    countLabel.textColor = .labelColor
  }
}
