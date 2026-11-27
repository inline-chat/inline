#if os(macOS)
import AppKit
import Darwin
import ObjectiveC
import TimelineCore

/// What NSScrollView does after a trackpad lets go, so a list that is not a scroll view feels like one.
///
/// Measured in TimelineMacLab (macOS 27.2, `results/native.*.hid.json`): NSScrollView ignores the deltas of
/// the momentum events the system sends after a gesture. It runs AppKit's own momentum calculator
/// (`_NSScrollingMomentumCalculator`, the "Cates" variant on this system) from the velocity it measured at
/// release, on its concurrent display-link animation. With no momentum events at all, it flings the same.
/// The calculator also does the bounce when the fling runs into an end, and the return from a pull.
/// Past an end during a gesture the content moves by a fixed share of the finger's travel.
///
/// The calculator is private. When it is missing (a future system), `ScrollPhysics` from TimelineCore takes
/// over with constants fitted to it.
public enum NativeScrolling {
  /// Share of the finger's travel the content moves past an end, during a gesture. NSScrollView on 27.2:
  /// 600 pt pulled showed 40 pt (0.067), linear.
  nonisolated(unsafe) public static var rubberBandShare: CGFloat = 0.067

  /// NSScrollView flings faster than the last event's speed. Fitted on travel against NSScrollView's for the same
  /// synthetic gestures (lab suite, `fling.travel-*`): ×1.15 matches within 4% from 500 to 4,000 pt/s; faster it
  /// grows (8,000 pt/s needs ×1.33). The estimate below already weighs the last frames; this scales it.
  nonisolated(unsafe) public static var releaseVelocityGain: Double = 1.15

  /// The gain for a release estimated at `velocity`: `releaseVelocityGain` up to 4,000 pt/s, then growing with the
  /// speed's doubling (+0.18 per doubling), capped at ×1.35 rather than extrapolated past what was measured.
  public static func releaseGain(for velocity: Double) -> Double {
    let speed = abs(velocity)
    guard speed > 4000 else { return releaseVelocityGain }
    return min(1.35, releaseVelocityGain + 0.18 * log2(speed / 4000))
  }

  /// Below this the release is a stop, not a fling.
  nonisolated(unsafe) public static var minimumFlingVelocity: Double = 60

  /// Whether AppKit's calculator is there.
  public static var hasNativeMomentum: Bool { calculatorClass != nil }

  /// The path of a fling released at `velocity` (points per second, positive: the content moves down, towards
  /// older rows), with the content able to travel `lower...upper` (nil: unknown, far), starting `overscroll`
  /// past an end (positive: past the oldest end). Displacements as `TimelineScroll.by`.
  public static func path(
    velocity: Double, lower: Double?, upper: Double?, viewportHeight: Double, interval: Double = 1.0 / 240
  ) -> ScrollPath {
    if let path = nativePath(velocity: velocity, lower: lower, upper: upper, viewportHeight: viewportHeight, interval: interval) {
      return path
    }
    var physics = ScrollPhysics()
    physics.decelerationPerMillisecond = 0.9955
    physics.releaseVelocityScale = 1
    physics.minimumFlingVelocity = minimumFlingVelocity
    return physics.path(velocity: velocity, lower: lower, upper: upper, scalesVelocity: false)
  }

  /// The system's momentum as real trackpad gestures show it (its 60 Hz momentum events, logged from Dev builds on
  /// 2026-11-26): fast flicks lose about 5% of their speed every 1/60 s; slow ones hold their speed for about 0.12 s,
  /// then decay faster. Over whole streams the travel is 0.28–0.35 × the starting speed; this shape gives that within
  /// about 15% (time constant 0.18 s slow to 0.28 s fast). AppKit's calculator, fitted earlier against NSScrollView's
  /// fallback for synthetic events, decays more slowly at speed (about 0.44 s at 8,000 pt/s): flings went too far.
  public static func momentumShape(for speed: Double) -> (hold: Double, tau: Double) {
    let s = max(1, abs(speed))
    let f = min(1, max(0, (log(s) - log(1500)) / (log(12000) - log(1500))))
    let tau = 0.18 + (0.28 - 0.18) * f
    let hold = s <= 2500 ? 0.12 : (s >= 6000 ? 0 : 0.12 * (6000 - s) / 3500)
    return (hold, tau)
  }

