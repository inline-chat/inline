#if os(macOS)
import Foundation
import Testing
@testable import TimelineAppKit
import TimelineCore

/// On the main actor, one test at a time, as the list calls it: AppKit's momentum calculator gave a different travel
/// now and then when tests called it from several threads at once.
@MainActor
@Suite("NativeScrolling", .serialized)
struct NativeScrollingTests {
  @Test("AppKit's momentum calculator is there on this system")
  func calculatorExists() {
    #expect(NativeScrolling.hasNativeMomentum)
  }

  @Test("A fling in open space travels the way it was thrown and comes to rest")
  func freeFling() {
    let down = NativeScrolling.path(velocity: 2000, lower: nil, upper: nil, viewportHeight: 700)
    let up = NativeScrolling.path(velocity: -2000, lower: nil, upper: nil, viewportHeight: 700)
    #expect(down.end > 200)
    #expect(up.end < -200)
    #expect(abs(down.end + up.end) < 1)
    #expect(down.positions.first == 0)
    // Monotonic: no bounce in open space.
    #expect(zip(down.positions, down.positions.dropFirst()).allSatisfy { $1 >= $0 - 0.01 })
    #expect(abs(down.velocities.last ?? 1) < 0.5)
  }

  @Test("Faster flings go further, as NSScrollView's do (travel grows faster than velocity)")
  func travelGrows() {
    let slow = NativeScrolling.path(velocity: 1000, lower: nil, upper: nil, viewportHeight: 700).end
    let fast = NativeScrolling.path(velocity: 4000, lower: nil, upper: nil, viewportHeight: 700).end
    #expect(fast > slow * 4)
  }

  @Test("A fling into an end overshoots it a little and settles on it")
  func bounce() {
    let path = NativeScrolling.path(velocity: 3000, lower: nil, upper: 300, viewportHeight: 700)
    #expect(path.touchesUpper)
    let peak = path.positions.max() ?? 0
    #expect(peak > 300)
    #expect(peak < 300 + 120)
    #expect(abs(path.end - 300) < 0.5)
  }

  @Test("Released past an end with no velocity, the content returns to the end")
  func pullReturn() {
    // Pulled 40 pt past the oldest end: the end is 40 pt behind (upper = -40).
    let path = NativeScrolling.path(velocity: 0, lower: -5000, upper: -40, viewportHeight: 700)
    #expect(abs(path.end - -40) < 0.5)
    #expect(path.duration > 0.15 && path.duration < 1.0)
  }

  @Test("Without the private calculator the fallback still flings and bounces")
  func fallback() {
    UserDefaults.standard.set(true, forKey: "timeline.nativeMomentum.disabled")
    defer { UserDefaults.standard.removeObject(forKey: "timeline.nativeMomentum.disabled") }
    let path = NativeScrolling.path(velocity: 2000, lower: nil, upper: 200, viewportHeight: 700)
    #expect(path.touchesUpper)
    #expect(abs(path.end - 200) < 0.5)
  }
}

@Suite("WheelVelocity")
struct WheelVelocityTests {
  @Test("Steady trackpad moves give their speed")
  func steady() {
    var v = WheelVelocity()
    for i in 0 ..< 20 { v.add(10, at: Double(i) / 120) }
    let speed = v.velocity(releasedAt: 19.0 / 120 + 0.008)
    #expect(abs(speed - 1200) < 1)
  }

  @Test("A finger that rested before lifting releases at zero")
  func rested() {
    var v = WheelVelocity()
    for i in 0 ..< 20 { v.add(10, at: Double(i) / 120) }
    #expect(v.velocity(releasedAt: 19.0 / 120 + 0.1) == 0)
  }

  @Test("Only the last 50 ms count")
  func recent() {
    var v = WheelVelocity()
    for i in 0 ..< 20 { v.add(30, at: Double(i) / 120) }
    for i in 20 ..< 30 { v.add(5, at: Double(i) / 120) }
    let speed = v.velocity(releasedAt: 29.0 / 120 + 0.008)
    #expect(abs(speed - 600) < 1)
  }
}
#endif
