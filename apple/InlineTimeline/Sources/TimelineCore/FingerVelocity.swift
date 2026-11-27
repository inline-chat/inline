import Foundation

/// The fingers' speed at the lift, as NSScrollView reads it for its fling: the distance of the tracked events in the
/// last `window` before the last event, over the time they span. Measured against NSScrollView on Mo's recorded
/// gestures (NSScrollView lane, phase 5): AppKit's calculator from 0.9 × this speed travels within 2–8% of
/// NSScrollView. A merged event counts by the time it covers (the first event only opens the span).
/// Fingers that rest before lifting mean to stop: a lift more than `pauseLimit` (60 ms) after the last event releases
/// without speed, the list's rule since its first lab (`input.rest-before-lift`). NSScrollView, replayed, still flung
/// after rests up to ~150 ms (70–110% of the travel) and not after 200 ms; we keep the stop.
public struct FingerVelocity: Sendable {
  public var window: Double = 0.12
  public var pauseLimit: Double = 0.06
  private var samples: [(time: Double, delta: Double)] = []

  public init() {}

  public mutating func reset() {
    samples.removeAll(keepingCapacity: true)
  }

  public mutating func add(_ delta: Double, at time: Double) {
    samples.append((time, delta))
    while let first = samples.first, time - first.time > window * 2 { samples.removeFirst() }
  }

  /// Points per second (the deltas' sign), or 0 for a lift after a pause or too few events.
  public func velocity(releasedAt lift: Double) -> Double {
    guard let last = samples.last, lift - last.time <= pauseLimit else { return 0 }
    let inWindow = samples.filter { $0.time >= last.time - window }
    guard inWindow.count >= 2, let first = inWindow.first else { return 0 }
    let span = last.time - first.time
    guard span > 0.004 else { return 0 }
    return inWindow.dropFirst().reduce(0) { $0 + $1.delta } / span
  }
}
