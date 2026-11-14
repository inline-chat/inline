import Foundation

/// Scroll physics as pure functions of time, so a whole fling can be computed up front and played by
/// the render server. The defaults were fitted to UIScrollView trajectories recorded on an
/// iPhone SE (iOS 27.2); see the phase 0 notes for the measurements.
///
/// Units: points and seconds. Displacement is positive when the content moves down (towards older
/// rows), the same sign as `TimelineScroll.by`.
public struct ScrollPhysics: Equatable, Sendable {
  /// Velocity kept after each millisecond of free deceleration.
  public var decelerationPerMillisecond = 0.998
  /// Free deceleration ends below this speed.
  public var stopVelocity = 10.0
  /// A release slower than this does not fling.
  public var minimumFlingVelocity = 250.0
  /// UIScrollView decelerates from slightly more than the release velocity it reports.
  public var releaseVelocityScale = 1.05
  /// Decay rate (1/s) of the velocity after a fling crosses an end.
  public var edgeDecay = 29.0
  /// Angular frequency (1/s) of the critically damped return after a fling crossed an end.
  public var edgeReturn = 11.3
  /// Angular frequency (1/s) of the critically damped return after a pull is released.
  public var pullReturn = 12.2
  /// Rubber band stiffness for a finger (0.715 for a trackpad).
  public var rubberBand = 0.55
  /// Spacing of the baked samples.
  public var sampleInterval = 1.0 / 120.0
  /// No path is longer than this.
  public var maximumDuration = 10.0

  public init() {}

  /// How far the content shows past an end when the finger has pulled `distance` past it.
  public func rubberBanded(_ distance: Double, dimension: Double) -> Double {
    guard dimension > 0, distance > 0 else { return 0 }
    return (1 - 1 / (distance * rubberBand / dimension + 1)) * dimension
  }

  /// The finger distance that shows as `shown` past an end.
  public func rubberBandInverse(_ shown: Double, dimension: Double) -> Double {
    guard dimension > 0, shown > 0 else { return 0 }
    let ratio = min(0.999, shown / dimension)
    return (1 / (1 - ratio) - 1) * dimension / rubberBand
  }

  /// The path the content takes after a release at `velocity`, as displacement from where it is.
  ///
  /// `lower` and `upper` are the displacements at which the content reaches its ends (nil: no end
  /// in reach). Zero outside that range means the release happened while pulled past an end; the
  /// path is then the return to that end and the velocity is ignored.
  public func path(velocity: Double, lower: Double? = nil, upper: Double? = nil, scalesVelocity: Bool = true) -> ScrollPath {
    let low = lower ?? -.infinity
    let high = max(upper ?? .infinity, low)
    let step = sampleInterval
    let decayPerSecond = log(decelerationPerMillisecond) * 1000

    enum Phase {
      case free
      case past(bound: Double)
      case returning(bound: Double, from: Double, elapsed: Double, frequency: Double)
    }

    var position = 0.0
    var speed = scalesVelocity ? velocity * releaseVelocityScale : velocity
    var phase = Phase.free
    if position > high {
      phase = .returning(bound: high, from: position - high, elapsed: 0, frequency: pullReturn)
      speed = 0
    } else if position < low {
      phase = .returning(bound: low, from: position - low, elapsed: 0, frequency: pullReturn)
      speed = 0
    }

    var positions = [position]
    var velocities = [speed]
    let limit = Int(maximumDuration / step)
    var touchesLower = false
    var touchesUpper = false

    func finish(at end: Double) -> ScrollPath {
      positions.append(end)
      velocities.append(0)
      return ScrollPath(
        interval: step, positions: positions, velocities: velocities, touchesLower: touchesLower,
        touchesUpper: touchesUpper
      )
    }

    while positions.count < limit {
      switch phase {
        case .free:
          let kept = exp(decayPerSecond * step)
          let travel = speed * (kept - 1) / decayPerSecond
          let next = position + travel
          if next > high || next < low {
            // The end is crossed inside this step: the rest of the step already decays past it.
            let bound = next > high ? high : low
            if bound == high { touchesUpper = true } else { touchesLower = true }
            let rest = step * (next - bound) / travel
            speed *= exp(decayPerSecond * (step - rest))
            let keptPast = exp(-edgeDecay * rest)
            position = bound + speed * (1 - keptPast) / edgeDecay
            speed *= keptPast
            phase = .past(bound: bound)
          } else if abs(speed * kept) < stopVelocity {
            position = next
            speed *= kept
            return finish(at: position)
          } else {
            position = next
            speed *= kept
          }

        case let .past(bound):
          let kept = exp(-edgeDecay * step)
          position += speed * (1 - kept) / edgeDecay
          speed *= kept
          if abs(speed) < 5 {
            phase = .returning(bound: bound, from: position - bound, elapsed: 0, frequency: edgeReturn)
          }

        case let .returning(bound, from, elapsed, frequency):
          if bound == high { touchesUpper = true } else { touchesLower = true }
          let time = elapsed + step
          let distance = from * (1 + frequency * time) * exp(-frequency * time)
          let next = bound + distance
          speed = (next - position) / step
          position = next
          phase = .returning(bound: bound, from: from, elapsed: time, frequency: frequency)
          if abs(distance) < 0.25 { return finish(at: bound) }
      }
      positions.append(position)
      velocities.append(speed)
    }
    return ScrollPath(
      interval: step, positions: positions, velocities: velocities, touchesLower: touchesLower,
      touchesUpper: touchesUpper
    )
  }
}

