#if canImport(UIKit)
import QuartzCore
import TimelineCore
import UIKit

extension TimelineTiming {
  /// How long a track with this timing runs.
  var duration: CFTimeInterval {
    switch self {
      case .none: 0
      case let .spring(_, _, _, duration): CFTimeInterval(duration)
      case let .curve(duration, _, _, _, _): CFTimeInterval(duration)
    }
  }

  /// An additive track from `delta` to zero. Added to a layer whose model value is already final,
  /// it makes the layer appear to start `delta` away and settle. Tracks stack, so a change that
  /// arrives mid-flight continues from what is on screen without reading it.
  ///
  /// `beginTime` is left unset on purpose: the track starts in the commit it is added in, which is
  /// how it lands in the same frame as the system keyboard's own animation.
  func track(keyPath: String, from delta: CGFloat) -> CAAnimation? {
    track(keyPath: keyPath, from: delta, to: CGFloat(0))
  }

  /// A track between values of any type the property animates additively; `to` is its zero.
  func track(keyPath: String, from delta: Any, to zero: Any) -> CAAnimation? {
    let animation: CABasicAnimation
    switch self {
      case .none:
        return nil
      case let .spring(mass, stiffness, damping, duration):
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = mass
        spring.stiffness = stiffness
        spring.damping = damping
        spring.initialVelocity = 0
        spring.duration = CFTimeInterval(duration)
        // As the system keyboard's own animation is set up (read on device, iOS 27.2).
        spring.timingFunction = CAMediaTimingFunction(name: .linear)
        spring.allowsOverdamping = false
        animation = spring
      case let .curve(duration, c1x, c1y, c2x, c2y):
        animation = CABasicAnimation(keyPath: keyPath)
        animation.duration = CFTimeInterval(duration)
        animation.timingFunction = CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y)
    }
    animation.fromValue = delta
    animation.toValue = zero
    animation.isAdditive = true
    animation.fillMode = .backwards
    animation.isRemovedOnCompletion = true
    return animation
  }
}

extension TimelineTiming {
  /// The animation the current layout pass runs in, as UIKit set it up for `layer`'s own frame change, so what
  /// moves inside a view moves exactly with its edges. A rotation is 0.4 s ease-in-out (read on iPad, iOS 27.2);
  /// a window resize can be a spring. When the layer's frame didn't change, UIKit's default curve over the
  /// inherited duration; outside an animation, none.
  @MainActor
  public static func inherited(by layer: CALayer) -> TimelineTiming {
    let duration = UIView.inheritedAnimationDuration
    guard duration > 0 else { return .none }
    // The newest frame animation added in this transaction (its begin time is set when it commits), not one
    // still running from an earlier change.
    let keys = (layer.animationKeys() ?? []).reversed().filter { $0.hasPrefix("bounds") || $0.hasPrefix("position") }
    for key in keys {
      guard let animation = layer.animation(forKey: key), animation.beginTime == 0 else { continue }
      if let spring = animation as? CASpringAnimation {
        return .spring(
          mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping, duration: spring.duration
        )
      }
      if let basic = animation as? CABasicAnimation, let curve = basic.timingFunction {
        var first: [Float] = [0, 0]
        var second: [Float] = [0, 0]
        curve.getControlPoint(at: 1, values: &first)
        curve.getControlPoint(at: 2, values: &second)
        return .curve(duration: basic.duration, c1x: first[0], c1y: first[1], c2x: second[0], c2y: second[1])
      }
    }
    return .curve(duration: duration, c1x: 0.42, c1y: 0, c2x: 0.58, c2y: 1)
  }
}

extension CALayer {
  /// Adds an additive track from `delta` to zero with this timing; nothing when the timing is
  /// `.none` or the distance is negligible. For views that move with the list (the composer).
  public func addTrack(_ timing: TimelineTiming, keyPath: String, from delta: CGFloat) {
    guard abs(delta) > 0.01, let track = timing.track(keyPath: keyPath, from: delta) else { return }
    add(track, forKey: nil)
  }
}
#endif
