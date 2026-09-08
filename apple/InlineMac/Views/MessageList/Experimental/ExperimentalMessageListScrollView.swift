import AppKit
import QuartzCore
import os.signpost

/// Owns one interruptible viewport movement. Actual clip bounds advance on each
/// display frame, so a second send or user input starts at the visible position.
final class ExperimentalMessageListScrollView: MessageListScrollView {
  var willScrollFromInput: (() -> Void)?
  var didScrollFromInput: ((_ isDiscrete: Bool) -> Void)?

  private var displayLink: CADisplayLink?
  private static let animationLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  private var animationSignpostID: OSSignpostID?
  private var lastAnimationFrame: CFTimeInterval = 0
  private var maximumFrameInterval: CFTimeInterval = 0
  private var animationFrames = 0
  private var animationStart: CFTimeInterval = 0
  private var startY: CGFloat = 0
  private var targetY: CGFloat = 0
  private var completion: (() -> Void)?
  private var outgoingViewport: NSImageView?
  private var outgoingFrame: NSRect = .zero
  private var transitionDirection: CGFloat = 1
  private let duration: CFTimeInterval = 0.28

  func captureOutgoingViewport(direction: CGFloat) {
    cancelAnimatedScroll()
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
          let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return }
    contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
    let image = NSImage(size: contentView.bounds.size)
    image.addRepresentation(bitmap)
    let snapshot = NSImageView(frame: contentView.frame)
    snapshot.image = image
    snapshot.imageScaling = .scaleAxesIndependently
    snapshot.setAccessibilityElement(false)
    addSubview(snapshot, positioned: .above, relativeTo: contentView)
    outgoingViewport = snapshot
    outgoingFrame = snapshot.frame
    transitionDirection = direction < 0 ? -1 : 1
  }

  func cancelAnimatedScroll() {
    finishAnimationTrace()
    displayLink?.invalidate()
    displayLink = nil
    completion = nil
    outgoingViewport?.removeFromSuperview()
    outgoingViewport = nil
  }

  func moveViewport(to target: CGFloat, animated: Bool, completion: @escaping () -> Void) {
    // Delivery/status updates can request the same bottom while a send is moving.
    // Keep its clock and visible trajectory; only a changed destination retargets.
    if animated, displayLink != nil, abs(targetY - target) <= 0.5,
       !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      self.completion = completion
      return
    }
    finishAnimationTrace()
    displayLink?.invalidate()
    displayLink = nil
    self.completion = nil
    targetY = target
    guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let window else {
      cancelAnimatedScroll()
      contentView.scroll(to: NSPoint(x: 0, y: target))
      reflectScrolledClipView(contentView)
      completion()
      return
    }
    if outgoingViewport == nil, abs(contentView.bounds.minY - target) > contentView.bounds.height * 2 {
      captureOutgoingViewport(direction: target > contentView.bounds.minY ? 1 : -1)
    }
    if outgoingViewport != nil {
      let proposed = NSRect(
        origin: NSPoint(x: 0, y: target - transitionDirection * contentView.bounds.height * 0.35),
        size: contentView.bounds.size
      )
      contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
    }
    startY = contentView.bounds.minY
    guard abs(startY - target) > 0.5 || outgoingViewport != nil else { completion(); return }
    self.completion = completion
    animationStart = CACurrentMediaTime()
    animationFrames = 0
    lastAnimationFrame = animationStart
    maximumFrameInterval = 0
    let signpostID = OSSignpostID(log: Self.animationLog)
    animationSignpostID = signpostID
    os_signpost(.begin, log: Self.animationLog, name: "MacMessagesScrollAnimation", signpostID: signpostID)
    displayLink = window.displayLink(target: self, selector: #selector(advanceAnimation(_:)))
    displayLink?.add(to: .main, forMode: .common)
  }

  @objc private func advanceAnimation(_ link: CADisplayLink) {
    animationFrames += 1
    let now = CACurrentMediaTime()
    maximumFrameInterval = max(maximumFrameInterval, now - lastAnimationFrame)
    lastAnimationFrame = now
    let progress = min(1, max(0, (now - animationStart) / duration))
    let eased = 1 - pow(1 - progress, 3)
    contentView.scroll(to: NSPoint(x: 0, y: startY + (targetY - startY) * eased))
    reflectScrolledClipView(contentView)
    if let outgoingViewport {
      outgoingViewport.frame.origin.y = outgoingFrame.minY + (isFlipped ? -1 : 1) * transitionDirection * outgoingFrame.height * 0.35 * eased
      outgoingViewport.alphaValue = 1 - eased
    }
    if progress >= 1 {
      let finished = completion
      cancelAnimatedScroll()
      finished?()
    }
  }

  private func finishAnimationTrace() {
    guard let signpostID = animationSignpostID else { return }
    os_signpost(
      .end, log: Self.animationLog, name: "MacMessagesScrollAnimation", signpostID: signpostID,
      "frames=%{public}d max_interval_ms=%{public}.2f", Int32(animationFrames), maximumFrameInterval * 1_000
    )
    animationSignpostID = nil
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil { cancelAnimatedScroll() }
    super.viewWillMove(toWindow: newWindow)
  }

  override func scrollWheel(with event: NSEvent) {
    cancelAnimatedScroll()
    willScrollFromInput?()
    super.scrollWheel(with: event)
    didScrollFromInput?(event.phase.isEmpty && event.momentumPhase.isEmpty)
  }
}
