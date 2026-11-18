#if canImport(UIKit)
import QuartzCore
import TimelineCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The list's pan. It reports the touch landing before any recogniser begins (so a fling stops under
/// the finger at once) and keeps raw touch samples for the release velocity.
final class TimelinePanGestureRecognizer: UIPanGestureRecognizer {
  var onTouchDown: (() -> Void)?
  /// Set while the touch that landed stopped a moving list: the pan begins with the finger's first
  /// vertical movement, with no dead zone, so a finger that catches the list and goes on scrolling
  /// moves it at once, as a decelerating scroll view does.
  var beginsOnFirstMove = false
  private var touchDownLocation: CGPoint?
  /// The finger lifted (or was cancelled) without the pan beginning: a tap.
  var onTouchUpWithoutPan: (() -> Void)?
  private(set) var samples: [ReleaseVelocity.Sample] = []
  private(set) var releaseTime: TimeInterval = 0

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if numberOfTouches == 0, let touch = touches.first {
      samples = [ReleaseVelocity.Sample(time: touch.timestamp, position: Double(touch.location(in: nil).y))]
      touchDownLocation = touch.location(in: nil)
      beginsOnFirstMove = false
      onTouchDown?()
    }
    super.touchesBegan(touches, with: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first {
      for coalesced in event.coalescedTouches(for: touch) ?? [touch] {
        samples.append(ReleaseVelocity.Sample(time: coalesced.timestamp, position: Double(coalesced.location(in: nil).y)))
      }
      if samples.count > 240 { samples.removeFirst(samples.count - 240) }
    }
    super.touchesMoved(touches, with: event)
    if beginsOnFirstMove, state == .possible, let start = touchDownLocation, let touch = touches.first {
      let location = touch.location(in: nil)
      let dx = abs(location.x - start.x), dy = abs(location.y - start.y)
      if dy >= 1, dy >= dx { state = .began }
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first {
      releaseTime = touch.timestamp
      samples.append(ReleaseVelocity.Sample(time: touch.timestamp, position: Double(touch.location(in: nil).y)))
    }
    let tapped = state == .possible
    super.touchesEnded(touches, with: event)
    if tapped { onTouchUpWithoutPan?() }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    let tapped = state == .possible
    super.touchesCancelled(touches, with: event)
    if tapped { onTouchUpWithoutPan?() }
  }

  override func reset() {
    super.reset()
    samples.removeAll()
    beginsOnFirstMove = false
    touchDownLocation = nil
  }

  /// The finger's vertical velocity at release, in window points per second (positive: downward). A
  /// trackpad or mouse scroll has no touches: the recogniser's own velocity stands in.
  func releaseVelocity() -> CGFloat {
    guard samples.count >= 2 else { return velocity(in: nil).y }
    return CGFloat(ReleaseVelocity.estimate(samples, releaseTime: releaseTime))
  }
}

/// The Objective-C facing half of the list's input: gesture targets, the gesture delegate and the
/// display link. `TimelineListView` is generic, so it keeps these here and receives closures.
@MainActor
final class TimelineInput: NSObject, UIGestureRecognizerDelegate {
  let pan = TimelinePanGestureRecognizer()
  var onPan: ((TimelinePanGestureRecognizer) -> Void)?
  /// Drags the scroll indicator, as UIScrollView's can be dragged to move through long content.
  let indicatorPan = UIPanGestureRecognizer()
  var onIndicatorPan: ((UIPanGestureRecognizer) -> Void)?
  /// Whether a touch starting here (in the list) lands on the shown indicator.
  var startsOnIndicator: (CGPoint) -> Bool = { _ in false }
  var onTick: ((CADisplayLink) -> Void)?
  private var link: CADisplayLink?

  override init() {
    super.init()
    pan.addTarget(self, action: #selector(handlePan(_:)))
    pan.delegate = self
    indicatorPan.addTarget(self, action: #selector(handleIndicatorPan(_:)))
    indicatorPan.delegate = self
    indicatorPan.maximumNumberOfTouches = 1
    pan.maximumNumberOfTouches = 1
    pan.delaysTouchesEnded = false
    // Trackpads and mouse wheels scroll the list too (iPad).
    pan.allowedScrollTypesMask = .all
  }

  @objc private func handlePan(_ recognizer: TimelinePanGestureRecognizer) {
    onPan?(recognizer)
  }

  @objc private func handleIndicatorPan(_ recognizer: UIPanGestureRecognizer) {
    onIndicatorPan?(recognizer)
  }

  @objc private func handleTick(_ link: CADisplayLink) {
    onTick?(link)
  }

  var isTicking: Bool { link != nil }

  func startTicking(maximumFramesPerSecond: Int) {
    guard link == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(handleTick(_:)))
    let maximum = Float(maximumFramesPerSecond)
    link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stopTicking() {
    link?.invalidate()
    link = nil
  }

  // Anything but a near-horizontal drag scrolls, as a scroll view does with a diagonal one; a row's
  // reply swipe takes drags within 24 degrees of horizontal. From the left edge only vertical drags, so
  // the navigation back swipe keeps its own.
  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    if recognizer === indicatorPan, let view = indicatorPan.view {
      let translation = indicatorPan.translation(in: view)
      let location = indicatorPan.location(in: view)
      return startsOnIndicator(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
    }
    guard recognizer === pan, let view = pan.view else { return true }
    let velocity = pan.velocity(in: view)
    let start = pan.location(in: view).x - pan.translation(in: view).x
    // A drag on the shown indicator moves through the content instead.
    if startsOnIndicator(CGPoint(x: start, y: pan.location(in: view).y - pan.translation(in: view).y)) { return false }
    if start < 24 { return abs(velocity.y) >= abs(velocity.x) }
    return abs(velocity.y) >= abs(velocity.x) * tan(24 * .pi / 180)
  }

  // Passive watchers of the same finger (the keyboard's window pan, presses) run alongside; another
  // pan (a row swipe, the back swipe) does not.
  func gestureRecognizer(
    _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    !(other is UIPanGestureRecognizer)
  }
}
#endif
