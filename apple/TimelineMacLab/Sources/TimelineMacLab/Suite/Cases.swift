import AppKit
import TimelineAppKit
import TimelineCore

// The cases. Each states the behaviour as a reader would see it, drives the lab chat, and checks numbers.

extension Bench {
  func goMiddle(top: CGFloat = 200) async {
    let ids = chat.ids
    list.apply(TimelineTransaction(scroll: .to(ids[ids.count / 2], .top(top))))
    await settle()
  }

  func goOldest() async {
    list.apply(TimelineTransaction(scroll: .to(chat.ids[0], .top(0))))
    await settle()
  }

  /// From the newest message, this far up.
  func goAboveLatest(_ distance: CGFloat) async {
    list.apply(TimelineTransaction(scroll: .latest))
    list.apply(TimelineTransaction(scroll: .by(distance)))
    await settle()
  }

  /// Pinned in effect: on the newest row at the live end, at rest (the next arrival keeps it there).
  var isPinned: Bool {
    let layout = list.timelineLayout
    return list.position == .latest || (layout.isAtBottom && abs(layout.restShift) < 0.5 && layout.placements.last?.id == chat.ids.last)
  }

  /// An incoming group of at least `rows` messages, as ids from first to last.
  func incomingGroup(rows: Int, near index: Int) -> [Int]? {
    let ids = chat.ids
    var i = index
    while i < ids.count {
      if let group = chat.group(ids[i]), chat.showsAvatar(group.end), let s = chat.index(group.start),
         let e = chat.index(group.end), e - s + 1 >= rows
      {
        return Array(ids[s ... e])
      }
      i += 1
    }
    return nil
  }
}

@MainActor
enum SuiteCases {
  static var all: [BehaviourCase] {
    position + fling + input + anchoring + pinning + insets + sticky + animation + performance + window + inventory + uncovered + interruptions + uncoveredMotion + accessibility + drawing + stress + layerText + lift + updates + splitGate + topPins + passage
  }

  // MARK: - Scroll positioning

