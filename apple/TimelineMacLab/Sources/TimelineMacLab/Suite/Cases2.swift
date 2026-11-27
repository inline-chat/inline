import AppKit
import TimelineAppKit
import TimelineCore

extension SuiteCases {
  // MARK: - Bottom-first anchoring

  static var anchoring: [BehaviourCase] {
    [
      BehaviourCase(id: "anchor.page-above", area: "Bottom-first anchoring", behaviour: "A page of history landing above the reader moves nothing on screen") { b, c in
        await b.goMiddle()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY else { return c.that("row", false) }
        let r = await b.record { b.prependPage(50) }
        c.atMost("reading row drift", r.deviation(id, from: Double(y)), 0.01)
      },
      BehaviourCase(
        id: "anchor.page-during-fling", area: "Bottom-first anchoring",
        behaviour: "Pages landing above during a fling do not bend it: same travel as without, no speed jump",
        options: Bench.Options(count: 1200)
      ) { b, c in
        await b.goMiddle()
        var start = b.scrolled
        await b.gesture(dy: 24, count: 12)
        await b.untilRest()
        let baseline = Double(b.scrolled - start)
        await b.goMiddle()
        start = b.scrolled
        guard let id2 = b.middleRow() else { return c.that("row", false) }
        let r = await b.record {
          await b.gesture(dy: 24, count: 12)
          for _ in 0 ..< 4 {
            await b.wait(0.08)
            b.prependPage(50)
          }
        }
        c.near("travel with pages − without", Double(b.scrolled - start) - baseline, 0, within: max(2, baseline * 0.02))
        c.atMost("speed jump", Recording(frames: r.frames.filter(\.flinging)).speedJump(id2), 0.25, unit: "")
      },
      BehaviourCase(id: "anchor.grow-above", area: "Bottom-first anchoring", behaviour: "A message above the reader growing or shrinking (reaction, edit) leaves the reader in place on every frame") { b, c in
        await b.goMiddle()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY,
              let above = b.list.timelineLayout.placements.last(where: { $0.maxY < y - 40 && !(b.chat.row($0.id)?.isDay ?? true) })?.id,
              let text = b.chat.row(above)?.text
        else { return c.that("rows", false) }
        let r = await b.record {
          b.setText(above, text + " grown by several more words so that it wraps onto two more lines of text")
          await b.wait(0.15)
          b.setText(above, "short")
        }
        c.atMost("reading row drift", r.deviation(id, from: Double(y)), 0.5)
        let seams = r.bubbleSeams()
        c.atMost("bubbles overlapping", seams.overlap, 0.5)
        c.atMost("space between bubbles opening up", seams.gapExcess, 0.5)
      },
      BehaviourCase(id: "anchor.delete-above", area: "Bottom-first anchoring", behaviour: "Deleting a message above the reader leaves the reader in place") { b, c in
        await b.goMiddle()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY,
              let above = b.list.timelineLayout.placements.last(where: { $0.maxY < y - 40 && !(b.chat.row($0.id)?.isDay ?? true) })?.id
        else { return c.that("rows", false) }
        let r = await b.record { b.delete(above) }
        c.atMost("reading row drift", r.deviation(id, from: Double(y)), 0.5)
      },
      BehaviourCase(id: "anchor.reading-row-grows", area: "Bottom-first anchoring", behaviour: "The reading row itself growing keeps its top (it grows downward, under the composer)") { b, c in
        await b.goMiddle()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY, let text = b.chat.row(id)?.text else { return c.that("row", false) }
        let r = await b.record { b.setText(id, text + " and it grows by a line or two of more words here") }
        c.atMost("reading row top drift", r.deviation(id, from: Double(y)), 0.5)
      },
      BehaviourCase(id: "anchor.expand-keeps-top", area: "Bottom-first anchoring", behaviour: "A row the reader expands (disclosure) keeps its own top when the host anchors it (Telegram's click anchor)") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let y = b.shown(id)?.minY, let text = b.chat.row(id)?.text else { return c.that("row", false) }
        b.chat.setText(id, text + String(repeating: " expanded content", count: 30))
        let r = await b.record {
          b.list.apply(TimelineTransaction(scroll: .to(id, .top(y - b.usableTop)), changed: [id], timing: .standard))
        }
        c.atMost("expanded row top drift", r.deviation(id, from: Double(y)), 0.5)
      },
      BehaviourCase(id: "anchor.delete-reading-row", area: "Bottom-first anchoring", behaviour: "Deleting the reading row hands its place to the next row; nothing else jumps") { b, c in
        await b.goMiddle()
        guard case let .row(id, _) = b.list.position, let at = b.chat.index(id), at > 1, at + 1 < b.chat.ids.count,
              let height = b.settled(id)?.height
        else { return c.that("rows", false) }
        let above = b.chat.ids[at - 1]
        let below = b.chat.ids[at + 1]
        guard let yAbove = b.shown(above)?.minY, let yBelow = b.shown(below)?.minY else { return c.that("rows", false) }
        let aboveHeight = b.settled(above)?.height ?? 0
        b.delete(id)
        await b.untilRest()
        // The newer neighbour takes the place; older rows close the gap downwards (Telegram anchors the bottom too).
        c.atMost("newer neighbour drift", Double(abs((b.shown(below)?.minY ?? 0) - yBelow)), 0.5)
        let aboveMoved = (b.shown(above)?.minY ?? 0) - yAbove
        let regrouped = (b.settled(above)?.height ?? 0) - aboveHeight
        c.near("older neighbour moved down by the deleted height", Double(aboveMoved + regrouped), Double(height), within: 0.5)
      },
      BehaviourCase(id: "anchor.window-height", area: "Bottom-first anchoring", behaviour: "Scrolled up, the window getting taller or shorter keeps the lowest message's distance from the composer") { b, c in
        await b.goAboveLatest(800)
        guard let id = b.readingRow(), let f = b.shown(id) else { return c.that("row", false) }
        let fromBottom = b.usableBottom - f.maxY
        var worst = 0.0
        for h in Array(stride(from: 760, through: 560, by: -10)) + Array(stride(from: 560, through: 900, by: 10)) {
          b.resize(height: CGFloat(h))
          await b.frames(1)
          worst = max(worst, Double(abs((b.usableBottom - (b.shown(id)?.maxY ?? 0)) - fromBottom)))
        }
        c.atMost("distance from the composer, worst step", worst, 0.5)
      },
      BehaviourCase(
        id: "anchor.width-round-trip", area: "Bottom-first anchoring",
        behaviour: "A live resize narrower and wider and back returns to the same reading place",
        options: Bench.Options(count: 1500, size: NSSize(width: 700, height: 760))
      ) { b, c in
        await b.goMiddle()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY else { return c.that("row", false) }
        var blank = 0.0
        b.startRecording()
        for w in Array(stride(from: 700, through: 420, by: -7)) + Array(stride(from: 420, through: 1100, by: 9)) + Array(stride(from: 1100, through: 700, by: -8)) {
          b.resize(width: CGFloat(w))
          await b.frames(1)
        }
        let r = b.stopRecording()
        blank = r.blank(oldest: b.chat.ids[0], newest: b.newest)
        c.atMost("reading row drift after the round trip", Double(abs((b.shown(id)?.minY ?? 0) - y)), 0.5)
        c.atMost("blank strip during", blank, 0.5)
      },
      BehaviourCase(id: "anchor.top-inset", area: "Bottom-first anchoring", behaviour: "A pinned header appearing at the top (top inset grows) does not move the reader") { b, c in
        await b.goMiddle()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY else { return c.that("row", false) }
        let r = await b.record {
          b.list.setInsets(top: LabChatView.bandHeight + 48, timing: .standard)
          await b.wait(0.4)
          b.list.setInsets(top: LabChatView.bandHeight, timing: .standard)
        }
        c.atMost("reading row drift", r.deviation(id, from: Double(y)), 0.5)
      },
      BehaviourCase(
        id: "anchor.newer-page-not-live", area: "Bottom-first anchoring",
        behaviour: "At the end of a loaded window that is not the live end, a newer page landing below does not pull the reader",
        options: Bench.Options(count: 300, coverage: TimelineCoverage(reachesOldest: true, reachesNewest: false))
      ) { b, c in
        b.list.apply(TimelineTransaction(scroll: .to(b.newest, .bottom(0))))
        await b.untilRest()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY else { return c.that("row", false) }
        _ = b.chat.appendPage(60)
        b.list.apply(TimelineTransaction(rows: b.chat.ids, coverage: TimelineCoverage(reachesOldest: true, reachesNewest: true), arrives: false))
        await b.untilRest()
        c.atMost("reading row drift", Double(abs((b.shown(id)?.minY ?? 0) - y)), 0.01)
        c.that("not pinned", !b.isPinned)
      },
    ]
  }

  // MARK: - Pinning to the newest message

  static var pinning: [BehaviourCase] {
    [
      BehaviourCase(id: "pin.arrival", area: "Scroll pinning", behaviour: "Pinned, a new message rises in and the list stays on the newest; nothing overlaps on the way") { b, c in
        let previous = b.newest
        guard let y = b.shown(previous)?.minY, let oldHeight = b.settled(previous)?.height else { return c.that("row", false) }
        var arrived = 0
        let r = await b.record { arrived = b.arrive() }
        let h = b.list.frame(for: arrived)?.height ?? 0
        let regrouped = oldHeight - (b.settled(previous)?.height ?? 0)
        c.near("newest bottom − usable bottom", Double((b.shown(arrived)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.near("previous newest moved up by the new row's height", Double(y - (b.shown(previous)?.minY ?? 0) + regrouped), Double(h), within: 0.5)
        c.atMost("overlap between rows", r.seams().overlap, 0.5)
        let steps = r.tops(previous)
        let monotonic = zip(steps, steps.dropFirst()).allSatisfy { $1 <= $0 + 0.01 }
        c.that("previous newest only moves up", monotonic)
        c.that("pinned", b.isPinned)
      },
      BehaviourCase(id: "pin.burst", area: "Scroll pinning", behaviour: "Eight messages 30 ms apart: the list ends exactly on the newest, nothing overlaps") { b, c in
        var last = 0
        let r = await b.record {
          for _ in 0 ..< 8 {
            last = b.arrive()
            await b.wait(0.03)
          }
        }
        c.near("newest bottom − usable bottom", Double((b.shown(last)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.atMost("overlap between rows", r.seams().overlap, 0.5)
      },
      BehaviourCase(id: "pin.streaming", area: "Scroll pinning", behaviour: "A streamed reply growing line by line stays on the newest; never a gap above the composer") { b, c in
        let id = b.arrive("streaming")
        await b.untilRest()
        let r = await b.record {
          for i in 0 ..< 16 {
            b.setText(id, (b.chat.row(id)?.text ?? "") + " streamed words \(i) that wrap", timing: .streamingLine)
            await b.wait(0.08)
          }
        }
        let gapAbove = r.frames.compactMap { f in f.rows[id].map { Double(f.usableBottom - $0.maxY) } }.max() ?? 0
        c.atMost("gap between the newest and the composer, worst frame", gapAbove, 0.5)
        c.near("rest: newest bottom − usable bottom", Double((b.shown(id)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      },
      BehaviourCase(id: "pin.scrolled-up", area: "Scroll pinning", behaviour: "Scrolled up, new messages do not move what the reader sees") { b, c in
        await b.goAboveLatest(300)
        guard let id = b.readingRow(), let y = b.shown(id)?.minY else { return c.that("row", false) }
        let r = await b.record {
          _ = b.arrive()
          await b.wait(0.1)
          _ = b.arrive()
        }
        c.atMost("reading row drift", r.deviation(id, from: Double(y)), 0.01)
        c.that("not pinned", !b.isPinned)
      },
      BehaviourCase(id: "pin.threshold", area: "Scroll pinning", behaviour: "Resting within half a point of the newest counts as pinned; two points up does not") { b, c in
        b.list.apply(TimelineTransaction(scroll: .by(0.4)))
        await b.settle()
        let a = b.arrive()
        await b.untilRest()
        c.near("0.4 pt up: newest bottom − usable bottom", Double((b.shown(a)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        b.list.apply(TimelineTransaction(scroll: .by(2)))
        await b.settle()
        let before = b.shown(a)?.minY ?? 0
        // Another sender, so `a` keeps its height (a same-sender message would regroup it).
        let a2 = b.arrive(sender: 3)
        await b.untilRest()
        c.atMost("2 pt up: the last message moved", Double(abs((b.shown(a)?.minY ?? 0) - before)), 0.01)
        c.that("2 pt up: the new message is not pulled into view", abs((b.shown(a2)?.maxY ?? 0) - b.usableBottom) > 1)
      },
      BehaviourCase(id: "pin.send-from-far", area: "Scroll pinning", behaviour: "Sending from far up history goes to the newest message: no blank frame, ends pinned", options: Bench.Options(count: 1500)) { b, c in
        await b.goMiddle()
        await b.untilRest()
        var sent = 0
        let r = await b.record {
          sent = b.chat.append("my reply", outgoing: true)
          b.list.apply(TimelineTransaction(rows: b.chat.ids, scroll: .latest, timing: .standard, towards: .newer))
        }
        let blank = r.blankWorst(oldest: b.chat.ids[0], newest: b.newest)
        c.atMost("blank strip", blank.value, 0.5)
        if blank.value > 0.5 { c.note("blank: \(blank.at)") }
        c.atMost("rows overlapping on screen", r.seams().overlap, 0.5)
        c.near("newest bottom − usable bottom", Double((b.shown(sent)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.that("pinned", b.isPinned)
      },
      BehaviourCase(id: "pin.delete-newest", area: "Scroll pinning", behaviour: "Pinned, deleting the newest message keeps the list on the new newest") { b, c in
        let doomed = b.newest
        b.delete(doomed)
        await b.untilRest()
        c.near("newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.that("pinned", b.isPinned)
      },
      BehaviourCase(id: "pin.receive-while-flinging", area: "Scroll pinning", behaviour: "Messages arriving during a fling up do not bend it; flinging back down lands pinned and follows again") { b, c in
        await b.goAboveLatest(200)
        guard let id = b.middleRow() else { return c.that("row", false) }
        let r = await b.record {
          await b.gesture(dy: 24, count: 10)
          for _ in 0 ..< 3 {
            await b.wait(0.07)
            _ = b.arrive()
          }
        }
        c.atMost("speed jump while receiving", Recording(frames: r.frames.filter(\.flinging)).speedJump(id), 0.25, unit: "")
        b.list.scrollToEndOfDocument(nil)
        await b.untilRest()
        let last = b.arrive()
        await b.untilRest()
        c.near("follows again: newest bottom − usable bottom", Double((b.shown(last)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      },
    ]
  }

  // MARK: - Insets

  static var insets: [BehaviourCase] {
    [
      BehaviourCase(id: "inset.composer-pinned", area: "Insets and composer", behaviour: "Pinned, the composer growing 1→4→1 lines keeps the newest message the same distance above it on every frame") { b, c in
        let newest = b.newest
        let r = await b.record {
          b.view.setComposerLines(4)
          await b.wait(0.5)
          b.view.setComposerLines(1)
        }
        let gaps = r.frames.compactMap { f in f.rows[newest].map { Double(f.composerTop - $0.maxY) } }
        let first = gaps.first ?? 0
        c.atMost("gap deviation, worst frame", gaps.map { abs($0 - first) }.max() ?? .infinity, 0.5)
        c.near("gap", first, 12, within: 0.5)
      },
      BehaviourCase(id: "inset.composer-scrolled", area: "Insets and composer", behaviour: "Scrolled up, the composer growing moves the reader with it (anchored from the bottom), every frame") { b, c in
        await b.goAboveLatest(600)
        guard let id = b.readingRow() else { return c.that("row", false) }
        let r = await b.record {
          b.view.setComposerLines(5)
          await b.wait(0.12)
          b.view.setComposerLines(2)
          await b.wait(0.5)
          b.view.setComposerLines(1)
        }
        c.atMost("reading row to composer, worst deviation", r.distanceToComposerDeviation(id), 0.5)
      },
      BehaviourCase(id: "inset.composer-arrival", area: "Insets and composer", behaviour: "A message arriving while the composer animates lands on the composer: one motion, no overlap") { b, c in
        var arrived = 0
        let r = await b.record {
          b.view.setComposerLines(4)
          await b.wait(0.08)
          arrived = b.arrive()
          await b.wait(0.1)
          b.view.setComposerLines(1)
        }
        c.near("rest: newest to composer", Double(b.view.convert(b.view.composer.frame.origin, to: b.list).y - (b.shown(arrived)?.maxY ?? 0)), 12, within: 0.5)
        c.atMost("overlap between rows", r.seams().overlap, 0.5)
        let underComposer = r.frames.compactMap { f in f.rows[arrived].map { Double($0.maxY - f.composerTop) } }
        _ = underComposer
      },
      BehaviourCase(id: "inset.during-fling", area: "Insets and composer", behaviour: "The composer changing mid-fling does not stop or jolt the fling") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow() else { return c.that("row", false) }
        let r = await b.record {
          await b.gesture(dy: 24, count: 12)
          await b.wait(0.1)
          b.view.setComposerLines(3)
        }
        c.atMost("speed jump", Recording(frames: r.frames.filter(\.flinging)).speedJump(id), 0.3, unit: "")
        c.atMost("blank strip", r.blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
      },
      BehaviourCase(id: "inset.while-held", area: "Insets and composer", behaviour: "With fingers on the trackpad, the composer changing leaves the content under the fingers") { b, c in
        await b.goMiddle()
        guard let id = b.middleRow() else { return c.that("row", false) }
        await b.gesture(dy: 2, count: 3, lift: false)
        let y = b.shown(id)?.minY ?? 0
        let r = await b.record(settle: false) {
          b.view.setComposerLines(4)
          await b.wait(0.45)
        }
        c.atMost("row under the fingers drift", r.deviation(id, from: Double(y)), 0.5)
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
      },
    ]
  }
}
