#if canImport(UIKit)
import QuartzCore
import TimelineCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// What the keyboard covers, as one value.
public struct KeyboardChange: Equatable, Sendable {
  /// How much of the tracked view's bottom the keyboard covers.
  public var height: CGFloat
  /// Move with this, in the call that delivers the change.
  public var timing: TimelineTiming
  /// A finger is moving the keyboard, or it is settling after one did.
  public var isInteractive: Bool
}

/// The one owner of the keyboard's effect on a chat screen. The composer's position and the list's
/// bottom inset both come from `onChange` and from nowhere else, so they cannot disagree.
///
/// - Open, close and reversal: one change, delivered inside the keyboard notification, carrying the
///   system's spring. Whatever is laid out in that call lands in the keyboard's own commit; one
///   run-loop turn later is a frame late.
/// - Interactive dismissal: the coordinator moves the keyboard itself (`KeyboardHost`) under a
///   passive window pan, so the keyboard, the composer and the list move in one transaction.
/// - Back swipe: `suspend()` while the interactive pop runs. The system posts a hide at the start
///   of the swipe and re-shows without animation on cancel; following either is the glitch.
@MainActor
public final class KeyboardCoordinator: NSObject, UIGestureRecognizerDelegate {
  public var onChange: ((KeyboardChange) -> Void)?
  /// The height of what rides on top of the keyboard (the composer). The keyboard starts to move
  /// when the finger crosses its top.
  public var ridingHeight: () -> CGFloat = { 0 }
  /// Whether a touch starting here (window coordinates) may dismiss the keyboard by dragging.
  public var allowsInteractiveDismissal: (CGPoint) -> Bool = { _ in true }
  /// What the coordinator decided and why, for probes.
  public var onDebug: ((String) -> Void)?
  /// A floating (undocked or split) keyboard counts up to its top, so what rides on it sits on it, as
  /// `UIKeyboardLayoutGuide.followsUndockedKeyboard` does. Off: a floating keyboard covers nothing.
  public var followsUndockedKeyboard = false

  public private(set) var height: CGFloat = 0
  public private(set) var isInteractive = false
  public private(set) var isSuspended = false
  /// The keyboard floats above the view's bottom edge (undocked or split, on iPad).
  public private(set) var isFloating = false

  private weak var view: UIView?
  private let pan = KeyboardPanGestureRecognizer()
  private var host: KeyboardHost?
  private var restHeight: CGFloat = 0
  private var offset: CGFloat = 0
  private var isEligible = false
  private var settle: Task<Void, Never>?
  /// The keyboard's last frame, in the screen's coordinates, read again when the view changes size.
  private var keyboardFrame: CGRect?
  /// The screen's bounds when that frame was posted: a frame from another orientation is not re-measured.
  private var keyboardScreen: CGRect?
  private var measuredSize: CGSize = .zero
  /// A rotation with the keyboard up, until the keyboard posts its frame for the new orientation.
  private var turn: Task<Void, Never>?
  /// What the keyboard covered, per size of the view, so a turn back to a size seen before moves what rides on
  /// it straight to where the keyboard will be.
  private var restHeights: [Size: CGFloat] = [:]

  private struct Size: Hashable {
    var width: Int
    var height: Int
    init(_ size: CGSize) {
      width = Int(size.width.rounded())
      height = Int(size.height.rounded())
    }
  }

  /// Tracks the keyboard against the bottom of `view`.
  public init(view: UIView) {
    self.view = view
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
    center.addObserver(
      self, selector: #selector(applicationWillResignActive), name: UIApplication.willResignActiveNotification,
      object: nil
    )
    pan.cancelsTouchesInView = false
    pan.delaysTouchesBegan = false
    pan.delaysTouchesEnded = false
    pan.delegate = self
    pan.onBegan = { [weak self] point in self?.fingerBegan(point) }
    pan.onMoved = { [weak self] point in self?.fingerMoved(point) }
    pan.onEnded = { [weak self] velocity in self?.fingerEnded(velocity: velocity) }
  }

  /// Call when the tracked view moves to a window (or leaves one).
  public func attach(to window: UIWindow?) {
    pan.view?.removeGestureRecognizer(pan)
    window?.addGestureRecognizer(pan)
    if window == nil {
      cancelInteraction(animated: false)
      turn?.cancel()
      turn = nil
    }
  }

  /// Stops following the keyboard (an interactive pop began).
  public func suspend() {
    isSuspended = true
    cancelInteraction(animated: false)
  }

  /// Follows the keyboard again. After a cancelled pop the keyboard is back where it was, so
  /// nothing is read or moved here.
  public func resume() {
    isSuspended = false
  }

