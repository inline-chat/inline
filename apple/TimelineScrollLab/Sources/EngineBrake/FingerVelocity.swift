import Foundation

/// The finger's speed at the lift, the speed NSScrollView's fling starts from (lab fit on Mo's recorded gestures,
/// 2026-11-26: NSScrollView's release speed ≈ 0.90 × this, then AppKit's momentum calculator).
///
/// Speed = the distance of the finger events in the last `window` before the lift, over the time those events span.
/// - Merged events (a busy main thread coalesces scroll events): a merged event carries the sum of the deltas over its
///   interval and the latest time stamp, so distance over elapsed time weighs it by the time it covers, as if its parts
///   had come one by one. The first event in the window is only the start of the span: its delta was travelled before.
/// - A pause before the lift: if the finger's last event is older than `pauseLimit` at the lift, the finger had
///   stopped and the lift is not a fling (speed 0). The window is anchored at the lift, so a finger that slowed down
///   at the end gives the slower speed of its last 120 ms.
public struct FingerVelocity: Sendable {
  public var window: Double = 0.12
  public var pauseLimit: Double = 0.05
  private var samples: [(time: Double, delta: Double)] = []

  public init() {}

  public mutating func reset() { samples.removeAll(keepingCapacity: true) }

  /// One finger event: its delta (points, the list's sign) and its time stamp (seconds, the event's).
  public mutating func add(_ delta: Double, at time: Double) {
    samples.append((time, delta))
    // Keep a little more than the window: the event that opens the span.
    while let first = samples.first, time - first.time > window * 2 { samples.removeFirst() }
  }

  /// Points per second at a lift at `lift` (the lift event's time stamp); 0 for a lift after a pause or a single event.
  public func velocity(releasedAt lift: Double) -> Double {
    guard let last = samples.last, lift - last.time <= pauseLimit else { return 0 }
    let inWindow = samples.filter { $0.time >= lift - window }
    guard inWindow.count >= 2, let first = inWindow.first else { return 0 }
    let span = last.time - first.time
    guard span > 0.004 else { return 0 }
    let distance = inWindow.dropFirst().reduce(0) { $0 + $1.delta }
    return distance / span
  }
}