  /// A fling shaped as the system's momentum (`momentumShape`), released at `velocity`. One that would reach a real end
  /// (`lower`/`upper` known and within its travel) takes AppKit's calculator instead, which bounces there.
  public static func systemPath(
    velocity: Double, lower: Double?, upper: Double?, viewportHeight: Double, interval: Double = 1.0 / 240,
    continuing tau: Double? = nil
  ) -> ScrollPath {
    // A fling continued mid-way (a page moved an end) keeps its decay and does not hold again.
    let shape = momentumShape(for: velocity)
    let hold = tau == nil ? shape.hold : 0
    let tau = tau ?? shape.tau
    let stop = 15.0
    let decay = abs(velocity) > stop ? tau * log(abs(velocity) / stop) : 0
    let duration = min(hold + decay, 4)
    let total = velocity * hold + velocity * tau * (1 - exp(-max(0, duration - hold) / tau))
    if let upper, total > upper - 0.5 {
      return path(velocity: velocity, lower: lower, upper: upper, viewportHeight: viewportHeight, interval: interval)
    }
    if let lower, total < lower + 0.5 {
      return path(velocity: velocity, lower: lower, upper: upper, viewportHeight: viewportHeight, interval: interval)
    }
    let count = max(1, Int((duration / interval).rounded(.up)))
    var positions: [Double] = []
    var velocities: [Double] = []
    positions.reserveCapacity(count + 1)
    velocities.reserveCapacity(count + 1)
    for step in 0 ... count {
      let t = min(duration, Double(step) * interval)
      if t <= hold {
        positions.append(velocity * t)
        velocities.append(velocity)
      } else {
        let k = exp(-(t - hold) / tau)
        positions.append(velocity * hold + velocity * tau * (1 - k))
        velocities.append(velocity * k)
      }
    }
    velocities[velocities.count - 1] = 0
    return ScrollPath(interval: interval, positions: positions, velocities: velocities, touchesLower: false, touchesUpper: false)
  }

  // MARK: - AppKit's calculator

  private typealias Make = @convention(c) (AnyObject, Selector, CGPoint, CGPoint, CGRect, CGPoint, CGSize) -> AnyObject
  private typealias Position = @convention(c) (AnyObject, Selector, Double) -> CGPoint
  private typealias Duration = @convention(c) (AnyObject, Selector) -> Double

  private static var disabled: Bool { UserDefaults.standard.bool(forKey: "timeline.nativeMomentum.disabled") }

  private static let calculatorClass: AnyClass? = {
    _ = NSScrollView.self
    return objc_getClass("_NSScrollingMomentumCalculator") as? AnyClass
  }()

  private static func nativePath(
    velocity: Double, lower: Double?, upper: Double?, viewportHeight: Double, interval: Double
  ) -> ScrollPath? {
    guard !disabled, let cls = calculatorClass else { return nil }
    let makeSelector = sel_registerName("initWithInitialOrigin:velocity:documentFrame:constrainedClippingOrigin:clippingSize:")
    let positionSelector = sel_registerName("positionAfterDuration:")
    let durationSelector = sel_registerName("durationUntilStop")
    guard let allocated = (cls as AnyObject).perform(sel_registerName("alloc"))?.takeUnretainedValue(),
          let makeIMP = class_getMethodImplementation(object_getClass(allocated), makeSelector) else { return nil }

    // The calculator works on a clip view's origin: it grows as the content moves up (towards newer rows),
    // the opposite of a `.by` displacement. Unknown ends are far away.
    let far = 10_000_000.0
    let minOrigin = -(upper ?? far)
    let maxOrigin = -(lower ?? -far)
    let height = max(1, viewportHeight)
    let document = CGRect(x: 0, y: minOrigin, width: 1, height: max(0, maxOrigin - minOrigin) + height)
    let clamped = min(max(0, minOrigin), maxOrigin)
    let make = unsafeBitCast(makeIMP, to: Make.self)
    let calculator = make(
      allocated, makeSelector, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -velocity), document, CGPoint(x: 0, y: clamped),
      CGSize(width: 1, height: height)
    )
    guard let positionIMP = class_getMethodImplementation(object_getClass(calculator), positionSelector) else { return nil }
    let position = unsafeBitCast(positionIMP, to: Position.self)
    var duration = 3.0
    if class_respondsToSelector(object_getClass(calculator), durationSelector),
       let durationIMP = class_getMethodImplementation(object_getClass(calculator), durationSelector)
    {
      duration = unsafeBitCast(durationIMP, to: Duration.self)(calculator, durationSelector)
    }
    guard duration.isFinite, duration >= 0 else { return nil }
    duration = min(duration, 10)

