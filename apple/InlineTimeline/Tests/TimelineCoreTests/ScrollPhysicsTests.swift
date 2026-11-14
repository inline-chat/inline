import Foundation
import Testing
@testable import TimelineCore

@Suite struct ScrollPhysicsTests {
  let physics = ScrollPhysics()

  @Test func freeFlingTravelsAboutHalfASecondOfVelocity() {
    // Measured on device: UIScrollView travels about velocity × 0.50 s from its effective start velocity.
    for velocity in [600.0, 1800.0, 4300.0, -1800.0] {
      let path = physics.path(velocity: velocity)
      let expected = velocity * physics.releaseVelocityScale * 0.4995
      #expect(abs(path.end - expected) < abs(expected) * 0.02)
      #expect(!path.touchesLower && !path.touchesUpper)
    }
  }

  @Test func freeFlingDurationMatchesTheScrollView() {
    // Device: 2.07 s at 594 pt/s reported, 3.08 s at 4305 pt/s.
    #expect(abs(physics.path(velocity: 594).duration - 2.07) < 0.1)
    #expect(abs(physics.path(velocity: 4305).duration - 3.08) < 0.1)
  }

  @Test func pathIsContinuousAndSlowsDown() {
    let path = physics.path(velocity: 3000)
    var largest = 0.0
    for index in 1 ..< path.positions.count {
      let step = path.positions[index] - path.positions[index - 1]
      #expect(step >= -0.001)
      largest = max(largest, step)
    }
    #expect(largest <= 3000 * physics.releaseVelocityScale * physics.sampleInterval + 0.001)
    #expect(path.velocities.last == 0)
  }

  @Test func flingIntoAnEndOvershootsAndReturnsToIt() {
    let path = physics.path(velocity: 3000, upper: 200)
    #expect(path.touchesUpper)
    #expect(path.end == 200)
    let peak = path.positions.max() ?? 0
    #expect(peak > 200)
    // The velocity at the end decays at 29/s, so the overshoot is about a 29th of it.
    #expect(peak - 200 < 3000 * physics.releaseVelocityScale / physics.edgeDecay)
  }

  @Test func flingIntoTheLowerEndMirrorsTheUpperOne() {
    let up = physics.path(velocity: 2500, upper: 150)
    let down = physics.path(velocity: -2500, lower: -150)
    #expect(down.touchesLower)
    #expect(up.positions.count == down.positions.count)
    for index in up.positions.indices {
      #expect(abs(up.positions[index] + down.positions[index]) < 0.0001)
    }
  }

  @Test func releaseWhilePulledPastAnEndReturnsWithoutUsingTheVelocity() {
    // The content sits 80 pt past its upper end: the end is at displacement -80.
    let path = physics.path(velocity: 900, lower: -5000, upper: -80)
    #expect(path.end == -80)
    #expect(path.positions.allSatisfy { $0 <= 0.0001 && $0 >= -80.0001 })
    // Device: a released pull is back within half a point in about 0.65 s.
    #expect(abs(path.duration - 0.65) < 0.15)
  }

  @Test func samplingInterpolatesAndClamps() {
    let path = physics.path(velocity: 1000)
    #expect(path.position(at: 0) == 0)
    #expect(path.position(at: 100) == path.end)
    let middle = path.position(at: path.interval * 1.5)
    #expect(middle > path.positions[1] && middle < path.positions[2])
    #expect(path.velocity(at: 100) == 0)
  }

  @Test func rubberBandRoundTrips() {
    for distance in [1.0, 40.0, 250.0, 900.0] {
      let shown = physics.rubberBanded(distance, dimension: 600)
      #expect(shown < distance)
      #expect(abs(physics.rubberBandInverse(shown, dimension: 600) - distance) < 0.01)
    }
    #expect(physics.rubberBanded(0, dimension: 600) == 0)
  }

  @Test func releaseVelocityFromASteadyDrag() {
    let samples = (0 ... 20).map { ReleaseVelocity.Sample(time: Double($0) / 120, position: Double($0) * 10) }
    let velocity = ReleaseVelocity.estimate(samples, releaseTime: 20.0 / 120)
    #expect(abs(velocity - 1200) < 1)
  }

  @Test func releaseVelocityIgnoresTheRepeatedLiftSample() {
    var samples = (0 ... 20).map { ReleaseVelocity.Sample(time: Double($0) / 120, position: Double($0) * 10) }
    samples.append(ReleaseVelocity.Sample(time: 20.5 / 120, position: 200))
    #expect(abs(ReleaseVelocity.estimate(samples, releaseTime: 20.5 / 120) - 1200) < 1)
  }

  @Test func aFingerThatRestedDoesNotFling() {
    var samples = (0 ... 20).map { ReleaseVelocity.Sample(time: Double($0) / 120, position: Double($0) * 10) }
    samples.append(ReleaseVelocity.Sample(time: 0.5, position: 200))
    #expect(ReleaseVelocity.estimate(samples, releaseTime: 0.5) == 0)
    #expect(ReleaseVelocity.estimate([], releaseTime: 1) == 0)
  }
}