/// A baked scroll path: displacement and velocity at fixed intervals from its start.
public struct ScrollPath: Equatable, Sendable {
  public let interval: Double
  public let positions: [Double]
  public let velocities: [Double]
  /// The path reached the lower / upper end it was baked with.
  public let touchesLower: Bool
  public let touchesUpper: Bool

  public var duration: Double { Double(positions.count - 1) * interval }
  public var end: Double { positions[positions.count - 1] }

  public func position(at time: Double) -> Double {
    sample(positions, at: time)
  }

  public func velocity(at time: Double) -> Double {
    sample(velocities, at: time)
  }

  private func sample(_ values: [Double], at time: Double) -> Double {
    let exact = max(0, time / interval)
    let index = Int(exact)
    guard index < values.count - 1 else { return values[values.count - 1] }
    let fraction = exact - Double(index)
    return values[index] * (1 - fraction) + values[index + 1] * fraction
  }
}

/// The finger's velocity at release, from raw touch samples.
///
/// UIScrollView's own estimate is not public and no estimator matched it exactly on device (the
/// best, this one, averaged 0.92 of it over automated drags). To be tuned with real fingers.
public enum ReleaseVelocity {
  public struct Sample: Equatable, Sendable {
    public var time: Double
    public var position: Double

    public init(time: Double, position: Double) {
      self.time = time
      self.position = position
    }
  }

  /// Least squares slope over the last `window` seconds before `releaseTime`. A finger that rested
  /// before lifting gives zero.
  public static func estimate(_ samples: [Sample], releaseTime: Double, window: Double = 0.1, restTime: Double = 0.08) -> Double {
    guard let last = samples.last else { return 0 }
    // The last sample of a release repeats the previous position; what matters is the last move.
    var moving = samples[...]
    while moving.count > 2, abs(moving[moving.endIndex - 1].position - moving[moving.endIndex - 2].position) < 0.01 {
      moving = moving.dropLast()
    }
    guard let lastMove = moving.last, releaseTime - lastMove.time < restTime, last.time >= lastMove.time else { return 0 }
    let recent = moving.filter { $0.time >= lastMove.time - window }
    guard recent.count >= 2, let first = recent.first, lastMove.time - first.time > 0.004 else { return 0 }
    let count = Double(recent.count)
    let meanTime = recent.reduce(0) { $0 + $1.time } / count
    let meanPosition = recent.reduce(0) { $0 + $1.position } / count
    var numerator = 0.0
    var denominator = 0.0
    for sample in recent {
      numerator += (sample.time - meanTime) * (sample.position - meanPosition)
      denominator += (sample.time - meanTime) * (sample.time - meanTime)
    }
    return denominator > 0 ? numerator / denominator : 0
  }
}