    let count = max(1, Int((duration / interval).rounded(.up)))
    var positions: [Double] = []
    positions.reserveCapacity(count + 1)
    var touchesLower = false
    var touchesUpper = false
    for step in 0 ... count {
      let origin = Double(position(calculator, positionSelector, min(duration, Double(step) * interval)).y)
      guard origin.isFinite else { return nil }
      let displacement = -origin
      if let upper, displacement >= upper - 0.25 { touchesUpper = true }
      if let lower, displacement <= lower + 0.25 { touchesLower = true }
      positions.append(displacement)
    }
    positions[0] = 0
    // The calculator stops near an end it settles on, not on it: within half a point from a plain fling, ~6 pt when
    // it starts deep past the end (a re-bake after the end moved mid-bounce). NSScrollView then sits on the end.
    // The tail eases onto it over its last 0.15 s, so the rest that follows has nothing to snap (Telegram CoreList:
    // settle exactly on the edge).
    let last = positions[positions.count - 1]
    let settled = [touchesUpper ? upper : nil, touchesLower ? lower : nil].compactMap { $0 }
      .min { abs($0 - last) < abs($1 - last) }
    if let settled, abs(settled - last) > 0.001, abs(settled - last) < 40 {
      let gap = settled - last
      let window = max(1, min(positions.count - 1, Int((0.15 / interval).rounded())))
      for k in 0 ..< window {
        let fraction = Double(k + 1) / Double(window)
        positions[positions.count - window + k] += gap * fraction * fraction * (3 - 2 * fraction)
      }
    }
    var velocities = [Double](repeating: 0, count: positions.count)
    for i in 0 ..< positions.count - 1 {
      velocities[i] = (positions[i + 1] - positions[i]) / interval
    }
    return ScrollPath(
      interval: interval, positions: positions, velocities: velocities, touchesLower: touchesLower,
      touchesUpper: touchesUpper
    )
  }
}

/// Estimates the release velocity of a trackpad gesture from its events, as points per second.
struct WheelVelocity {
  private var samples: [(time: CFTimeInterval, delta: CGFloat)] = []

  mutating func reset() { samples.removeAll(keepingCapacity: true) }

  mutating func add(_ delta: CGFloat, at time: CFTimeInterval) {
    samples.append((time, delta))
    if samples.count > 32 { samples.removeFirst(samples.count - 32) }
  }

  /// Travel over the last 50 ms before the last movement, over that span; zero when the finger rested before
  /// lifting (no movement in the last 60 ms).
  func velocity(releasedAt release: CFTimeInterval) -> Double {
    guard let last = samples.last(where: { abs($0.delta) > 0.01 }), release - last.time < 0.06 else { return 0 }
    let window = 0.05
    let recent = samples.filter { $0.time >= last.time - window && $0.time <= last.time }
    guard recent.count >= 2, let first = recent.first else { return 0 }
    let span = last.time - first.time
    guard span > 0.004 else { return 0 }
    // The first sample's delta happened before its own time: count the travel after it.
    let travel = recent.dropFirst().reduce(0) { $0 + Double($1.delta) }
    return travel / span
  }
}
#endif
