import CoreGraphics
import Testing
@testable import TimelineCore

/// A keyframe track as Core Animation plays it with `calculationMode = .linear`: evenly spaced, or at `keyTimes`.
private func interpolate(_ values: [CGFloat], keyTimes: [Double]?, at fraction: Double) -> CGFloat {
  let times = keyTimes ?? values.indices.map { Double($0) / Double(values.count - 1) }
  guard let upper = times.firstIndex(where: { $0 >= fraction }) else { return values[values.count - 1] }
  guard upper > 0 else { return values[0] }
  let span = times[upper] - times[upper - 1]
  let f = span > 0 ? (fraction - times[upper - 1]) / span : 1
  return values[upper - 1] + CGFloat(f) * (values[upper] - values[upper - 1])
}

@Suite("Sticky values along a fling")
struct FollowTests {
  /// A path that moves 10 pt per sample: shifts −30, −20, −10, 0 from its end.
  let path = ScrollPath(
    interval: 0.1, positions: [0, 10, 20, 30], velocities: [100, 100, 100, 0], touchesLower: false, touchesUpper: false
  )
  let pin = TimelinePinGeometry(overhang: 15, maxLift: 100)

  @Test("A lift that starts between two samples gets a sample where it starts")
  func addsKinkSample() {
    let followed = path.follow({ -pin.lift(shift: $0) }, kinks: [-pin.overhang, pin.maxLift - pin.overhang])
    #expect(followed.values.count == 5)
    #expect(followed.keyTimes == [0, 1.0 / 3, 0.5, 2.0 / 3, 1])
    #expect(followed.values == [15, 15, 15, 10, 0])
    #expect(followed.varies)
  }

  @Test("Played linearly, the track equals the lift on every frame, corner included")
  func exactBetweenSamples() {
    let followed = path.follow({ -pin.lift(shift: $0) }, kinks: [-pin.overhang, pin.maxLift - pin.overhang])
    let end = -pin.lift
    for step in 0 ... 300 {
      let fraction = Double(step) / 300
      let shift = CGFloat(path.position(at: fraction * path.duration) - path.end)
      let exact = -pin.lift(shift: shift) - end
      #expect(abs(interpolate(followed.values, keyTimes: followed.keyTimes, at: fraction) - exact) < 1e-9)
    }
  }

  @Test("Without a crossing the samples stay evenly spaced")
  func noCrossing() {
    let followed = path.follow({ -pin.lift(shift: $0) }, kinks: [-200, 500, .infinity])
    #expect(followed.keyTimes == nil)
    #expect(followed.values == path.follow { -pin.lift(shift: $0) }.values)
  }
}

@Suite("Far jump slide")
struct CarouselTests {
  let viewport = TimelineViewport(width: 320, height: 600)

  private func layout(ids: ClosedRange<Int>, firstY: CGFloat, height: CGFloat, firstIndex: Int) -> TimelineLayout<Int> {
    var placements: [TimelinePlacement<Int>] = []
    for (offset, id) in ids.enumerated() {
      placements.append(TimelinePlacement(id: id, index: firstIndex + offset, y: firstY + CGFloat(offset) * height, height: height))
    }
    var layout = TimelineLayout<Int>.empty(viewport: viewport)
    layout.placements = placements
    return layout
  }

  @Test("Only rows on screen slide out")
  func slides() {
    #expect(!TimelineCarousel.slides(-50, height: 50, screen: 600))
    #expect(TimelineCarousel.slides(-49, height: 50, screen: 600))
    #expect(TimelineCarousel.slides(599, height: 50, screen: 600))
    #expect(!TimelineCarousel.slides(600, height: 50, screen: 600))
  }

  @Test("Jumping older, the destination's bottom joins the top of the screen's rows, margins aside")
  func older() {
    // The old window starts in the margin above the screen; its first row on screen straddles the top at −20.
    let previous = layout(ids: 100 ... 115, firstY: -170, height: 50, firstIndex: 100)
    let next = layout(ids: 10 ... 30, firstY: -150, height: 50, firstIndex: 10)
    // Positions as ids: 10…30, a gap, 100…115.
    let index = TimelineRowIndex(Array(0 ... 115))
    let travel = TimelineCarousel.travel(from: previous, to: next, index: index, towards: nil)
    // The destination ends at 900; it starts with that bottom at −20.
    #expect(travel == -920)
  }

