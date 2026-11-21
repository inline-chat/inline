import CoreGraphics
import Foundation

/// A normalized easing curve for timed motion. Values follow Core Animation's
/// named timing functions so hosts can match a system animation exactly.
public enum ChatListTimingCurve: Equatable, Sendable {
  case linear
  case easeIn
  case easeOut
  case easeInOut
  case bezier(CGFloat, CGFloat, CGFloat, CGFloat)

  /// Progress on the curve for normalized time `t` in 0...1.
  public func solve(_ t: CGFloat) -> CGFloat {
    let t = min(1, max(0, t))
    switch self {
      case .linear: return t
      case .easeIn: return Self.bezierValue(0.42, 0, 1, 1, t)
      case .easeOut: return Self.bezierValue(0, 0, 0.58, 1, t)
      case .easeInOut: return Self.bezierValue(0.42, 0, 0.58, 1, t)
      case let .bezier(x1, y1, x2, y2): return Self.bezierValue(x1, y1, x2, y2, t)
    }
  }

  /// Cubic bezier from (0,0) to (1,1): solve x(s) = t, then return y(s).
  static func bezierValue(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ t: CGFloat) -> CGFloat {
    if t <= 0 { return 0 }
    if t >= 1 { return 1 }
    func sample(_ a1: CGFloat, _ a2: CGFloat, _ s: CGFloat) -> CGFloat {
      let inverse = 1 - s
      return 3 * inverse * inverse * s * a1 + 3 * inverse * s * s * a2 + s * s * s
    }
    func slope(_ a1: CGFloat, _ a2: CGFloat, _ s: CGFloat) -> CGFloat {
      let inverse = 1 - s
      return 3 * inverse * inverse * a1 + 6 * inverse * s * (a2 - a1) + 3 * s * s * (1 - a2)
    }
    var s = t
    for _ in 0 ..< 8 {
      let error = sample(x1, x2, s) - t
      if abs(error) < 1e-6 { return sample(y1, y2, s) }
      let derivative = slope(x1, x2, s)
      if abs(derivative) < 1e-6 { break }
      s -= error / derivative
    }
    var lower: CGFloat = 0
    var upper: CGFloat = 1
    s = t
    for _ in 0 ..< 40 {
      let x = sample(x1, x2, s)
      if abs(x - t) < 1e-6 { break }
      if x < t { lower = s } else { upper = s }
      s = (lower + upper) / 2
    }
    return sample(y1, y2, s)
  }
}

/// How one transaction moves. Springs are physical and keep velocity when a
/// later transaction retargets them; timed motion restarts from the presented
/// value with its own duration, like Telegram's list animations.
public enum ChatListMotion: Equatable, Sendable {
  case spring(stiffness: CGFloat, damping: CGFloat, mass: CGFloat = 1)
  case timed(duration: Double, curve: ChatListTimingCurve)

  /// The iOS 26 system spring: Telegram's list and keyboard curve and
  /// `MessageMotion.standard`. Critically damped, 0.27 s response.
  /// Telegram iOS row insertion (0.4 s on this curve) uses it as well.
  public static let system = ChatListMotion.spring(stiffness: 555.027, damping: 47.118)
  /// One more revealed line while a message streams (`MessageMotion.streamingLine`).
  public static let streamingLine = ChatListMotion.timed(duration: 0.15, curve: .easeInOut)
}

public extension ChatListMotion {
  /// Normalized position `elapsed` seconds after starting from rest.
  func progress(after elapsed: Double) -> CGFloat {
    var value = TimelineSpring(0)
    value.set(1, motion: self)
    value.advance(elapsed)
    return value.value
  }
}

/// One animated scalar. Springs are evaluated analytically, so a missed display
/// callback or a large step lands exactly where continuous motion would be.
struct TimelineSpring: Sendable {
  var value: CGFloat
  var velocity: CGFloat = 0
  var target: CGFloat
  var motion: ChatListMotion = .system
  private var start: CGFloat = 0
  private var elapsed: Double = 0

  init(_ value: CGFloat) {
    self.value = value
    target = value
  }

  var isSettled: Bool {
    switch motion {
      case .spring: abs(value - target) < 0.01 && abs(velocity) < 0.05
      case let .timed(duration, _): elapsed >= duration || abs(value - target) < 0.0001 && start == target
    }
  }

  mutating func advance(_ dt: Double) {
    guard dt > 0, !isSettled else {
      if isSettled { value = target
        velocity = 0
      }
      return
    }
    switch motion {
      case let .spring(stiffness, damping, mass):
        advanceSpring(dt, stiffness: stiffness, damping: damping, mass: mass)
      case let .timed(duration, curve):
        let previous = value
        elapsed = min(duration, elapsed + dt)
        let fraction = duration > 0 ? curve.solve(CGFloat(elapsed / duration)) : 1
        value = start + (target - start) * fraction
        velocity = (value - previous) / CGFloat(dt)
        if elapsed >= duration {
          value = target
          velocity = 0
        }
    }
  }

  private mutating func advanceSpring(_ dt: Double, stiffness: CGFloat, damping: CGFloat, mass: CGFloat) {
    let mass = max(0.0001, mass)
    let omega = sqrt(max(0.0001, stiffness) / mass)
    let zeta = max(0, damping) / (2 * sqrt(max(0.0001, stiffness) * mass))
    let t = CGFloat(dt)
    let x = value - target
    let v = velocity
    if abs(zeta - 1) < 0.0001 {
      let coefficient = v + omega * x
      let decay = exp(-omega * t)
      value = target + (x + coefficient * t) * decay
      velocity = (v - omega * coefficient * t) * decay
    } else if zeta < 1 {
      let damped = omega * sqrt(1 - zeta * zeta)
      let decay = exp(-zeta * omega * t)
      let b = (v + zeta * omega * x) / damped
      let cosine = cos(damped * t)
      let sine = sin(damped * t)
      value = target + decay * (x * cosine + b * sine)
      velocity = decay * ((b * damped - zeta * omega * x) * cosine - (x * damped + zeta * omega * b) * sine)
    } else {
      let root = omega * sqrt(zeta * zeta - 1)
      let r1 = -zeta * omega + root
      let r2 = -zeta * omega - root
      let c2 = (v - r1 * x) / (r2 - r1)
      let c1 = x - c2
      let e1 = exp(r1 * t)
      let e2 = exp(r2 * t)
      value = target + c1 * e1 + c2 * e2
      velocity = c1 * r1 * e1 + c2 * r2 * e2
    }
    if isSettled {
      value = target
      velocity = 0
    }
  }

  /// Retarget with the default system spring, or jump when not animated.
  mutating func set(_ target: CGFloat, animated: Bool) {
    set(target, motion: animated ? .system : nil)
  }

  /// Retarget with a motion, or jump when `motion` is nil. Springs keep their
  /// velocity; timed motion restarts from the presented value.
  mutating func set(_ target: CGFloat, motion: ChatListMotion?) {
    guard let motion else {
      self.target = target
      value = target
      velocity = 0
      start = target
      elapsed = 0
      if case .timed = self.motion { self.motion = .system }
      return
    }
    if case .timed = motion, self.target == target, self.motion == motion { return }
    self.target = target
    self.motion = motion
    if case .timed = motion {
      start = value
      elapsed = 0
      if abs(value - target) < 0.0001 { value = target
        velocity = 0
        start = target
      }
    }
  }
}
