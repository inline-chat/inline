#if os(macOS)
import QuartzCore
import TimelineCore

extension TimelineTiming {
  /// How long a track with this timing runs.
  var duration: CFTimeInterval {
    switch self {
      case .none: 0
      case let .spring(_, _, _, duration): CFTimeInterval(duration)
      case let .curve(duration, _, _, _, _): CFTimeInterval(duration)
    }
  }

  /// An additive track from `delta` to zero. Added to a layer whose model value is already final, it makes the
  /// layer appear to start `delta` away and settle. Tracks stack, so a change that arrives mid-flight continues
  /// from what is on screen without reading it. `beginTime` stays unset: the track starts in the commit it is
  /// added in, with everything else that change moves.
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

/// The last track key's number (`timeline.track.N`): a change that may be stopped records the numbers of its own.
@MainActor var trackSerial = 0

/// While a change commits: when its tracks begin. Without it a track starts when Core Animation commits the transaction,
/// a few milliseconds after the change's own clock (`commitTime`), which content tracks, scroll motions and pins are
/// computed on; a pin's lift then followed an earlier motion that many milliseconds early (5–13 pt on the first frames
/// of a far jump's slide, `update.insetWithDelete`). Every track of a change, the host's included (`addTrack` during
/// `updateRow`), begins on that clock instead.
@MainActor var trackClock: CFTimeInterval?

@MainActor func stamped(_ animation: CAAnimation) -> CAAnimation {
  if let begin = trackClock { animation.beginTime = begin }
  return animation
}

extension CALayer {
  /// Adds an additive track from `delta` to zero with this timing; nothing when the timing is `.none` or the
  /// distance is negligible. For views that move with the list (the composer).
  ///
  /// Each track gets a key of its own: tracks stack (none cuts another short), and `animationKeys()` lists them,
  /// which it does not for animations added without a key.
  @MainActor
  public func addTrack(_ timing: TimelineTiming, keyPath: String, from delta: CGFloat) {
    guard abs(delta) > 0.01, let track = timing.track(keyPath: keyPath, from: delta) else { return }
    trackSerial &+= 1
    // On the list's clock: inside a change, its `commitTime`; outside one (the composer, added just before the change
    // it moves with), now, microseconds before that change's clock, rather than when the transaction commits.
    track.beginTime = trackClock ?? CACurrentMediaTime()
    add(track, forKey: "timeline.track.\(trackSerial)")
  }
}
#endif
