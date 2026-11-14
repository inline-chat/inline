#if canImport(UIKit)
import QuartzCore
import TimelineCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The list's pan. It reports the touch landing before any recogniser begins (so a fling stops under
/// the finger at once) and keeps raw touch samples for the release velocity.
final class TimelinePanGestureRecognizer: UIPanGestureRecognizer {
  var onTouchDown: (() -> Void)?
  private(set) var samples: [ReleaseVelocity.Sample] = []
  private(set) var releaseTime: TimeInterval = 0

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    if numberOfTouches == 0, let touch = touches.first {
      samples = [ReleaseVelocity.Sample(time: touch.timestamp, position: Double(touch.location(in: nil).y))]
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
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first {
      releaseTime = touch.timestamp
      samples.append(ReleaseVelocity.Sample(time: touch.timestamp, position: Double(touch.location(in: nil).y)))
    }
    super.touchesEnded(touches, with: event)
  }

  /// The finger's vertical velocity at release, in window points per second (positive: downward).
  func releaseVelocity() -> CGFloat {
    CGFloat(ReleaseVelocity.estimate(samples, releaseTime: releaseTime))
  }
}

/// The Objective-C facing half of the list's input: gesture targets, the gesture delegate and the
/// display link. `TimelineListView` is generic, so it keeps these here and receives closures.
@MainActor
final class TimelineInput: NSObject, UIGestureRecognizerDelegate {
  let pan = TimelinePanGestureRecognizer()
  var onPan: ((TimelinePanGestureRecognizer) -> Void)?
  var onTick: ((CADisplayLink) -> Void)?
  private var link: CADisplayLink?

  override init() {
    super.init()
    pan.addTarget(self, action: #selector(handlePan(_:)))
    pan.delegate = self
    pan.maximumNumberOfTouches = 1
    pan.delaysTouchesEnded = false
    pan.allowedScrollTypesMask = .continuous
  }

  @objc private func handlePan(_ recognizer: TimelinePanGestureRecognizer) {
    onPan?(recognizer)
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

  // Vertical drags only, so row swipes and the navigation back swipe keep theirs.
  func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard recognizer === pan, let view = pan.view else { return true }
    let velocity = pan.velocity(in: view)
    return abs(velocity.y) >= abs(velocity.x)
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
