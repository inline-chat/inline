import QuartzCore
import UIKit
// swiftlint:disable:next duplicate_imports
import UIKit.UIGestureRecognizerSubclass

/// Telegram's context gesture: after a short hold the source starts shrinking, and when the
/// shrink completes the menu opens. Moving the finger before that cancels it, so scrolling and
/// swipes keep working. After it opens, the gesture keeps reporting the finger, so sliding onto
/// an action and lifting picks it.
///
/// States: `.possible` through the press, `.began` when the menu should open, `.changed` while
/// the finger moves, `.ended` when it lifts.
final class MessageContextMenuHoldGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
  var motion = MessageContextMenuMotion.standard
  /// Whether a touch at a location in the gesture's view may start a press; checked when the
  /// finger lands, before any shrink.
  var acceptsTouch: ((CGPoint) -> Bool)?
  /// Movement that cancels the press before it opens the menu.
  var allowableMovement: CGFloat = 10

  /// The press starts at a location in the gesture's view. Return false to fail, for example
  /// when nothing under the finger has a menu.
  var onPressBegan: ((CGPoint) -> Bool)?
  /// Press progress from 0 to 1.
  var onPressProgress: ((CGFloat) -> Void)?
  /// The press ended without opening the menu.
  var onPressCancelled: (() -> Void)?

  private var startLocation: CGPoint?
  private var delayTimer: Timer?
  private var displayLink: CADisplayLink?
  private var pressStart: CFTimeInterval = 0
  private var isPressing = false
  private(set) var isActivated = false

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    // Opening the menu cancels the touch for the views under it, so a button in the bubble
    // doesn't fire when the finger lifts.
    cancelsTouchesInView = true
    delaysTouchesBegan = false
    delaysTouchesEnded = false
    delegate = self
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    acceptsTouch?(touch.location(in: view)) ?? true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Scrolls and swipes run alongside the press (and fail it by moving); once the menu is
    // open, nothing else may start under it.
    !isActivated
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    guard startLocation == nil, touches.count == 1, let touch = touches.first else {
      // A second finger means a pinch or a scroll, not a hold.
      fail()
      return
    }
    startLocation = touch.location(in: view)
    let timer = Timer(timeInterval: motion.pressDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.beginPress() }
    }
    RunLoop.main.add(timer, forMode: .common)
    delayTimer = timer
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)
    guard let touch = touches.first else { return }
    if isActivated {
      state = .changed
      return
    }
    guard let startLocation else { return }
    let location = touch.location(in: view)
    if hypot(location.x - startLocation.x, location.y - startLocation.y) > allowableMovement {
      fail()
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesEnded(touches, with: event)
    if isActivated {
      state = .ended
    } else {
      fail()
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesCancelled(touches, with: event)
    if isActivated {
      state = .cancelled
    } else {
      fail()
    }
  }

  override func reset() {
    super.reset()
    stopTimers()
    startLocation = nil
    isPressing = false
    isActivated = false
  }

  /// Fails a press that hasn't opened the menu yet, as when the list starts scrolling.
  func cancelPress() {
    guard !isActivated, state == .possible else { return }
    fail()
  }

  // MARK: - Press

  private func beginPress() {
    delayTimer = nil
    guard state == .possible, let startLocation else { return }
    guard onPressBegan?(startLocation) == true else {
      state = .failed
      return
    }
    isPressing = true
    pressStart = CACurrentMediaTime()
    onPressProgress?(0)
    let link = CADisplayLink(target: DisplayLinkTarget(self), selector: #selector(DisplayLinkTarget.tick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  fileprivate func tick() {
    guard isPressing, state == .possible else {
      stopTimers()
      return
    }
    let elapsed = CACurrentMediaTime() - pressStart
    let progress = motion.pressDuration > 0 ? min(1, elapsed / motion.pressDuration) : 1
    onPressProgress?(CGFloat(progress))
    if progress >= 1 {
      stopTimers()
      isPressing = false
      isActivated = true
      state = .began
    }
  }

  private func fail() {
    let wasPressing = isPressing
    stopTimers()
    isPressing = false
    if state == .possible {
      state = .failed
    }
    if wasPressing {
      onPressCancelled?()
    }
  }

  private func stopTimers() {
    delayTimer?.invalidate()
    delayTimer = nil
    displayLink?.invalidate()
    displayLink = nil
  }
}

/// Breaks the display link's strong reference to the gesture.
private final class DisplayLinkTarget: NSObject {
  weak var gesture: MessageContextMenuHoldGesture?

  init(_ gesture: MessageContextMenuHoldGesture) {
    self.gesture = gesture
  }

  @objc func tick() {
    MainActor.assumeIsolated { gesture?.tick() }
  }
}
