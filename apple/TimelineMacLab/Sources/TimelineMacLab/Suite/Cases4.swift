import AppKit
import TimelineAppKit
import TimelineCore

// Cases from the inventories that the first pass did not cover (iOS timeline fixes, Telegram CoreList lessons).

extension SuiteCases {
  static var inventory: [BehaviourCase] {
    [
      BehaviourCase(
        id: "fling.touch-in-bounce", area: "Flings",
        behaviour: "A touch while a fling bounces past the newest end stops it there; letting go, it springs back and settles exactly on the end (iOS: a tap in the bounce springs back)"
      ) { b, c in
        await b.goAboveLatest(300)
        let newest = b.newest
        await b.gesture(dy: -40, count: 10)
        // Until the content shows past the end.
        var past = 0.0
        for _ in 0 ..< 120 {
          await b.frames(1)
          past = Double(b.usableBottom - (b.shown(newest)?.maxY ?? b.usableBottom))
          if past > 6 { break }
        }
        c.atLeast("past the end when touched", past, 6)
        await b.touch(lift: false)
        await b.settle()
        let held = Double(b.usableBottom - (b.shown(newest)?.maxY ?? 0))
        c.atLeast("still past the end while held", held, 3)
        b.send(Synth.trackpad(0, phase: .cancelled))
        await b.untilRest()
        c.near("rest: newest bottom − usable bottom", Double((b.shown(newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.01)
        c.that("pinned after", b.isPinned)
      },
      BehaviourCase(
        id: "input.rest-before-lift", area: "Gestures and input",
        behaviour: "Fingers that stop and rest before lifting do not fling (the release velocity is zero after 60 ms without movement)"
      ) { b, c in
        await b.goMiddle()
        await b.gesture(dy: 24, count: 10, lift: false)
        await b.wait(0.12)
        let before = b.scrolled
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        c.that("no fling", !b.list.isFlinging)
        c.atMost("moved after the lift", Double(abs(b.scrolled - before)), 0.01)
      },
      BehaviourCase(
        id: "anim.rapid-deletes", area: "Row animations",
        behaviour: "Five messages above the reader deleted 25 ms apart: the reader stays, kept bubbles never overlap"
      ) { b, c in
        await b.goMiddle()
        guard let reading = b.readingRow(), let y = b.shown(reading)?.minY else { return c.that("row", false) }
        let above = b.list.timelineLayout.placements
          .filter { $0.maxY < y - 4 && $0.maxY > b.usableTop && !(b.chat.row($0.id)?.isDay ?? true) }
          .map(\.id)
        guard above.count >= 5 else { return c.that("five rows above the reader", false) }
        let doomed = Array(above.suffix(5))
        let r = await b.record {
          for id in doomed.reversed() {
            b.delete(id)
            await b.wait(0.025)
          }
        }
        c.atMost("reader drift", r.deviation(reading, from: Double(y)), 0.5)
        c.atMost("kept bubbles overlapping", r.bubbleSeams(excluding: Set(doomed)).overlap, 0.5)
      },
    ]
  }
}