  // MARK: - Animated changes

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    keyboardFrame = end
    keyboardScreen = view?.window?.screen.coordinateSpace.bounds
    guard !isSuspended, !isInteractive else { return }
    let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
    if turn != nil {
      // Mid-turn the keyboard posts the frames of its rotating snapshot, unanimated: empty, then shrunk in the
      // middle of the screen (iPad). Followed, the composer dropped to the bottom and jumped halfway up the
      // screen. Only its real frame, docked across the new screen, ends the turn.
      guard let screen = keyboardScreen, end.height >= 1, end.maxY >= screen.maxY - 1,
            abs(end.width - screen.width) < 1 else { return }
      // Posted with animations off: the composer's spring would land in one frame while the list's
      // tracks still moved. Settled from the next turn of the run loop, a frame after the keyboard.
      turn?.cancel()
      turn = Task { @MainActor [weak self] in self?.endTurn() }
      return
    }
    deliver(end, duration: duration)
  }

  /// Call from the tracked view's layout. When its size changed (a rotation, a window resize), what the
  /// keyboard covers is measured again from its last frame: a rotation can post the keyboard's new frame
  /// while the view still has its old size, and posts nothing after it takes the new one.
  public func viewDidLayout() {
    guard let view, let window = view.window, view.bounds.size != measuredSize else { return }
    guard !isSuspended, !isInteractive, let keyboardFrame else {
      measuredSize = view.bounds.size
      return
    }
    let screen = window.screen.coordinateSpace.bounds
    guard keyboardScreen.map({ $0 != screen }) != true else {
      // A frame posted for the other orientation says nothing about this one: measured against it, the
      // landscape keyboard read as one floating 804 pt up a portrait iPad. Inside a rotation the keyboard
      // turns with the screen and posts its new frame after the turn.
      measuredSize = view.bounds.size
      if height > 0, UIView.inheritedAnimationDuration > 0 { beginTurn(in: view) }
      return
    }
    deliver(keyboardFrame, duration: 0)
  }

  /// A rotation with the keyboard up. What the keyboard covers holds, or moves with the turn to what it covered at
  /// this size before, until the keyboard posts its frame for the new orientation (on iPad, 0.15 s after the
  /// turn ends) or, without one (a floating keyboard), a while after the turn.
  private func beginTurn(in view: UIView) {
    let duration = UIView.inheritedAnimationDuration
    turn?.cancel()
    turn = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(duration + 0.6))
      guard let self, !Task.isCancelled else { return }
      endTurn()
    }
    let size = Size(view.bounds.size)
    guard let known = restHeights[size], abs(known - height) > 0.01 else { return }
    height = known
    onChange?(KeyboardChange(height: known, timing: .inherited(by: view.layer), isInteractive: false))
  }

  /// The keyboard's frame after a turn lands without an animation of its own: what rides on it settles there
  /// with the keyboard's motion instead of in one frame.
  private func endTurn() {
    turn?.cancel()
    turn = nil
    guard !isSuspended, !isInteractive, let keyboardFrame else { return }
    deliver(keyboardFrame, duration: 0, timing: Self.spring(duration: 0.5))
  }

  private func deliver(_ end: CGRect, duration: Double, timing settling: TimelineTiming? = nil) {
    guard let view, let window = view.window else { return }
    measuredSize = view.bounds.size
    let frame = view.convert(end, from: window.screen.coordinateSpace)
    var covered = max(0, view.bounds.maxY - frame.minY)
    let closed = frame.height < 1 || frame.maxX <= view.bounds.minX || frame.minX >= view.bounds.maxX
    isFloating = !closed && frame.maxY < view.bounds.maxY - 1
    if closed || (isFloating && !followsUndockedKeyboard) {
      // Closed, beside the view, or floating above its bottom edge.
      covered = 0
    }
    covered = min(covered, view.bounds.height)
    if covered > 0 { restHeights[Size(view.bounds.size)] = covered }
    guard abs(covered - height) > 0.01 else { return }

    let timing: TimelineTiming
    if let settling {
      timing = settling
    } else if duration > 0 {
      timing = Self.spring(duration: duration)
    } else {
      // A rotation can post the new keyboard height inside its own animation.
      timing = .inherited(by: view.layer)
    }
    height = covered
    onChange?(KeyboardChange(height: covered, timing: timing, isInteractive: false))
  }

  private static func spring(duration: Double) -> TimelineTiming {
    if #available(iOS 26, *) {
      return .spring(mass: 1, stiffness: 555.027, damping: 47.118, duration: CGFloat(duration))
    }
    return .spring(mass: 3, stiffness: 1000, damping: 500, duration: CGFloat(duration))
  }

  // MARK: - Interactive dismissal

  private func fingerBegan(_ point: CGPoint) {
    isEligible = false
    // A floating keyboard is not dragged away, as UIKit's interactive dismissal leaves it.
    guard !isSuspended, !isInteractive, height > 0, !isFloating, let view, view.window != nil else { return }
    let composerTop = view.convert(view.bounds, to: nil).maxY - height - ridingHeight()
    isEligible = point.y < composerTop && allowsInteractiveDismissal(point)
    onDebug?("finger began y=\(point.y) composerTop=\(composerTop) eligible=\(isEligible)")
  }

  private func fingerMoved(_ point: CGPoint) {
    guard isEligible, let view else { return }
    if !isInteractive {
      let composerTop = view.convert(view.bounds, to: nil).maxY - height - ridingHeight()
      guard point.y > composerTop else { return }
      guard let host = KeyboardHost(scene: view.window?.windowScene) else {
        isEligible = false
        onDebug?("no keyboard host: interactive dismissal unavailable")
        return
      }
      self.host = host
      restHeight = height
      isInteractive = true
    }
    let composerTop = view.convert(view.bounds, to: nil).maxY - restHeight - ridingHeight()
    offset = min(max(0, point.y - composerTop), restHeight)
    host?.setOffset(offset)
    height = restHeight - offset
    onChange?(KeyboardChange(height: height, timing: .none, isInteractive: true))
  }

  private func fingerEnded(velocity: CGFloat?) {
    isEligible = false
    guard isInteractive, settle == nil else { return }
    guard let velocity else {
      cancelInteraction(animated: true)
      return
    }
    onDebug?("finger ended velocity=\(velocity) offset=\(offset) of \(restHeight)")
    if velocity > 100 || offset >= restHeight - 0.5 {
      finish(dismissing: true)
    } else {
      finish(dismissing: false)
    }
  }

  private func finish(dismissing: Bool) {
    let timing = Self.spring(duration: 0.3832)
    let target = dismissing ? restHeight : 0
    host?.setOffset(target, from: offset, timing: timing)
    offset = target
    height = restHeight - target
    onChange?(KeyboardChange(height: height, timing: timing, isInteractive: true))
    settle = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(0.3832))
      guard let self, !Task.isCancelled else { return }
      self.settle = nil
      if dismissing {
        // The keyboard is off screen: let go of it without the system animating anything.
        UIView.performWithoutAnimation { self.view?.window?.endEditing(true) }
      }
      self.host?.restore()
      self.host = nil
      self.isInteractive = false
    }
  }

  /// Puts the keyboard back at rest (the app is going away, or a pop began).
  private func cancelInteraction(animated: Bool) {
    guard isInteractive else { return }
    settle?.cancel()
    settle = nil
    if animated {
      finish(dismissing: false)
      return
    }
    host?.restore()
    host = nil
    offset = 0
    isInteractive = false
    if height != restHeight {
      height = restHeight
      onChange?(KeyboardChange(height: height, timing: .none, isInteractive: false))
    }
  }

  @objc private func applicationWillResignActive() {
    cancelInteraction(animated: false)
  }

  public func gestureRecognizer(
    _ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

/// Watches one finger across the whole window without ever claiming it: it stays `.possible`, so
/// the list, the composer and every control keep their touches.
final class KeyboardPanGestureRecognizer: UIGestureRecognizer {
  var onBegan: ((CGPoint) -> Void)?
  var onMoved: ((CGPoint) -> Void)?
  /// The finger's vertical velocity, or nil when the touch was cancelled.
  var onEnded: ((CGFloat?) -> Void)?
  private var points: [(y: CGFloat, time: TimeInterval)] = []

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    guard let touch = touches.first, event.allTouches?.count == 1 else { return }
    let point = touch.location(in: view)
    points = [(point.y, touch.timestamp)]
    onBegan?(point)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)
    guard let touch = touches.first else { return }
    let point = touch.location(in: view)
    points.append((point.y, touch.timestamp))
    if points.count > 12 { points.removeFirst() }
    onMoved?(point)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesEnded(touches, with: event)
    var velocity: CGFloat = 0
    if let touch = touches.first {
      let recent = points.filter { $0.time >= touch.timestamp - 0.1 }
      if let first = recent.first, let last = recent.last, last.time - first.time > 0.004 {
        velocity = (last.y - first.y) / CGFloat(last.time - first.time)
      }
    }
    onEnded?(velocity)
    state = .failed
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesCancelled(touches, with: event)
    onEnded?(nil)
    state = .failed
  }

  override func reset() {
    super.reset()
    points.removeAll()
  }
}
#endif
