import AppKit
import TimelineAppKit
import TimelineCore

// The inventory's "not covered yet" list (`2026-11-26-macos-timeline-inventory.md`, section 4), first batch.

extension SuiteCases {
  static var uncovered: [BehaviourCase] {
    [
      BehaviourCase(
        id: "input.no-descendant-scroll", area: "Gestures and input",
        behaviour: "Nothing inside a row can scroll the list: a text view revealing its selection, scrollToVisible from a row or a text view, a text view's autoscroll do nothing (the old list leapt 130–941 pt in Alerts from this)"
      ) { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let row = b.list.view(for: id) else { return c.that("row", false) }
        let text = NSTextView(frame: NSRect(x: 60, y: 4, width: 200, height: 40))
        text.string = String(repeating: "a long line of text in a row ", count: 40)
        row.addSubview(text)
        let before = b.scrolled
        let r = await b.record {
          text.setSelectedRange(NSRange(location: text.string.count - 1, length: 0))
          text.scrollRangeToVisible(NSRange(location: text.string.count - 1, length: 0))
          _ = text.scrollToVisible(NSRect(x: 0, y: 2000, width: 10, height: 10))
          row.scrollToVisible(NSRect(x: 0, y: -900, width: 10, height: 10))
          _ = row.scrollToVisible(NSRect(x: 0, y: 1500, width: 10, height: 10))
          row.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 1500))
          _ = text.autoscroll(with: NSEvent.mouseEvent(
            with: .leftMouseDragged, location: b.list.convert(NSPoint(x: 100, y: b.usableTop + 4), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: b.window.windowNumber,
            context: nil, eventNumber: 9, clickCount: 1, pressure: 1
          )!)
          await b.frames(3)
        }
        text.removeFromSuperview()
        c.atMost("list moved", Double(abs(b.scrolled - before)), 0.01)
        c.atMost("row moved on screen", r.deviation(id, from: r.tops(id).first ?? 0), 0.01)
      },
      BehaviourCase(
        id: "resize.offscreen-rows", area: "Window",
        behaviour: "After a live width change, flinging into rows that were off screen during it shows each at its final height: no height corrected on screen, no seam",
        options: Bench.Options(count: 2000, size: NSSize(width: 700, height: 760))
      ) { b, c in
        await b.goMiddle()
        for w in stride(from: 700, through: 460, by: -8) {
          b.resize(width: CGFloat(w))
          await b.frames(1)
        }
        await b.untilRest()
        let r = await b.record { await b.gesture(dy: 40, count: 12) }
        var corrected = 0.0
        var first: [Int: CGFloat] = [:]
        for frame in r.frames {
          for (id, rect) in frame.rows {
            if let height = first[id] { corrected = max(corrected, Double(abs(rect.height - height))) } else { first[id] = rect.height }
          }
        }
        let seams = r.seams()
        c.atLeast("rows seen", Double(first.count), 30, unit: "")
        c.atMost("a row's height changing on screen", corrected, 0.01)
        c.atMost("gap between rows", seams.gap, 0.5)
        c.atMost("overlap between rows", seams.overlap, 0.5)
      },
      BehaviourCase(
        id: "pin.live-resize", area: "Scroll pinning",
        behaviour: "Pinned, a live resize of height and width keeps the newest message on the composer at every step"
      ) { b, c in
        var worst = 0.0
        let heights = Array(stride(from: 760, through: 560, by: -10)) + Array(stride(from: 560, through: 900, by: 12))
        for h in heights {
          b.resize(height: CGFloat(h))
          await b.frames(1)
          worst = max(worst, Double(abs((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom)))
        }
        for w in Array(stride(from: 520, through: 380, by: -7)) + Array(stride(from: 380, through: 720, by: 9)) {
          b.resize(width: CGFloat(w))
          await b.frames(1)
          worst = max(worst, Double(abs((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom)))
        }
        c.atMost("newest bottom − usable bottom, worst step", worst, 0.5)
        c.that("pinned after", b.isPinned)
      },
      BehaviourCase(
        id: "anchor.one-update-many", area: "Bottom-first anchoring",
        behaviour: "Scrolled up, one update carrying a page above, a delete above, the newest growing and an arrival leaves the reader in place; nothing crosses (the old list drifted −40 pt)"
      ) { b, c in
        await b.goMiddle()
        guard let reading = b.readingRow(), let y = b.shown(reading)?.minY,
              let above = b.list.timelineLayout.placements.last(where: { $0.maxY < y - 40 && !(b.chat.row($0.id)?.isDay ?? true) })?.id
        else { return c.that("rows", false) }
        let newest = b.newest
        let r = await b.record {
          _ = b.chat.prepend(50)
          b.chat.delete(above)
          b.chat.setText(newest, (b.chat.row(newest)?.text ?? "") + String(repeating: " grown", count: 30))
          _ = b.chat.append("an arrival in the same update", sender: 2)
          b.list.apply(TimelineTransaction(rows: b.chat.ids, changed: [newest], timing: .standard))
        }
        c.atMost("reader drift", r.deviation(reading, from: Double(y)), 0.5)
        c.atMost("bubbles overlapping", r.bubbleSeams(excluding: [above]).overlap, 0.5)
      },
      BehaviourCase(
        id: "pin.one-update-many", area: "Scroll pinning",
        behaviour: "Pinned, one update carrying a page above, a delete above, the newest growing and an arrival ends on the new newest; nothing crosses"
      ) { b, c in
        guard let above = b.list.timelineLayout.placements.dropLast(3).last(where: { !(b.chat.row($0.id)?.isDay ?? true) })?.id
        else { return c.that("rows", false) }
        let newest = b.newest
        var arrived = 0
        let r = await b.record {
          _ = b.chat.prepend(50)
          b.chat.delete(above)
          b.chat.setText(newest, (b.chat.row(newest)?.text ?? "") + String(repeating: " grown", count: 30))
          arrived = b.chat.append("an arrival in the same update", sender: 2)
          b.list.apply(TimelineTransaction(rows: b.chat.ids, changed: [newest], timing: .standard))
        }
        c.near("rest: newest bottom − usable bottom", Double((b.shown(arrived)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.atMost("bubbles overlapping", r.bubbleSeams(excluding: [above]).overlap, 0.5)
        c.that("pinned", b.isPinned)
      },
      BehaviourCase(
        id: "pin.detached-by-scroll", area: "Scroll pinning",
        behaviour: "A wheel notch, Page Up or a selection autoscroll up unpins: the next arrival does not pull the reader back down"
      ) { b, c in
        let ways: [(String, @MainActor () -> Void)] = [
          ("wheel", { b.wheel(lines: 2) }),
          ("page up", { b.list.pageUp(nil) }),
          ("autoscroll", {
            for _ in 0 ..< 3 {
              _ = b.list.autoscroll(with: NSEvent.mouseEvent(
                with: .leftMouseDragged, location: b.list.convert(NSPoint(x: 100, y: b.usableTop - 30), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: b.window.windowNumber,
                context: nil, eventNumber: 3, clickCount: 1, pressure: 1
              )!)
            }
          }),
        ]
        for (name, scroll) in ways {
          b.list.apply(TimelineTransaction(scroll: .latest))
          await b.untilRest()
          scroll()
          await b.untilRest()
          c.that("\(name): unpinned", !b.isPinned)
          guard let id = b.readingRow(), let y = b.shown(id)?.minY else { c.that("\(name): row", false); continue }
          _ = b.arrive()
          await b.untilRest()
          c.atMost("\(name): reader moved by the arrival", Double(abs((b.shown(id)?.minY ?? 0) - y)), 0.01)
        }
      },
      BehaviourCase(
        id: "input.held-row-changes", area: "Gestures and input",
        behaviour: "With fingers resting on the trackpad, rows growing above the reader and the reading row itself keep the reading row in place (bottom-first, as at rest), and the lift does not fling"
      ) { b, c in
        await b.goMiddle()
        await b.gesture(dy: 3, count: 6, lift: false)
        await b.wait(0.1)
        guard let id = b.readingRow(), let y = b.shown(id)?.minY,
              let above = b.list.timelineLayout.placements.last(where: { $0.maxY < y - 40 && !(b.chat.row($0.id)?.isDay ?? true) })?.id
        else { return c.that("rows", false) }
        let r = await b.record(settle: false) {
          b.setText(above, (b.chat.row(above)?.text ?? "") + String(repeating: " more", count: 20))
          b.setText(id, (b.chat.row(id)?.text ?? "") + String(repeating: " more", count: 20))
          await b.wait(0.4)
        }
        c.atMost("reading row drift", r.deviation(id, from: Double(y)), 0.5)
        b.send(Synth.trackpad(0, phase: .ended))
        await b.frames(2)
        c.that("no fling on lift", !b.list.isFlinging)
        await b.untilRest()
      },
      BehaviourCase(
        id: "pin.send-one-transaction", area: "Scroll pinning",
        behaviour: "Sending as the composer shrinks 3→1 lines, in one transaction: the sent message closes on the composer in one motion and lands 12 pt above it"
      ) { b, c in
        b.view.setComposerLines(3)
        await b.untilRest()
        var sent = 0
        let r = await b.record {
          CATransaction.begin()
          sent = b.chat.append("my reply as the composer empties", outgoing: true)
          b.view.setComposerLines(1)
          b.list.apply(TimelineTransaction(rows: b.chat.ids, scroll: .latest, timing: .standard, towards: .newer))
          CATransaction.commit()
        }
        let gaps = r.frames.compactMap { f in f.rows[sent].map { Double(f.composerTop - $0.maxY) } }
        let reversals = zip(gaps, gaps.dropFirst()).filter { $1 < $0 - 0.05 }.count
        c.atLeast("frames", Double(gaps.count), 5, unit: "")
        c.atMost("frames where it falls back from the composer", Double(reversals), 0, unit: "")
        c.near("rest: gap to the composer", gaps.last ?? 0, 12, within: 0.5)
      },
      BehaviourCase(
        id: "sticky.under-list-motion", area: "Sticky items",
        behaviour: "Avatars and the floating date keep their rules on every frame while the composer moves the list, during an animated jump, and while rows change height",
        options: Bench.Options(count: 800, groupRun: 8)
      ) { b, c in
        await b.goMiddle()
        @MainActor func judge(_ name: String, _ r: Recording) {
          c.atMost("\(name): avatar error, worst frame", StickyRules.avatarError(r, chat: b.chat, edge: avatarEdge(b)).error, 0.5)
          let h = StickyRules.headerError(r, chat: b.chat)
          c.atMost("\(name): floating date position error, worst frame", h.position, 0.5)
          c.atMost("\(name): frames with the date shown, hidden or titled wrongly", Double(h.wrongVisibility + h.wrongTitle), 0, unit: "")
        }
        judge("composer", await b.record {
          b.view.setComposerLines(5)
          await b.wait(0.15)
          b.view.setComposerLines(1)
        })
        let ids = b.chat.ids
        let jump = await b.record { b.list.apply(TimelineTransaction(scroll: .to(ids[ids.count / 2 - 20], .center), timing: .standard)) }
        judge("jump", jump)
        var noted = 0
        for frame in jump.frames where noted < 8 {
          for (id, a) in frame.avatars where noted < 8 {
            guard a.maxY > frame.usableTop, a.minY < frame.usableBottom + 40,
                  let exp = StickyRules.expectedAvatarBottom(lastRow: id, in: frame, chat: b.chat, edge: frame.composerTop - 12), abs(exp - a.maxY) > 0.5 else { continue }
            noted += 1
            c.note(String(format: "t %.3f id %d avatar %.1f exp %.1f row %@ first %@ placed %@", frame.t, id, a.maxY, exp, String(describing: frame.rows[id]), String(describing: b.chat.group(id).flatMap { frame.rows[$0.start] }), String(describing: b.list.timelineLayout.placement(for: id).map { $0.y })))
          }
        }
        if let id = b.middleRow(), let text = b.chat.row(id)?.text {
          judge("height", await b.record {
            b.setText(id, text + String(repeating: " more", count: 40))
            await b.wait(0.1)
            b.setText(id, text)
          })
        }
      },
      BehaviourCase(
        id: "anim.delete-during-arrival", area: "Row animations",
        behaviour: "A message deleted 60 ms into its arrival fades from where it is (never brighter again) and its neighbours close without crossing"
      ) { b, c in
        let id = b.arrive("arrives and is deleted at once", sender: 2)
        await b.wait(0.06)
        guard let slotLayer = b.chat.live[id]?.superview?.layer else { return c.that("row view", false) }
        // A retired slot is hidden (pooled) or out of the tree: it shows nothing.
        func shown() -> Float {
          guard !slotLayer.isHidden, slotLayer.superlayer != nil else { return 0 }
          return (slotLayer.presentation() ?? slotLayer).opacity
        }
        var opacities: [Float] = [shown()]
        let r = await b.record {
          b.delete(id)
          for _ in 0 ..< 20 {
            await b.frames(1)
            opacities.append(shown())
          }
        }
        let rises = zip(opacities, opacities.dropFirst()).map { Double($1 - $0) }.max() ?? 0
        if rises > 0.01 { c.note("opacities " + opacities.map { String(format: "%.2f", $0) }.joined(separator: " ") + " keys \(slotLayer.animationKeys() ?? [])") }
        c.atMost("opacity rising after the delete", rises, 0.01)
        c.atMost("kept bubbles overlapping", r.bubbleSeams(excluding: [id]).overlap, 0.5)
        c.near("rest: newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      },
      BehaviourCase(
        id: "pin.streaming-leaves-and-returns", area: "Scroll pinning",
        behaviour: "A message streaming while the reader scrolls away and back shows at its final height when it comes back: no jump, no empty row"
      ) { b, c in
        let id = b.arrive("streaming", sender: 2)
        await b.untilRest()
        for i in 0 ..< 10 {
          b.setText(id, (b.chat.row(id)?.text ?? "") + " streamed words \(i) that wrap", timing: .streamingLine)
          await b.wait(1.0 / 60)
        }
        b.list.apply(TimelineTransaction(scroll: .by(1600)))
        await b.settle()
        c.that("scrolled away", b.shown(id) == nil)
        for i in 10 ..< 30 {
          b.setText(id, (b.chat.row(id)?.text ?? "") + " streamed words \(i) that wrap", timing: .streamingLine)
          await b.wait(1.0 / 60)
        }
        let r = await b.record { b.list.apply(TimelineTransaction(scroll: .latest, timing: .standard, towards: .newer)) }
        let final = b.settled(id)?.height ?? 0
        let heights = r.frames.compactMap { $0.rows[id]?.height }
        c.atLeast("frames showing it", Double(heights.count), 3, unit: "")
        c.atMost("height shown other than its final one", heights.map { Double(abs($0 - final)) }.max() ?? 0, 0.01)
        c.atMost("overlap between rows", r.seams().overlap, 0.5)
        c.near("rest: newest bottom − usable bottom", Double((b.shown(id)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      },
      BehaviourCase(
        id: "pos.text-size-replan", area: "Scroll positioning",
        behaviour: "Every row 1.2× taller at once (a text size change), in one pass: scrolled up the reading row keeps its top, pinned the newest stays on the composer"
      ) { b, c in
        await b.goMiddle()
        guard let id = b.readingRow(), let y = b.shown(id)?.minY else { return c.that("row", false) }
        b.chat.heightScale = 1.2
        b.list.apply(TimelineTransaction(changed: Set(b.chat.ids)))
        await b.settle()
        c.near("scrolled up: reading row top moved", Double((b.shown(id)?.minY ?? 0) - y), 0, within: 0.5)
        b.chat.heightScale = 1
        b.list.apply(TimelineTransaction(scroll: .latest, changed: Set(b.chat.ids)))
        await b.untilRest()
        b.chat.heightScale = 1.2
        b.list.apply(TimelineTransaction(changed: Set(b.chat.ids)))
        await b.settle()
        c.near("pinned: newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
        c.that("pinned", b.isPinned)
        b.chat.heightScale = 1
      },
      BehaviourCase(
        id: "input.swipe-locks-vertical", area: "Gestures and input",
        behaviour: "Once a gesture starts sideways (swipe to reply), its later vertical movement does not scroll the list"
      ) { b, c in
        await b.goMiddle()
        guard let id = b.middleRow(), let start = b.shown(id)?.minY else { return c.that("row", false) }
        var taken = 0
        b.list.onHorizontalScroll = { _, _ in
          taken += 1
          return true
        }
        defer { b.list.onHorizontalScroll = nil }
        var steps: [(at: Double, event: CGEvent)] = [(0, Synth.trackpad(0, phase: .mayBegin))]
        steps.append((1.0 / 120, Synth.trackpadXY(dx: -12, dy: 0, phase: .began)))
        for i in 0 ..< 20 {
          steps.append((Double(i + 2) / 120, Synth.trackpadXY(dx: i < 6 ? -8 : -1, dy: i < 6 ? 0 : 9, phase: .changed)))
        }
        steps.append((23.0 / 120, Synth.trackpad(0, phase: .ended)))
        await b.play(steps)
        await b.untilRest()
        c.atMost("vertical travel", Double(abs((b.shown(id)?.minY ?? 0) - start)), 0.01)
        c.atLeast("events to the row", Double(taken), 20, unit: "")
      },
      BehaviourCase(
        id: "fling.frame-rate", area: "Flings",
        behaviour: "A fling's frames run at the display's top rate, minimum equal to maximum (Telegram CoreList: a range lets the system throttle to ~80 Hz)"
      ) { b, c in
        await b.goMiddle()
        await b.gesture(dy: 32, count: 10)
        await b.frames(2)
        // A coast moves the content from the list's ticks; a render-server fling from its animation.
        let range = b.list.diagnostics.tickRate ?? b.list.content.layer?.animation(forKey: "timeline.flight")?.preferredFrameRateRange
        let top = Float(b.window.screen?.maximumFramesPerSecond ?? 60)
        c.that("a fling running", range != nil)
        c.near("minimum", Double(range?.minimum ?? 0), Double(top), within: 0.5)
        c.near("maximum", Double(range?.maximum ?? 0), Double(top), within: 0.5)
        await b.untilRest()
      },
    ]
  }
}

extension SuiteCases {
  /// A jump from the middle, animated; `interrupt` runs about 40% of the way in (0.06 s into the spring). `rows` away:
  /// 12 keeps rows in common with the screen (a scroll), 25 does not (a far jump's slide).
  static func interruptedJump(
    _ b: Bench, rows: Int = 12, _ interrupt: (() async -> Void)?
  ) async -> (recording: Recording, target: Int, row: Int?) {
    await b.goMiddle()
    let ids = b.chat.ids
    let target = ids[ids.count / 2 - rows]
    let row = b.middleRow()
    let r = await b.record {
      b.list.apply(TimelineTransaction(scroll: .to(target, .center), timing: .standard))
      guard let interrupt else { return }
      await b.wait(0.06)
      await interrupt()
    }
    return (r, target, row)
  }

  static var interruptions: [BehaviourCase] {
    [
      BehaviourCase(
        id: "anim.jump-stopped", area: "Row animations",
        behaviour: "A wheel notch or a trackpad touch during an animated jump stops it where it shows (then the notch's 10 pt), as a touch catches a fling"
      ) { b, c in
        for (name, extra) in [("wheel", 10.0), ("touch", 0.0)] {
          var at: (y: Double, step: Double)?
          var tracked = 0
          let run = await interruptedJump(b) {
            // The last two frames before the interruption: where the content was and how fast it went.
            let id = b.middleRow() ?? 0
            tracked = id
            let y0 = Double(b.shown(id)?.minY ?? 0)
            await b.frames(1)
            let y1 = Double(b.shown(id)?.minY ?? 0)
            at = (y1, abs(y1 - y0))
            if name == "wheel" { b.wheel(lines: 1) } else { await b.touch(lift: false) }
            await b.frames(6)
            if name == "touch" { b.send(Synth.trackpad(0, phase: .cancelled)) }
          }
          _ = run
          await b.untilRest()
          guard let at, let final = b.shown(tracked)?.minY else { c.that("\(name): row", false); continue }
          // Stopped within one frame of motion of where it showed, plus the notch; nowhere near the destination.
          c.atMost("\(name): distance from where it showed (beyond one frame's travel)", max(0, abs(Double(final) - extra - at.y) - at.step), 0.5)
          c.that("\(name): not at the destination", b.list.timelineLayout.placement(for: run.target).map { abs(($0.y + $0.height / 2) - (b.usableTop + b.usableBottom) / 2) > 50 } ?? true)
          let sticky = StickyRules.avatarError(run.recording, chat: b.chat, edge: avatarEdge(b))
          c.atMost("\(name): avatar error, worst frame", sticky.error, 0.5)
        }
      },
      BehaviourCase(
        id: "anim.jump-undisturbed", area: "Row animations",
        behaviour: "A page landing above, or the same jump asked again, during an animated jump or a far jump's slide keeps one motion (no step) and lands exactly"
      ) { b, c in
        for (kind, rows) in [("jump", 12), ("slide", 25)] {
          for name in ["same jump", "page above"] {
            // The undisturbed jump from the same state, then the disturbed one.
            let baseline = await interruptedJump(b, rows: rows, nil)
            let base = baseline.row.map { baseline.recording.largestStep($0) } ?? 0
            c.atMost("\(kind), undisturbed: avatar error, worst frame", StickyRules.avatarError(baseline.recording, chat: b.chat, edge: avatarEdge(b)).error, 0.5)
            let target = b.chat.ids[b.chat.ids.count / 2 - rows]
            let run = await interruptedJump(b, rows: rows) {
              if name == "page above" {
                b.prependPage(50)
              } else {
                b.list.apply(TimelineTransaction(scroll: .to(target, .center), timing: .standard))
              }
            }
            c.that("\(kind), \(name): the same row tracked", run.row == baseline.row && run.target == target)
            let step = run.row.map { run.recording.largestStep($0) } ?? 0
            // Two runs sample the spring at frame phases up to ~0.2 ms apart: at its top speed (~8,000 pt/s) that is
            // ~1.6 pt of step either way. A snap shows as tens of points.
            c.atMost("\(kind), \(name): largest step beyond the undisturbed one's", max(0, step - base), 3)
            c.near("\(kind), \(name): lands centred", Double((b.shown(target)?.midY ?? 0) - (b.usableTop + b.usableBottom) / 2), 0, within: 0.51)
            let sticky = StickyRules.avatarError(run.recording, chat: b.chat, edge: avatarEdge(b))
            c.atMost("\(kind), \(name): avatar error, worst frame", sticky.error, 0.5)
            if sticky.error > 0.5 {
              var noted = 0
              for frame in run.recording.frames where noted < 4 {
                for (id, a) in frame.avatars where noted < 4 {
                  guard a.maxY > frame.usableTop, a.minY < frame.usableBottom + 40,
                        let exp = StickyRules.expectedAvatarBottom(lastRow: id, in: frame, chat: b.chat, edge: frame.composerTop - 12), abs(exp - a.maxY) > 0.5 else { continue }
                  noted += 1
                  c.note(String(format: "%@ %@ t %.3f id %d avatar %.1f exp %.1f row %@ first %@", kind, name, frame.t, id, a.maxY, exp, String(describing: frame.rows[id]), String(describing: b.chat.group(id).flatMap { frame.rows[$0.start] })))
                }
              }
            }
          }
        }
      },
    ]
  }
}