  static var position: [BehaviourCase] {
    [
      BehaviourCase(id: "pos.open-latest", area: "Scroll positioning", behaviour: "Opens on the newest message: its bottom on the usable bottom, pinned") { b, c in
        c.near("newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.that("pinned", b.isPinned)
      },
      BehaviourCase(
        id: "pos.open-short", area: "Scroll positioning",
        behaviour: "A chat shorter than the window sits at the bottom, against the composer (bottom-first)",
        options: Bench.Options(count: 3)
      ) { b, c in
        c.near("newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.atLeast("oldest top − usable top", Double((b.shown(b.chat.ids[0])?.minY ?? 0) - b.usableTop), 1)
        // A pull and a fling either way come back to the same place.
        await b.gesture(dy: 12, count: 20)
        await b.untilRest()
        c.near("after a pull down: newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        await b.gesture(dy: -12, count: 20)
        await b.untilRest()
        c.near("after a pull up: newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      },
      BehaviourCase(id: "pos.align", area: "Scroll positioning", behaviour: "Scrolling to a message puts it exactly at the top, centre or bottom asked for") { b, c in
        let id = b.chat.ids[200]
        b.list.apply(TimelineTransaction(scroll: .to(id, .top(8))))
        await b.settle()
        c.near("top(8): row top − usable top", Double((b.shown(id)?.minY ?? 0) - b.usableTop), 8, within: 0.01)
        b.list.apply(TimelineTransaction(scroll: .to(id, .center)))
        await b.settle()
        let mid = ((b.shown(id)?.midY ?? 0) - (b.usableTop + b.usableBottom) / 2)
        c.near("center: row middle − usable middle", Double(mid), 0, within: 0.51)
        b.list.apply(TimelineTransaction(scroll: .to(id, .bottom(12))))
        await b.settle()
        c.near("bottom(12): usable bottom − row bottom", Double(b.usableBottom - (b.shown(id)?.maxY ?? 0)), 12, within: 0.01)
      },
      BehaviourCase(id: "pos.align-tall", area: "Scroll positioning", behaviour: "Centring a message taller than the window shows its top") { b, c in
        let id = b.chat.ids[300]
        b.chat.setText(id, String(repeating: "a very tall message that wraps over many lines ", count: 120))
        b.list.apply(TimelineTransaction(changed: [id]))
        b.list.apply(TimelineTransaction(scroll: .to(id, .center)))
        await b.settle()
        c.near("row top − usable top", Double((b.shown(id)?.minY ?? 0) - b.usableTop), 0, within: 0.01)
      },
      BehaviourCase(
        id: "pos.saved-place", area: "Scroll positioning",
        behaviour: "A reading place saved as (message, distance from the bottom) reopens exactly, also in a taller window"
      ) { b, c in
        await b.goMiddle(top: 137)
        guard let id = b.readingRow(), let frame = b.shown(id) else { return c.that("reading row", false) }
        let fromBottom = b.usableBottom - frame.maxY
        let other = Bench(Bench.Options(size: NSSize(width: 520, height: 900)))
        await other.frames(2)
        other.list.apply(TimelineTransaction(scroll: .to(id, .bottom(fromBottom))))
        await other.settle()
        c.near("distance from the usable bottom, reopened taller", Double(other.usableBottom - (other.shown(id)?.maxY ?? 0)), Double(fromBottom), within: 0.01)
        other.close()
      },
      BehaviourCase(id: "pos.oldest-end", area: "Scroll positioning", behaviour: "At the oldest message the first row sits at the top and wheel notches up do nothing") { b, c in
        await b.goOldest()
        let first = b.chat.ids[0]
        c.near("first top − usable top", Double((b.shown(first)?.minY ?? 0) - b.usableTop), 0, within: 0.01)
        for _ in 0 ..< 5 { b.wheel(lines: 3) }
        await b.untilRest()
        c.near("after 5 notches up", Double((b.shown(first)?.minY ?? 0) - b.usableTop), 0, within: 0.01)
      },
      BehaviourCase(id: "pos.pixel-aligned", area: "Scroll positioning", behaviour: "After a fling every row rests on whole pixels") { b, c in
        await b.goMiddle()
        await b.gesture(dy: 13.3, count: 12)
        await b.untilRest()
        let scale = b.window.backingScaleFactor
        let worst = b.list.placedViews.compactMap { b.shown($0.0) }.map { abs(($0.minY * scale).rounded() - $0.minY * scale) / scale }.max() ?? 1
        c.atMost("largest distance from a pixel", Double(worst), 0.01)
      },
    ]
  }

  // MARK: - Flings

  static let nativeTravel: [(name: String, dy: Double, count: Int, travel: Double)] = [
    ("500", 4, 20, 149), ("1000", 8, 20, 330), ("2000", 16, 20, 799), ("4000", 32, 12, 1550), ("8000", 64, 8, 4020),
  ]

  static var fling: [BehaviourCase] {
    // Fling travel against real gestures (Mo's trackpad) and NSScrollView's measured travel for each (the NSScrollView
    // lane: NSScrollView ignores the momentum deltas and runs AppKit's calculator from its own reading of the fingers'
    // speed, which sits 0.78–1.24× from any finger average; hence ±30% per gesture, median 1.06 over the four).
    var cases: [BehaviourCase] = RealGesture.all.map { gesture in
      BehaviourCase(
        id: "fling.real-\(gesture.name.split(separator: " ").first.map(String.init) ?? "")", area: "Flings",
        behaviour: "A real flick (\(gesture.name)) travels as far as NSScrollView does for it (\(Int(gesture.nsScrollViewTravel)) pt with the fingers'), within 30%",
        options: Bench.Options(count: 3000)
      ) { b, c in
        await b.goMiddle()
        let start = b.scrolled
        var steps: [(at: Double, event: CGEvent)] = [(0, Synth.trackpad(0, phase: .mayBegin))]
        let first = gesture.tracked.first?[0] ?? 0
        for (i, sample) in gesture.tracked.enumerated() {
          steps.append((0.01 + first - sample[0], Synth.trackpad(sample[1], phase: i == 0 ? .began : .changed)))
        }
        let lift = 0.01 + first
        steps.append((lift, Synth.trackpad(0, phase: .ended)))
        for (i, sample) in gesture.momentum.enumerated() {
          steps.append((lift + gesture.momentumDelay + sample[0], Synth.trackpad(sample[1], phase: .none, momentum: i == 0 ? .begin : .continue)))
        }
        await b.play(steps)
        await b.untilRest()
        let expected = gesture.nsScrollViewTravel
        let system = gesture.trackedTravel + gesture.momentumTravel
        let travel = Double(b.scrolled - start)
        c.near("travel", travel, expected, within: abs(expected) * 0.3)
        c.note(String(
          format: "travel %.0f pt, NSScrollView's %.0f pt (%.0f%%); the system's momentum %.0f pt",
          travel, expected, travel / expected * 100, system
        ))
      }
    }
    cases += [
      BehaviourCase(
        id: "fling.momentum-events", area: "Flings",
        behaviour: "After a lift the first momentum event sets the fling's speed and the system's shape carries it (a synthetic stream: within 20%; the real-gesture cases hold the exact reference), smoothly; without momentum events the release estimate flings",
        options: Bench.Options(count: 1200)
      ) { b, c in
        await b.goMiddle()
        guard let id = b.middleRow() else { return c.that("row", false) }
        var start = b.scrolled
        let r = await b.record {
          await b.gesture(dy: 16, count: 20, momentum: true)
          await b.untilRest()
        }
        let withMomentum = Double(b.scrolled - start)
        // The stream `gesture(momentum: true)` plays: 1.5 × dy, then 30 events each 5% smaller, at 60 Hz.
        var d = 16.0 * 1.5
        var stream = d
        for _ in 0 ..< 30 {
          d *= 0.95
          stream += d
        }
        // Within 30%: this stream decays from its first event; real slow flicks hold their speed ~0.12 s first, as the
        // fling does (the real-gesture cases `fling.real-*` hold the exact reference).
        c.near("travel after the lift − the momentum stream's", withMomentum - 16 * 20 - stream, 0, within: stream * 0.3)
        let coasting = Recording(frames: r.frames.filter(\.flinging))
        c.atMost("largest speed jump (share) while coasting", coasting.speedJump(id), 0.25, unit: "")
        await b.goMiddle()
        start = b.scrolled
        await b.gesture(dy: 16, count: 20, momentum: false)
        await b.untilRest()
        c.atLeast("without momentum events: travel beyond the fingers'", Double(b.scrolled - start) - 16 * 20, 100)
      },
      BehaviourCase(id: "fling.smooth", area: "Flings", behaviour: "A fling decelerates smoothly: no frame-to-frame speed jump", options: Bench.Options(count: 1200)) { b, c in
        await b.goMiddle()
        guard let id = b.middleRow() else { return c.that("row", false) }
        let r = await b.record { await b.gesture(dy: 24, count: 12) }
        let flying = Recording(frames: r.frames.filter(\.flinging))
        c.atMost("largest speed jump (share)", flying.speedJump(id), 0.25, unit: "")
        c.atMost("blank strip", r.blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
      },
      BehaviourCase(
        id: "fling.stalls", area: "Flings",
        behaviour: "Three 80 ms main-thread stalls mid-fling do not stop or bend the motion (it runs on the render server)",
        options: Bench.Options(count: 3000, rowCost: 1)
      ) { b, c in
        await b.goMiddle()
        var start = b.scrolled
        await b.gesture(dy: 32, count: 12)
        await b.untilRest()
        let baseline = Double(b.scrolled - start)
        await b.goMiddle()
        start = b.scrolled
        guard let id2 = b.middleRow() else { return c.that("row", false) }
        let r = await b.record {
          await b.gesture(dy: 32, count: 12)
          for _ in 0 ..< 3 {
            await b.wait(0.12)
            b.stall(0.08)
          }
        }
        let travel = Double(b.scrolled - start)
        c.near("travel with stalls − without", travel - baseline, 0, within: max(4, baseline * 0.02))
        c.atMost("largest speed jump (share)", Recording(frames: r.frames.filter(\.flinging)).speedJump(id2), 0.3, unit: "")
        c.atMost("blank strip", r.blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
      },
      BehaviourCase(id: "fling.catch", area: "Flings", behaviour: "A touch mid-fling stops the content where it shows when the stop reaches the screen (at most a refresh on, never back), and it stays there") { b, c in
        await b.goMiddle()
        await b.gesture(dy: 32, count: 12)
        await b.wait(0.2)
        let point = NSPoint(x: 100, y: (b.usableTop + b.usableBottom) / 2)
        guard let id = b.list.row(atPresented: point) else { return c.that("row", false) }
        let speed = await b.record { await b.wait(0.05) }.speeds(id).last.map { abs($0.v) } ?? 0
        let before = b.shown(id)?.minY ?? 0
        await b.touch(lift: false)
        await b.settle()
        let after = b.shown(id)?.minY ?? 0
        // The render server plays the fling until the stop lands: the stop is where the content is at the next refresh
        // (the fling moves rows down here), so it never steps back on screen (TimelineScrollLab `--compare catch`).
        c.atLeast("on at the touch (no step back)", Double(after - before), -1.0)
        c.atMost("on at the touch", Double(after - before), speed / 60 + 2)
        let r = await b.record { await b.wait(0.3) }
        c.atMost("drift while held", r.deviation(id, from: Double(after)), 0.01)
        b.send(Synth.trackpad(0, phase: .cancelled))
        await b.untilRest()
        c.atMost("drift after lifting", Double(abs((b.shown(id)?.minY ?? 0) - after)), 0.5)
      },
      BehaviourCase(id: "fling.catch-drag", area: "Flings", behaviour: "Catching a fling and dragging on moves 1:1 from where it stopped, no step") { b, c in
        await b.goMiddle()
        await b.gesture(dy: 32, count: 12)
        await b.wait(0.2)
        await b.touch(lift: false)
        await b.settle()
        let caught = b.scrolled
        let r = await b.record(settle: false) { await b.gesture(dy: 5, count: 10, lift: false, touch: false) }
        await b.settle()
        c.near("moved by the drag", Double(b.scrolled - caught), 50, within: 0.5)
        let origins = r.frames.map { -Double($0.origin) }
        let steps = zip(origins, origins.dropFirst()).map { $1 - $0 }
        c.atMost("largest step (two 5 pt moves can share a frame)", steps.map(abs).max() ?? 0, 10.5)
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
      },
      BehaviourCase(id: "fling.reverse", area: "Flings", behaviour: "A flick the other way mid-fling turns the content at once") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow() else { return c.that("row", false) }
        await b.gesture(dy: 32, count: 12)
        await b.wait(0.15)
        let r = await b.record { await b.gesture(dy: -24, count: 10) }
        let v = r.speeds(id)
        c.that("ends moving the other way", (v.last(where: { abs($0.v) > 50 })?.v ?? 1) < 0)
      },
      BehaviourCase(id: "fling.bounce-newest", area: "Flings", behaviour: "A fling into the newest end bounces once (under 120 pt) and settles exactly on it") { b, c in
        await b.goAboveLatest(500)
        let newest = b.newest
        let r = await b.record { await b.gesture(dy: -32, count: 10) }
        let over = r.overshootAbove(newest, edge: { $0.usableBottom })
        c.atLeast("overshoot", over, 1)
        c.atMost("overshoot", over, 120)
        c.near("rest: newest bottom − usable bottom", Double((b.shown(newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.01)
        c.atMost("speed reversals", Double(r.reversals(newest)), 1, unit: "")
        c.that("pinned after", b.isPinned)
      },
      BehaviourCase(id: "fling.bounce-oldest", area: "Flings", behaviour: "A fling into the oldest end bounces once and settles exactly on it") { b, c in
        await b.goOldest()
        b.list.apply(TimelineTransaction(scroll: .by(-500)))
        let first = b.chat.ids[0]
        let r = await b.record { await b.gesture(dy: 32, count: 10) }
        let over = r.overshootBelow(first, edge: { $0.usableTop })
        c.atLeast("overshoot", over, 1)
        c.atMost("overshoot", over, 120)
        c.near("rest: first top − usable top", Double((b.shown(first)?.minY ?? 0) - b.usableTop), 0, within: 0.01)
        c.atMost("speed reversals", Double(r.reversals(first)), 1, unit: "")
      },
      BehaviourCase(
        id: "fling.through-paging", area: "Flings",
        behaviour: "Flinging towards history that is still loading keeps going when the page lands: no stop at the old edge",
        options: Bench.Options(count: 200, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: true))
      ) { b, c in
        var pages = 0
        b.list.onDemand = { edges in
          guard edges.contains(.older), pages < 6 else { return }
          pages += 1
          DispatchQueue.main.async { b.prependPage(60, coverage: TimelineCoverage(reachesOldest: pages >= 6, reachesNewest: true)) }
        }
        await b.goOldest()
        b.list.apply(TimelineTransaction(scroll: .by(-1500)))
        let oldFirst = b.chat.ids[0]
        guard let id = b.middleRow() else { return c.that("row", false) }
        let r = await b.record { await b.gesture(dy: 48, count: 10) }
        c.atLeast("pages loaded", Double(pages), 1, unit: "")
        c.atMost("speed reversals", Double(r.reversals(id)), 0, unit: "")
        c.that("went past the old first row", (b.shown(oldFirst)?.minY ?? 0) > b.usableTop + 5 || b.shown(oldFirst) == nil)
        c.atMost("blank strip", r.blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
      },
    ]
    return cases
  }

  // MARK: - Gestures and input

  static var input: [BehaviourCase] {
    [
      BehaviourCase(id: "input.drag-1to1", area: "Gestures and input", behaviour: "The content follows the fingers 1:1, and a lift after resting does not fling") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let start = b.shown(id)?.minY else { return c.that("row", false) }
        await b.gesture(dy: 5, count: 40, lift: false)
        c.near("moved", Double((b.shown(id)?.minY ?? 0) - start), 200, within: 0.5)
        await b.wait(0.12)
        let held = b.shown(id)?.minY ?? 0
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        c.atMost("moved after a still lift", Double(abs((b.shown(id)?.minY ?? 0) - held)), 0.5)
      },
      BehaviourCase(id: "input.rubber-band-newest", area: "Gestures and input", behaviour: "Pulling past the newest end shows 0.067 of the pull (NSScrollView) and springs back on release") { b, c in
        let newest = b.newest
        await b.gesture(dy: -10, count: 60, lift: false)
        let shown = Double(b.usableBottom - (b.shown(newest)?.maxY ?? 0))
        c.near("shown past the end for a 600 pt pull", shown, 40, within: 4)
        let began = CACurrentMediaTime()
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        c.atMost("return time", CACurrentMediaTime() - began, 0.8, unit: "s")
        c.near("rest: newest bottom − usable bottom", Double((b.shown(newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      },
      BehaviourCase(id: "input.rubber-band-oldest", area: "Gestures and input", behaviour: "Pulling past the oldest end rubber-bands the same way and springs back") { b, c in
        await b.goOldest()
        let first = b.chat.ids[0]
        await b.gesture(dy: 10, count: 60, lift: false)
        c.near("shown past the end", Double((b.shown(first)?.minY ?? 0) - b.usableTop), 40, within: 4)
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        c.near("rest: first top − usable top", Double((b.shown(first)?.minY ?? 0) - b.usableTop), 0, within: 0.5)
      },
      BehaviourCase(id: "input.rubber-band-reverse", area: "Gestures and input", behaviour: "Pulling past an end and back without lifting returns 1:1 once inside, no leap") { b, c in
        let newest = b.newest
        await b.gesture(dy: -10, count: 30, lift: false)
        await b.gesture(dy: 10, count: 60, lift: false, touch: false)
        await b.settle()
        // 300 pulled past the end, 600 back: 300 of real travel into history.
        c.near("newest bottom below the usable bottom", Double((b.shown(newest)?.maxY ?? 0) - b.usableBottom), 300, within: 0.5)
        await b.wait(0.12)
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
      },
      BehaviourCase(id: "input.wheel", area: "Gestures and input", behaviour: "A mouse wheel notch moves 10 pt per line at once, no animation, no fling") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let start = b.shown(id)?.minY else { return c.that("row", false) }
        b.wheel(lines: 1)
        await b.settle()
        c.near("one notch", Double((b.shown(id)?.minY ?? 0) - start), 10, within: 0.01)
        b.wheel(lines: -3)
        await b.settle()
        c.near("three notches back", Double((b.shown(id)?.minY ?? 0) - start), -20, within: 0.01)
        for _ in 0 ..< 10 { b.wheel(lines: 2) }
        await b.settle()
        let after = b.shown(id)?.minY ?? 0
        await b.wait(0.4)
        c.atMost("moved after the last notch", Double(abs((b.shown(id)?.minY ?? 0) - after)), 0.5)
      },
      BehaviourCase(id: "input.wheel-at-end", area: "Gestures and input", behaviour: "Wheel notches past the newest end do nothing (no overscroll)") { b, c in
        for _ in 0 ..< 5 { b.wheel(lines: -3) }
        await b.untilRest()
        c.near("newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.01)
        c.that("still pinned", b.isPinned)
      },
      BehaviourCase(id: "input.horizontal", area: "Gestures and input", behaviour: "A sideways swipe does not scroll; it goes to the row it started on (swipe to reply)") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let start = b.shown(id)?.minY else { return c.that("row", false) }
        var events = 0
        var startedOn: Int?
        b.list.onHorizontalScroll = { event, row in
          events += 1
          if event.phase.contains(.began) { startedOn = row }
          return true
        }
        await b.gesture(dy: 1, count: 20, dx: -10)
        await b.untilRest()
        c.atMost("vertical travel", Double(abs((b.shown(id)?.minY ?? 0) - start)), 0.01)
        c.atLeast("events taken", Double(events), 20, unit: "")
        c.that("started on a row", startedOn != nil)
      },
      BehaviourCase(id: "input.diagonal", area: "Gestures and input", behaviour: "A mostly vertical gesture with sideways wobble scrolls vertically only, 1:1") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let start = b.shown(id)?.minY else { return c.that("row", false) }
        await b.gesture(dy: 6, count: 20, dx: 2, lift: false)
        c.near("vertical travel", Double((b.shown(id)?.minY ?? 0) - start), 120, within: 0.5)
        await b.wait(0.12)
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
      },
      BehaviourCase(id: "input.keys", area: "Gestures and input", behaviour: "Page Up/Down move a page less a line, animated; Home/End go to the ends") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let start = b.shown(id)?.minY else { return c.that("row", false) }
        let page = b.usableBottom - b.usableTop - 40
        b.list.pageUp(nil)
        await b.untilRest()
        c.near("page up", Double((b.shown(id)?.minY ?? 0) - start), Double(page), within: 0.5)
        b.list.pageDown(nil)
        await b.untilRest()
        c.near("page down back", Double((b.shown(id)?.minY ?? 0) - start), 0, within: 0.5)
        b.list.scrollToEndOfDocument(nil)
        await b.untilRest()
        c.that("end: pinned", b.isPinned)
        c.near("end: newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        b.list.scrollToBeginningOfDocument(nil)
        await b.untilRest()
        c.near("home: first top − usable top", Double((b.shown(b.chat.ids[0])?.minY ?? 0) - b.usableTop), 0, within: 0.5)
      },
      BehaviourCase(id: "input.click-stops-fling", area: "Gestures and input", behaviour: "A mouse click mid-fling stops it where it shows; the click lands on what is under it") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow() else { return c.that("row", false) }
        await b.gesture(dy: 32, count: 12)
        await b.wait(0.15)
        let point = NSPoint(x: b.list.bounds.midX, y: (b.usableTop + b.usableBottom) / 2)
        let before = b.shown(id)?.minY ?? 0
        let windowPoint = b.list.convert(point, to: nil)
        let down = NSEvent.mouseEvent(
          with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: b.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!
        NSApp.postEvent(down, atStart: false)
        await b.settle()
        let after = b.shown(id)?.minY ?? 0
        c.that("stopped", !b.list.isFlinging)
        c.atMost("jump at the click", Double(abs(after - before)), 1)
        let up = NSEvent.mouseEvent(
          with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: b.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        )!
        NSApp.postEvent(up, atStart: false)
        await b.settle()
        let hit = b.list.hitTest(b.list.convert(point, to: b.list.superview))
        let under = b.list.row(atPresented: point)
        c.that("hit row is the row shown under the point", hit.map { v in b.list.view(for: under ?? -1).map { v.isDescendant(of: $0) } ?? false } ?? false)
      },
      BehaviourCase(id: "input.hover-during-fling", area: "Gestures and input", behaviour: "During a fling the pointer finds the row shown under it, not the one the fling will bring there") { b, c in
        await b.goMiddle()
        await b.gesture(dy: 32, count: 12)
        var checked = 0
        var wrong = 0
        for _ in 0 ..< 30 {
          await b.frames(1)
          guard b.list.isFlinging else { break }
          let point = NSPoint(x: b.list.bounds.midX, y: (b.usableTop + b.usableBottom) / 2)
          // Clear of a row's edges by a few points, for the frame time the presentation is read at.
          guard let under = b.list.row(atPresented: point), let view = b.list.view(for: under),
                let frame = b.shown(under), point.y - frame.minY > 6, frame.maxY - point.y > 6 else { continue }
          let hit = b.list.hitTest(b.list.convert(point, to: b.list.superview))
          checked += 1
          if !(hit.map { $0.isDescendant(of: view) } ?? false) { wrong += 1 }
        }
        c.atLeast("frames checked", Double(checked), 8, unit: "")
        c.atMost("frames hitting another row", Double(wrong), 0, unit: "")
        await b.untilRest()
      },
      BehaviourCase(id: "input.autoscroll", area: "Gestures and input", behaviour: "Dragging a selection past the bottom or top edge scrolls the list that way, faster further out") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let start = b.shown(id)?.minY else { return c.that("row", false) }
        @MainActor func drag(_ y: CGFloat) -> NSEvent {
          NSEvent.mouseEvent(
            with: .leftMouseDragged, location: b.list.convert(NSPoint(x: 100, y: y), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: b.window.windowNumber, context: nil,
            eventNumber: 3, clickCount: 1, pressure: 1
          )!
        }
        for _ in 0 ..< 5 { _ = b.list.autoscroll(with: drag(b.usableBottom + 20)) }
        await b.settle()
        let near = Double((b.shown(id)?.minY ?? 0) - start)
        for _ in 0 ..< 5 { _ = b.list.autoscroll(with: drag(b.usableBottom + 60)) }
        await b.settle()
        let far = Double((b.shown(id)?.minY ?? 0) - start) - near
        c.near("5 drags 20 pt below", near, -100, within: 0.5)
        c.near("5 drags 60 pt below", far, -300, within: 0.5)
        for _ in 0 ..< 5 { _ = b.list.autoscroll(with: drag(b.usableTop - 30)) }
        await b.settle()
        c.near("5 drags 30 pt above", Double((b.shown(id)?.minY ?? 0) - start) - near - far, 150, within: 0.5)
        await b.untilRest()
      },
    ]
  }
}
