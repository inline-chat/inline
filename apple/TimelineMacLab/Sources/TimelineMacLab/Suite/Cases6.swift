import AppKit
import TimelineAppKit
import TimelineCore

// The inventory's "not covered yet" list, second batch: changes landing during a bounce, window frame animations, a
// far jump whose window lands later, an end moving under a held pull.

extension SuiteCases {
  static var uncoveredMotion: [BehaviourCase] {
    [
      BehaviourCase(
        id: "fling.updates-during-bounce", area: "Flings",
        behaviour: "An arrival, a delete of the newest and a page landing while a fling bounces past the newest end: the bounce carries on with no jump (it may pull back harder), and settles exactly on the (new) end"
      ) { b, c in
        // A bounce into the newest end; `change` lands as the content shows past the end. Recorded from then on.
        @MainActor func bounce(_ change: String?) async -> (Recording, Int?) {
          await b.goAboveLatest(300)
          await b.untilRest()
          let id = b.middleRow()
          await b.gesture(dy: -40, count: 10)
          for _ in 0 ..< 120 {
            await b.frames(1)
            if Double(b.usableBottom - (b.shown(b.newest)?.maxY ?? b.usableBottom)) > 6 { break }
          }
          let r = await b.record {
            switch change {
              case "arrival": _ = b.arrive()
              case "delete newest": b.delete(b.newest)
              case "page above": b.prependPage(50)
              default: break
            }
          }
          return (r, id)
        }
        for change in ["arrival", "delete newest", "page above"] {
          let (r, id) = await bounce(change)
          guard let id else { c.that("\(change): row", false); continue }
          // The end moving changes how hard the bounce pulls back (a bend, as NSScrollView's when its content size
          // changes); what must not happen is a jump: a one-frame spike.
          c.atMost("\(change): largest one-frame spike", r.largestSpike(id), 3)
          if r.largestSpike(id) > 3 {
            c.note("\(change): " + r.frames.compactMap { f in f.rows[id].map { String(format: "%.3f:%.1f%@", f.t, $0.minY, f.flinging ? "f" : "") } }.prefix(30).joined(separator: " "))
          }
          c.near("\(change): rest: newest bottom − usable bottom", Double((b.shown(b.newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.01)
          c.that("\(change): pinned after", b.isPinned)
        }
      },
      BehaviourCase(
        id: "window.frame-animation", area: "Window",
        behaviour: "An animated window frame change (zoom, a pane opening): pinned, the newest stays on the composer every frame; scrolled up, the reader keeps its distance from the composer"
      ) { b, c in
        @MainActor func animate(to height: CGFloat, width: CGFloat) async -> Recording {
          let window = b.window
          return await b.record {
            var frame = window.frame
            let delta = height - (window.contentView?.bounds.height ?? height)
            frame.size.height += delta
            frame.origin.y -= delta
            frame.size.width = width
            await NSAnimationContext.runAnimationGroup { context in
              context.duration = 0.25
              window.animator().setFrame(frame, display: true)
            }
            await b.wait(0.15)
          }
        }
        let pinned = await animate(to: 620, width: 460)
        let gaps = pinned.frames.compactMap { f in f.rows[b.newest].map { Double(f.composerTop - $0.maxY) } }
        c.atLeast("pinned: frames", Double(gaps.count), 10, unit: "")
        c.atMost("pinned: gap to the composer, worst deviation from 12", gaps.map { abs($0 - 12) }.max() ?? .infinity, 0.5)
        await b.goAboveLatest(500)
        guard let id = b.readingRow() else { return c.that("row", false) }
        let scrolled = await animate(to: 820, width: 560)
        c.atMost("scrolled up: reader to composer, worst deviation", scrolled.distanceToComposerDeviation(id), 0.5)
      },
      BehaviourCase(
        id: "anim.far-jump-late-window", area: "Row animations",
        behaviour: "A far jump whose window loads 30 ms after the request, with wheel scrolling in between: the new rows only show by sliding in, no blank, no overlap, and it lands exactly",
        options: Bench.Options(count: 3000)
      ) { b, c in
        await b.goMiddle()
        let target = b.chat.ids[300]
        let r = await b.record {
          b.wheel(lines: 2)
          await b.wait(0.01)
          b.wheel(lines: 2)
          await b.wait(0.02)
          // The window around the destination lands: rows and scroll in one transaction.
          guard let at = b.chat.index(target) else { return }
          b.chat.keep(max(0, at - 150) ..< min(b.chat.ids.count, at + 150))
          b.list.apply(TimelineTransaction(
            rows: b.chat.ids, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: false),
            scroll: .to(target, .top(20)), timing: .standard, towards: .older
          ))
        }
        c.atMost("blank strip", r.blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
        c.atMost("rows overlapping on screen", r.seams().overlap, 0.5)
        c.near("lands at top(20)", Double((b.shown(target)?.minY ?? 0) - b.usableTop), 20, within: 0.01)
      },
      BehaviourCase(
        id: "input.pull-end-moves", area: "Gestures and input",
        behaviour: "Pulling past the oldest end, a page landing under the fingers: the motion stays with the fingers (no leap), then the lift flings or rests normally",
        options: Bench.Options(count: 200, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: true))
      ) { b, c in
        await b.goOldest()
        let first = b.chat.ids[0]
        await b.gesture(dy: 8, count: 15, lift: false)
        guard let before = b.shown(first)?.minY else { return c.that("first row", false) }
        c.atLeast("pulled past the end", Double(before - b.usableTop), 3)
        let r = await b.record(settle: false) {
          b.prependPage(50, coverage: TimelineCoverage(reachesOldest: true, reachesNewest: true))
          await b.frames(2)
          await b.gesture(dy: 6, count: 10, lift: false, touch: false)
          await b.gesture(dy: -6, count: 10, lift: false, touch: false)
        }
        // The row under the fingers: each frame's step no more than the fingers' (two events can share a frame).
        c.atMost("largest step of the row under the fingers", r.largestStep(first), 12.5)
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        c.atMost("blank strip at rest", (await b.record { await b.frames(2) }).blank(oldest: b.chat.ids[0], newest: b.newest), 0.5)
      },
    ]
  }
}

extension SuiteCases {
  static var accessibility: [BehaviourCase] {
    [
      BehaviourCase(
        id: "access.reduce-motion", area: "Accessibility",
        behaviour: "With Reduce Motion, a jump lands in one frame and a new message fades in where it ends, without rising"
      ) { b, c in
        b.list.reducesMotion = true
        defer { b.list.reducesMotion = false }
        await b.goMiddle()
        let ids = b.chat.ids
        let target = ids[ids.count / 2 - 12]
        let jump = await b.record { b.list.apply(TimelineTransaction(scroll: .to(target, .center), timing: .standard)) }
        let centre = Double((b.usableTop + b.usableBottom) / 2)
        let off = jump.frames.dropFirst().compactMap { f in f.rows[target].map { abs(Double($0.midY) - centre) } }.max() ?? .infinity
        c.atMost("jump: target away from its place on any frame after the change", off, 0.5)
        b.list.apply(TimelineTransaction(scroll: .latest))
        await b.untilRest()
        let previous = b.newest
        var arrived = 0
        let arrival = await b.record { arrived = b.arrive("arrives with reduce motion", sender: 2) }
        let gaps = arrival.frames.compactMap { f -> Double? in
          guard let new = f.rows[arrived], let old = f.rows[previous] else { return nil }
          return Double(new.minY - old.maxY)
        }
        c.atLeast("arrival: frames", Double(gaps.count), 3, unit: "")
        c.atMost("arrival: below its neighbour on any frame (a rise)", gaps.map { abs($0) }.max() ?? .infinity, 0.5)
      },
      BehaviourCase(
        id: "access.list-children", area: "Accessibility",
        behaviour: "For accessibility the list is a list of its placed rows, top to bottom, each a group holding the row"
      ) { b, c in
        await b.goMiddle()
        let children = (b.list.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        c.that("role list", b.list.accessibilityRole() == .list)
        c.near("children", Double(children.count), Double(b.list.diagnostics.placedCount), within: 0)
        let tops = children.map { $0.frame.minY }
        c.that("top to bottom", zip(tops, tops.dropFirst()).allSatisfy { $0 < $1 })
        c.that("each holds its row", zip(children, b.list.timelineLayout.placements).allSatisfy { view, placement in
          b.list.view(for: placement.id)?.superview === view
        })
      },
      BehaviourCase(
        id: "access.scroll-to-visible", area: "Accessibility",
        behaviour: "Accessibility's scroll to visible on a row partly hidden under the composer or the top bar brings it fully into view"
      ) { b, c in
        for edge in ["bottom", "top"] {
          await b.goMiddle()
          // A message row with 20 pt hidden past the edge.
          guard let id = b.middleRow() else { c.that("\(edge): row", false); continue }
          b.list.apply(TimelineTransaction(scroll: .to(id, edge == "bottom" ? .bottom(-20) : .top(-20))))
          await b.settle()
          guard let row = b.list.timelineLayout.placement(for: id), let slot = b.list.view(for: row.id)?.superview else {
            c.that("\(edge): a partly hidden row", false)
            continue
          }
          slot.accessibilityPerformAction(NSAccessibility.Action(rawValue: "AXScrollToVisible"))
          await b.untilRest()
          guard let shown = b.shown(row.id) else { c.that("\(edge): shown", false); continue }
          c.atLeast("\(edge): top below the usable top", Double(shown.minY - b.usableTop), -0.5)
          c.atLeast("\(edge): bottom above the usable bottom", Double(b.usableBottom - shown.maxY), -0.5)
        }
      },
    ]
  }
}
