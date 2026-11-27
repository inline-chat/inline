import AppKit
import TimelineAppKit
import TimelineCore

extension SuiteCases {
  // MARK: - Sticky avatars and the floating date

  /// The visible bottom edge for avatars: the composer's top less the 12 pt gap, as presented (it moves with the
  /// composer's animation).
  static func avatarEdge(_ b: Bench) -> (Frame) -> CGFloat {
    { frame in frame.composerTop - 12 }
  }

  static var sticky: [BehaviourCase] {
    [
      BehaviourCase(id: "sticky.avatar-rest", area: "Sticky items", behaviour: "An incoming group wholly in sight shows its avatar beside its last message", options: Bench.Options(count: 600, groupRun: 3)) { b, c in
        await b.goMiddle()
        await b.untilRest()
        let r = await b.record { await b.frames(2) }
        guard let frame = r.frames.last else { return c.that("frames", false) }
        var checked = 0
        var worst = 0.0
        for (id, avatar) in frame.avatars {
          guard let row = frame.rows[id], row.maxY < frame.usableBottom - 1 else { continue }
          checked += 1
          worst = max(worst, Double(abs(avatar.maxY - (row.maxY - LabChat.bottomGap(last: true)))))
        }
        c.atLeast("avatars checked", Double(checked), 2, unit: "")
        c.atMost("distance from the resting place", worst, 0.5)
      },
      BehaviourCase(
        id: "sticky.avatar-drag", area: "Sticky items",
        behaviour: "Dragging slowly through long groups, every avatar stays on the bottom edge while its group is in sight, never above the group's top",
        options: Bench.Options(count: 600, groupRun: 8)
      ) { b, c in
        await b.goMiddle()
        let r = await b.record(settle: false) {
          await b.gesture(dy: 3, count: 160, lift: false)
        }
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        let e = StickyRules.avatarError(r, chat: b.chat, edge: avatarEdge(b))
        c.atLeast("avatar frames checked", Double(e.checked), 100, unit: "")
        c.atMost("avatar error, worst frame", e.error, 0.5)
      },
      BehaviourCase(
        id: "sticky.avatar-fling", area: "Sticky items",
        behaviour: "During a fling, avatars ride the same render-server path as the rows: on the edge every frame",
        options: Bench.Options(count: 1200, groupRun: 8)
      ) { b, c in
        await b.goMiddle()
        let r = await b.record { await b.gesture(dy: 20, count: 12) }
        let e = StickyRules.avatarError(Recording(frames: r.frames.filter(\.flinging)), chat: b.chat, edge: avatarEdge(b))
        c.atLeast("avatar frames checked", Double(e.checked), 20, unit: "")
        c.atMost("avatar error, worst frame", e.error, 0.5)
      },
      BehaviourCase(
        id: "sticky.avatar-stalls", area: "Sticky items",
        behaviour: "Main-thread stalls mid-fling do not leave avatars behind",
        options: Bench.Options(count: 1200, rowCost: 1, groupRun: 8)
      ) { b, c in
        await b.goMiddle()
        let r = await b.record {
          await b.gesture(dy: 20, count: 12)
          for _ in 0 ..< 3 {
            await b.wait(0.1)
            b.stall(0.08)
          }
        }
        let e = StickyRules.avatarError(Recording(frames: r.frames.filter(\.flinging)), chat: b.chat, edge: avatarEdge(b))
        c.atMost("avatar error, worst frame", e.error, 0.5)
      },
      BehaviourCase(
        id: "sticky.avatar-handoff", area: "Sticky items",
        behaviour: "Pinned, the same sender's next message takes the avatar over: it stays in sight and moves, never vanishes and fades in",
        options: Bench.Options(count: 200)
      ) { b, c in
        _ = b.arrive("first from Sam", sender: 1)
        await b.untilRest()
        let groupStart = b.chat.group(b.newest)?.start
        let r = await b.record { _ = b.arrive("second from Sam", sender: 1) }
        let newest = b.newest
        var missing = 0
        var jump = 0.0
        var last: CGFloat?
        for frame in r.frames {
          // The group's avatar: on whichever of its rows has it.
          let shown = frame.avatars.filter { b.chat.group($0.key)?.start == groupStart }
          guard let avatar = shown.values.max(by: { $0.maxY < $1.maxY }) else { missing += 1; continue }
          if let last { jump = max(jump, Double(abs(avatar.maxY - last))) }
          last = avatar.maxY
        }
        c.atMost("frames without the group's avatar", Double(missing), 0, unit: "")
        c.atMost("largest avatar step between frames", jump, 12)
        if let row = b.shown(newest), let avatar = r.frames.last?.avatars[newest] {
          c.near("rest: on the new last message", Double(avatar.maxY - (row.maxY - LabChat.bottomGap(last: true))), 0, within: 0.5)
        } else {
          c.that("avatar on the new last message", false)
        }
      },
      BehaviourCase(
        id: "sticky.avatar-composer", area: "Sticky items",
        behaviour: "Scrolled up with a group across the bottom edge, the composer growing carries the avatar with the edge",
        options: Bench.Options(count: 600, groupRun: 10)
      ) { b, c in
        // An incoming group of several messages whose last row hangs below the composer.
        guard let group = b.incomingGroup(rows: 4, near: b.chat.ids.count / 2), let last = group.last,
              let height = b.settled(last)?.height ?? Optional(60)
        else { return c.that("group", false) }
        b.list.apply(TimelineTransaction(scroll: .to(last, .bottom(-height * 0.6))))
        await b.settle()
        let r = await b.record {
          b.view.setComposerLines(5)
          await b.wait(0.5)
          b.view.setComposerLines(1)
        }
        let e = StickyRules.avatarError(r, chat: b.chat, edge: avatarEdge(b))
        c.atLeast("avatar frames checked", Double(e.checked), 10, unit: "")
        c.atMost("avatar error, worst frame", e.error, 0.5)
      },
      BehaviourCase(
        id: "sticky.avatar-new-row", area: "Sticky items",
        behaviour: "A row that has just appeared (a jump) shows its group's avatar lifted on its first frame (AppKit rebuilds a new row's layers: a layer transform set then is lost)",
        options: Bench.Options(count: 600, groupRun: 10)
      ) { b, c in
        guard let group = b.incomingGroup(rows: 4, near: b.chat.ids.count / 2), let last = group.last else {
          return c.that("group", false)
        }
        let r = await b.record(settle: false) {
          b.list.apply(TimelineTransaction(scroll: .to(last, .bottom(-24))))
          await b.frames(3)
        }
        let e = StickyRules.avatarError(Recording(frames: Array(r.frames.dropFirst())), chat: b.chat, edge: avatarEdge(b))
        c.atLeast("avatar frames checked", Double(e.checked), 3, unit: "")
        c.atMost("avatar error, worst frame", e.error, 0.5)
      },
      BehaviourCase(id: "sticky.header-drag", area: "Sticky items", behaviour: "Dragging across days, the floating date shows the top message's day, is pushed up by the next day, hides where the day's own row shows") { b, c in
        await b.goMiddle()
        let r = await b.record(settle: false) { await b.gesture(dy: -4, count: 220, lift: false) }
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        let e = StickyRules.headerError(r, chat: b.chat)
        c.atMost("header position error, worst frame", e.position, 0.5)
        c.atMost("frames shown or hidden wrongly", Double(e.wrongVisibility), 0, unit: "")
        c.atMost("frames with the wrong day", Double(e.wrongTitle), 0, unit: "")
      },
      BehaviourCase(id: "sticky.header-fling", area: "Sticky items", behaviour: "During a fling across days the floating date keeps the same rules on every frame", options: Bench.Options(count: 1200)) { b, c in
        await b.goMiddle()
        let r = await b.record { await b.gesture(dy: 24, count: 12) }
        let e = StickyRules.headerError(Recording(frames: r.frames.filter(\.flinging)), chat: b.chat)
        c.atMost("header position error, worst frame", e.position, 0.75)
        c.atMost("frames shown or hidden wrongly", Double(e.wrongVisibility), 2, unit: "")
        c.atMost("frames with the wrong day", Double(e.wrongTitle), 2, unit: "")
      },
      BehaviourCase(id: "sticky.header-idle", area: "Sticky items", behaviour: "The floating date shows while scrolling and fades out once the list rests (2 s, as Telegram)") { b, c in
        await b.goMiddle()
        await b.gesture(dy: 6, count: 20, lift: false)
        await b.frames(2)
        let shown = b.list.floatingHeader?.view.superview?.alphaValue ?? 0
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        await b.wait(2.6)
        let after = b.list.floatingHeader?.view.superview?.alphaValue ?? 1
        c.atLeast("visible while scrolling", Double(shown), 0.99, unit: "")
        c.atMost("visible 2.6 s after resting", Double(after), 0.01, unit: "")
      },
    ]
  }

