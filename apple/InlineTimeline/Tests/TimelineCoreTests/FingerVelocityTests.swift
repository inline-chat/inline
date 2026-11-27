import Testing
@testable import TimelineCore

@Suite("Finger velocity at the lift (NSScrollView's reading)")
struct FingerVelocityTests {
  /// Events every 1/60 s moving `delta` each, the last at `end`.
  private func steady(_ delta: Double, count: Int, end: Double = 1) -> FingerVelocity {
    var finger = FingerVelocity()
    for i in 0 ..< count { finger.add(delta, at: end - Double(count - 1 - i) / 60) }
    return finger
  }

  @Test("Steady events give their speed")
  func steadySpeed() {
    let finger = steady(20, count: 12)
    #expect(abs(finger.velocity(releasedAt: 1.005) - 1200) < 1)
  }

  @Test("Only the last 120 ms count")
  func window() {
    var finger = steady(5, count: 20, end: 0.8)
    for i in 1 ... 8 { finger.add(30, at: 0.8 + Double(i) / 60) }
    #expect(abs(finger.velocity(releasedAt: 0.8 + 8.0 / 60) - 1800) < 1)
  }

  @Test("A merged event counts by the time it covers")
  func mergedEvent() {
    var finger = FingerVelocity()
    finger.add(10, at: 0.9)
    finger.add(10, at: 0.9 + 1.0 / 60)
    finger.add(20, at: 0.9 + 3.0 / 60) // two refreshes' worth in one event
    #expect(abs(finger.velocity(releasedAt: 0.96) - 600) < 1)
  }

  @Test("A rest before the lift: a fling up to 60 ms, none after")
  func pause() {
    let finger = steady(-20, count: 10)
    #expect(finger.velocity(releasedAt: 1.05) < -1000)
    #expect(finger.velocity(releasedAt: 1.07) == 0)
  }

  @Test("One event, or none, gives no speed")
  func tooFew() {
    var finger = FingerVelocity()
    #expect(finger.velocity(releasedAt: 1) == 0)
    finger.add(40, at: 1)
    #expect(finger.velocity(releasedAt: 1.01) == 0)
  }
}