  @Test("Jumping newer, the destination's top joins the bottom of the screen's rows, margins aside")
  func newer() {
    // The old window runs on into the margin below; the last row on screen ends at 630 (it straddles 600).
    let previous = layout(ids: 10 ... 25, firstY: -170, height: 50, firstIndex: 10)
    let next = layout(ids: 100 ... 120, firstY: -100, height: 50, firstIndex: 100)
    let index = TimelineRowIndex(Array(0 ... 120))
    let travel = TimelineCarousel.travel(from: previous, to: next, index: index, towards: nil)
    #expect(travel == 730)
  }
}

@Suite("Timing as a function of time")
struct TimingTests {
  @Test("A critically damped spring starts at 1, falls monotonically, and is 0 at its end")
  func spring() {
    let timing = TimelineTiming.standard
    #expect(timing.remaining(at: 0) == 1)
    var last = 1.0
    for step in 1 ... 40 {
      let q = timing.remaining(at: Double(step) * 0.0095)
      #expect(q <= last)
      last = q
    }
    #expect(timing.remaining(at: 0.3832) == 0)
    // (1 + ωt)·e^(−ωt) with ω = √555.027 at t = 0.05.
    let omega = 555.027.squareRoot()
    #expect(abs(timing.remaining(at: 0.05) - (1 + omega * 0.05) * exp(-omega * 0.05)) < 1e-9)
  }

  @Test("A curve follows its Bézier: ease in-out is half done at half its time")
  func curve() {
    let timing = TimelineTiming.streamingLine
    #expect(abs(timing.remaining(at: 0.075) - 0.5) < 1e-6)
    #expect(timing.remaining(at: 0.15) == 0)
  }

  @Test("Following a clamp along a spring adds a sample exactly where it bends, and is exact there")
  func followKink() {
    let timing = TimelineTiming.standard
    // A lift that starts once 60% of the motion is left: max(0, 100·(0.6 − q)).
    let followed = timing.follow(interval: 1.0 / 120, kinks: [0.6]) { max(0, 100 * (0.6 - CGFloat($0))) }
    #expect(followed.varies)
    #expect(followed.values.first == -60)
    #expect(followed.values.last == 0)
    // The sample at the bend: where q = 0.6, the value (less the end's, 60) is −60.
    let bend = zip(followed.keyTimes, followed.values).first { abs(timing.remaining(at: $0.0 * 0.3832) - 0.6) < 1e-6 }
    #expect(bend != nil)
    #expect(abs((bend?.1 ?? 0) + 60) < 1e-6)
    #expect(followed.keyTimes == followed.keyTimes.sorted())
  }

  @Test("A small move samples less often than a long one")
  func interval() {
    let timing = TimelineTiming.standard
    #expect(timing.interval(amplitude: 17) > timing.interval(amplitude: 1200))
    #expect(timing.interval(amplitude: 1200) >= 1.0 / 960)
    #expect(timing.interval(amplitude: 0.5) <= 1.0 / 120)
  }
}

@Suite("Floating header sampler")
struct HeaderSamplerTests {
  /// Rows of varied heights; every seventh opens a section (a day separator), and the rows after it belong to it.
  private func layout(topInset: CGFloat) -> TimelineLayout<Int> {
    var placements: [TimelinePlacement<Int>] = []
    var y: CGFloat = -900
    for index in 0 ..< 80 {
      let height: CGFloat = index % 7 == 0 ? 28 : CGFloat(40 + (index * 37) % 90)
      placements.append(TimelinePlacement(id: index, index: index, y: y, height: height))
      y += height
    }
    var layout = TimelineLayout<Int>.empty(viewport: TimelineViewport(width: 320, height: 600, topInset: topInset))
    layout.placements = placements
    return layout
  }

  private func section(_ id: Int) -> Int? { id < 3 ? nil : id - id % 7 }

  @Test("Gives what place gives, at every shift of a long fling")
  func matchesPlace() {
    for topInset: CGFloat in [0, 52] {
      let layout = layout(topInset: topInset)
      let sampler = TimelineHeaderFloat.Sampler(layout: layout, height: 26, gap: 8, section: section)
      var shift: CGFloat = -4000
      while shift < 4000 {
        let expected = TimelineHeaderFloat.place(in: layout, height: 26, gap: 8, shift: shift, section: section)
        #expect(sampler.place(shift: shift) == expected, "shift \(shift)")
        shift += 3.7
      }
    }
  }
}
