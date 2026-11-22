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
        if #available(iOS 17.0, *) {
          spring.allowsOverdamping = false
        }
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

extension CALayer {
  /// Adds an additive track from `delta` to zero with this timing; nothing when the timing is
  /// `.none` or the distance is negligible. For views that move with the list (the composer).
  public func addTrack(_ timing: TimelineTiming, keyPath: String, from delta: CGFloat) {
    guard abs(delta) > 0.01, let track = timing.track(keyPath: keyPath, from: delta) else { return }
    add(track, forKey: nil)
  }
}
#endif
