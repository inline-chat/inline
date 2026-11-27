import AppKit
import QuartzCore
import TimelineAppKit
import TimelineCore

// The lift's own cost. Until a fling's animation reaches the render server the main thread drives the motion, so
// whatever the lift does (and the re-bake at the system's first momentum event, ~5 ms later in real gestures) delays
// the first frame of the fling. In the app the same refresh also carries the last finger frame's rows, and captures
// showed one refresh lost there. The floating date's bake once scanned every placed row three times per path sample
// (1.5 ms of a 3.6 ms start).

extension SuiteCases {
  static var lift: [BehaviourCase] {
    [
      BehaviourCase(id: "fling.lift-cost", area: "Flings", behaviour: "Lifting into a fling across days, and steering it at the first momentum event, each cost the main thread about 1 ms or less (Core Animation's commit aside)", options: Bench.Options(count: 1200)) { b, c in
        await b.goMiddle()
        var lifts: [Double] = []
        var steers: [Double] = []
        var headerShown = false
        for round in 0 ..< 5 {
          let dy: Double = round % 2 == 0 ? 24 : -24
          await b.gesture(dy: dy, count: 12, lift: false)
          headerShown = headerShown || b.list.floatingHeader != nil
          // Each event inside an explicit transaction, so its commit (layout, drawing) is left out, as in the app,
          // where an event handler's changes go out with the run loop's transaction.
          CATransaction.begin()
          var start = CACurrentMediaTime()
          b.send(Synth.trackpad(0, phase: .ended))
          lifts.append((CACurrentMediaTime() - start) * 1000)
          CATransaction.commit()
          await b.sleep(0.005)
          CATransaction.begin()
          start = CACurrentMediaTime()
          b.send(Synth.trackpad(dy * 1.5, phase: .none, momentum: .begin))
          steers.append((CACurrentMediaTime() - start) * 1000)
          CATransaction.commit()
          b.send(Synth.trackpad(0, phase: .none, momentum: .end))
          await b.untilRest()
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        c.that("the floating date was up", headerShown)
        c.atMost("lift, median of 5", median(lifts), 1, unit: "ms")
        c.atMost("lift, worst of 5", lifts.max() ?? 0, 1.5, unit: "ms")
        c.atMost("first momentum event, median of 5", median(steers), 1, unit: "ms")
        c.atMost("first momentum event, worst of 5", steers.max() ?? 0, 1.5, unit: "ms")
      },
    ]
  }
}