  // MARK: - Row animations and jumps

  static var animation: [BehaviourCase] {
    [
      BehaviourCase(id: "anim.arrival-rise", area: "Row animations", behaviour: "A new message rises from below and fades in (Telegram: 1.6× its height, 0.2 s)") { b, c in
        var id = 0
        let previous = b.newest
        let r = await b.record { id = b.arrive("a new message that arrives", sender: 2) }
        let h = Double(b.list.frame(for: id)?.height ?? 0)
        // Relative to the message above it, which moves up with the block.
        let gaps = r.frames.compactMap { f -> Double? in
          guard let new = f.rows[id], let old = f.rows[previous] else { return nil }
          return Double(new.minY - old.maxY)
        }
        c.near("starts below its neighbour by", gaps.first ?? 0, 1.6 * h, within: max(4, h * 0.3))
        c.near("ends against its neighbour", gaps.last ?? 1, 0, within: 0.01)
        c.that("fades in", r.frames.count > 3)
      },
      BehaviourCase(id: "anim.height-seams", area: "Row animations", behaviour: "A message growing and shrinking moves its neighbours with it: no gap, no overlap, any frame") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let text = b.chat.row(id)?.text else { return c.that("row", false) }
        let r = await b.record {
          b.setText(id, text + String(repeating: " more", count: 40))
          await b.wait(0.12)
          b.setText(id, "tiny")
          await b.wait(0.1)
          b.setText(id, text)
        }
        let seams = r.bubbleSeams()
        c.atMost("bubbles overlapping", seams.overlap, 0.5)
        c.atMost("space between bubbles opening up", seams.gapExcess, 0.5)
      },
      BehaviourCase(id: "anim.delete-seams", area: "Row animations", behaviour: "Deleting messages closes the gap without rows crossing") { b, c in
        await b.goMiddle()
        let ids = b.list.timelineLayout.visible.map(\.id).filter { !(b.chat.row($0)?.isDay ?? true) }
        guard ids.count > 6 else { return c.that("rows", false) }
        let doomed = [ids[2], ids[4]]
        let r = await b.record {
          b.delete(doomed[0])
          await b.wait(0.05)
          b.delete(doomed[1])
        }
        let seams = r.bubbleSeams(excluding: Set(doomed))
        c.atMost("kept bubbles overlapping", seams.overlap, 0.5)
      },
      BehaviourCase(id: "anim.jump-near", area: "Row animations", behaviour: "Jumping to a message a screen away animates there with no blank strip and lands exactly") { b, c in
        await b.goMiddle()
        let ids = b.chat.ids
        let target = ids[ids.count / 2 - 25]
        let r = await b.record { b.list.apply(TimelineTransaction(scroll: .to(target, .center), timing: .standard)) }
        let blank = r.blankWorst(oldest: ids[0], newest: b.newest)
        c.atMost("blank strip", blank.value, 0.5)
        if blank.value > 0.5 { c.note("blank: \(blank.at)") }
        c.atMost("rows overlapping on screen", r.seams().overlap, 0.5)
        let mid = ((b.shown(target)?.midY ?? 0) - (b.usableTop + b.usableBottom) / 2)
        c.near("lands centred", Double(mid), 0, within: 0.51)
      },
      BehaviourCase(
        id: "anim.jump-far", area: "Row animations",
        behaviour: "Jumping far (thousands of rows) slides the screen out and the destination in as one strip: no blank, lands exactly",
        options: Bench.Options(count: 3000)
      ) { b, c in
        let ids = b.chat.ids
        let target = ids[300]
        let r = await b.record { b.list.apply(TimelineTransaction(scroll: .to(target, .top(20)), timing: .standard, towards: .older)) }
        c.atMost("blank strip", r.blank(oldest: ids[0], newest: b.newest), 0.5)
        c.atMost("rows overlapping on screen", r.seams().overlap, 0.5)
        c.near("lands at top(20)", Double((b.shown(target)?.minY ?? 0) - b.usableTop), 20, within: 0.01)
        c.that("nothing of the old screen is left", b.list.diagnostics.lingeringCount == 0)
      },
      BehaviourCase(
        id: "anim.jump-far-latest", area: "Row animations",
        behaviour: "The scroll-to-bottom action from far up slides to the newest: no blank, ends pinned",
        options: Bench.Options(count: 3000)
      ) { b, c in
        b.list.apply(TimelineTransaction(scroll: .to(b.chat.ids[400], .top(0))))
        let r = await b.record { b.list.apply(TimelineTransaction(scroll: .latest, timing: .standard, towards: .newer)) }
        c.atMost("blank strip", r.blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
        c.atMost("rows overlapping on screen", r.seams().overlap, 0.5)
        c.that("pinned", b.isPinned)
        c.near("newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      },
      BehaviourCase(id: "anim.jump-during-fling", area: "Row animations", behaviour: "A jump while flinging takes over from where the content is: no blank, lands exactly", options: Bench.Options(count: 1500)) { b, c in
        await b.goMiddle()
        let target = b.chat.ids[200]
        let r = await b.record {
          await b.gesture(dy: 24, count: 10)
          await b.wait(0.1)
          b.list.apply(TimelineTransaction(scroll: .to(target, .top(0)), timing: .standard, towards: .older))
        }
        c.atMost("blank strip", r.blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
        c.atMost("rows overlapping on screen", r.seams().overlap, 0.5)
        c.near("lands at top", Double((b.shown(target)?.minY ?? 0) - b.usableTop), 0, within: 0.01)
      },
    ]
  }

  // MARK: - Performance

  /// A fresh list opening the bench's chat at the newest: the list's own time (the whole apply less the lab's row
  /// work: measuring, making and laying out rows) against `budget`, and how much it placed.
  static func open(_ b: Bench, _ c: Checks, budget: Double) async {
    let fresh = TimelineListView(rows: b.chat.rowsAPI())
    fresh.frame = b.list.frame
    b.view.addSubview(fresh)
    let host = b.chat.hostSeconds
    // Inside a transaction, as an event handler calls it: AppKit's display flush (drawing the rows' text) runs when
    // the run loop's transaction ends, not inside `apply`.
    CATransaction.begin()
    let began = CACurrentMediaTime()
    fresh.apply(TimelineTransaction(rows: b.chat.ids, scroll: .latest, topInset: 52, bottomInset: b.view.bottomInset))
    let ms = (CACurrentMediaTime() - began) * 1000
    CATransaction.commit()
    // The rows' own cost: measuring, making and laying them out (the lab's closures), and their view trees joining the
    // window (AppKit, whatever list puts them there).
    let attachMs = fresh.diagnostics.totalAttachDuration * 1000
    let rowsMs = (b.chat.hostSeconds - host) * 1000 + attachMs
    c.atMost("first layout, list's own work", ms - rowsMs, budget, unit: " ms")
    c.note(String(format: "with the rows %.2f ms (rows %.2f ms, of which joining the window %.2f ms)", ms, rowsMs, attachMs))
    c.atMost("rows placed", Double(fresh.diagnostics.placedCount), 40, unit: "")
    fresh.removeFromSuperview()
  }

  static var performance: [BehaviourCase] {
    [
      BehaviourCase(id: "perf.open", area: "Performance", behaviour: "Opening a 2,000-message window lays out only what shows: the list's own first layout under 1 ms", options: Bench.Options(count: 2000)) { b, c in
        await open(b, c, budget: 1)
      },
      BehaviourCase(id: "perf.open-10k", area: "Performance", behaviour: "Opening a 10,000-message window: the list's own first layout under 2 ms", options: Bench.Options(count: 10_000)) { b, c in
        await open(b, c, budget: 2)
        c.note("known: the row index (10,000 hash inserts) runs as unspecialized generic code across modules, ~2 ms in release vs ~0.25 ms specialized; shared with iOS")
      },
      BehaviourCase(
        id: "perf.fling", area: "Performance",
        behaviour: "A fast fling with 1 ms rows: list work per frame p95 under 4 ms, no long frames",
        options: Bench.Options(count: 3000, rowCost: 1)
      ) { b, c in
        await b.goMiddle()
        var perFrame: [Double] = []
        var last = b.list.diagnostics.totalPerformDuration
        b.clock.onFrame = { _ in
          let now = b.list.diagnostics.totalPerformDuration
          if b.list.isFlinging { perFrame.append((now - last) * 1000) }
          last = now
        }
        let gapsBefore = b.clock.gaps.count
        await b.gesture(dy: 48, count: 10)
        await b.untilRest()
        b.clock.onFrame = nil
        let sorted = perFrame.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        c.atMost("list work per frame p95", p95, 4, unit: " ms")
        c.atMost("list work per frame max", sorted.last ?? 0, 10, unit: " ms")
        let nominal = b.clock.gaps.sorted()[b.clock.gaps.count / 2]
        let long = b.clock.gaps[gapsBefore...].filter { $0 > nominal * 1.6 }.count
        c.atMost("long frames", Double(long), 2, unit: "")
      },
      BehaviourCase(id: "perf.page", area: "Performance", behaviour: "A 200-message page landing costs one placement: under 3 ms", options: Bench.Options(count: 2000)) { b, c in
        await b.goMiddle()
        _ = b.chat.prepend(200)
        CATransaction.begin()
        let began = CACurrentMediaTime()
        b.list.apply(TimelineTransaction(rows: b.chat.ids, arrives: false))
        c.atMost("apply", (CACurrentMediaTime() - began) * 1000, 3, unit: " ms")
        CATransaction.commit()
      },
      BehaviourCase(
        id: "perf.resize", area: "Performance",
        behaviour: "Live resize at 2,000 messages: each step p95 under 6 ms (rewrapping uncached rows)",
        options: Bench.Options(count: 2000, size: NSSize(width: 800, height: 760))
      ) { b, c in
        await b.goMiddle()
        var steps: [Double] = []
        for w in Array(stride(from: 800, through: 450, by: -5)) + Array(stride(from: 450, through: 800, by: 5)) {
          let began = CACurrentMediaTime()
          b.resize(width: CGFloat(w))
          steps.append((CACurrentMediaTime() - began) * 1000)
          await b.frames(1)
        }
        let sorted = steps.sorted()
        c.atMost("step p95", sorted[Int(Double(sorted.count - 1) * 0.95)], 6, unit: " ms")
        c.note("includes window frame change and AppKit layout")
      },
      BehaviourCase(id: "perf.memory", area: "Performance", behaviour: "After flinging through 5,000 messages the list holds only what is near the screen", options: Bench.Options(count: 5000)) { b, c in
        await b.goMiddle()
        for _ in 0 ..< 4 {
          await b.gesture(dy: 64, count: 8)
          await b.untilRest()
        }
        let d = b.list.diagnostics
        c.atMost("rows placed", Double(d.placedCount), 50, unit: "")
        c.atMost("slots pooled", Double(d.pooledCount), 32, unit: "")
        c.atMost("row views alive in the host", Double(b.chat.live.count), 60, unit: "")
      },
      BehaviourCase(id: "perf.streaming", area: "Performance", behaviour: "A message streaming 60 updates a second: the list's own work p95 under 1.5 ms") { b, c in
        let id = b.arrive("streaming")
        await b.untilRest()
        var all: [Double] = []
        var own: [Double] = []
        for i in 0 ..< 60 {
          let host = b.chat.hostSeconds
          // Inside a transaction, as an event handler calls it (see `open`).
          CATransaction.begin()
          let began = CACurrentMediaTime()
          b.setText(id, (b.chat.row(id)?.text ?? "") + " w\(i)", timing: .streamingLine)
          let ms = (CACurrentMediaTime() - began) * 1000
          CATransaction.commit()
          all.append(ms)
          own.append(ms - (b.chat.hostSeconds - host) * 1000)
          await b.wait(1.0 / 60)
        }
        own.sort()
        all.sort()
        // p95 for the cost; the worst only bounds it loosely (one sample takes the scheduler's noise on a busy host).
        // About 0.5 ms (solving 13 placed rows, placing them, pins, the date, the knob), spikes to ~1 ms; the lab's
        // own row work (remeasuring the growing text, relayout) is 1–1.7 ms. The budget still catches O(n) work.
        c.atMost("update p95, list's own work", own[Int(Double(own.count - 1) * 0.95)], 1.5, unit: " ms")
        c.atMost("update worst, list's own work", own.last ?? 0, 2, unit: " ms")
        c.note(String(format: "with the lab's row (remeasure and relayout): p95 %.2f ms, worst %.2f ms", all[Int(Double(all.count - 1) * 0.95)], all.last ?? 0))
      },
    ]
  }

  // MARK: - Window

  static var window: [BehaviourCase] {
    [
      BehaviourCase(id: "window.removed-mid-fling", area: "Window", behaviour: "Leaving the window mid-fling finishes where it was going; back in the window it rests there") { b, c in
        await b.goMiddle()
        await b.gesture(dy: 32, count: 12)
        await b.wait(0.1)
        let list = b.list
        let superview = list.superview
        list.removeFromSuperview()
        c.that("fling ended", !list.isFlinging)
        superview?.addSubview(list, positioned: .below, relativeTo: nil)
        b.view.needsLayout = true
        await b.untilRest()
        let blank = (await b.record { await b.frames(3) }).blank(oldest: b.chat.ids[0], newest: b.newest)
        c.atMost("blank strip after", blank, 0.5)
      },
      BehaviourCase(id: "window.hidden-mid-fling", area: "Window", behaviour: "A window hidden mid-fling shows the settled place when it comes back") { b, c in
        await b.goMiddle()
        await b.gesture(dy: 32, count: 12)
        await b.wait(0.1)
        b.window.orderOut(nil)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        b.window.orderFrontRegardless()
        await b.untilRest()
        let blank = (await b.record { await b.frames(3) }).blank(oldest: b.chat.ids[0], newest: b.newest)
        c.atMost("blank strip after", blank, 0.5)
        c.that("at rest", !b.list.isFlinging)
      },
    ]
  }
}
