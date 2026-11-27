import AppKit
import TimelineAppKit
import TimelineCore

// Drawing: frames say where rows are; these check that what is on screen has drawn its content. AppKit draws a view
// only where it is visible by the model geometry, and the list's model scroll is already at a motion's end.

extension SuiteCases {
  static var drawing: [BehaviourCase] {
    [
      BehaviourCase(
        id: "draw.text-during-fling", area: "Drawing",
        behaviour: "Every row on screen shows its text on every frame of a fast fling, both ways",
        options: Bench.Options(count: 3000)
      ) { b, c in
        await b.goMiddle()
        await b.frames(5)
        let rest = await b.undrawnWhile {}
        c.atMost("at rest: rows on screen without their text", Double(rest.worst), 0, unit: "")
        let drag = await b.undrawnWhile { await b.gesture(dy: 6, count: 120, lift: false) }
        c.atMost("slow drag: rows on screen without their text, worst frame", Double(drag.worst), 0, unit: "")
        if drag.worst > 0 { for line in drag.diagnostics.prefix(4) { c.note("drag " + line) } }
        b.send(Synth.trackpad(0, phase: .ended))
        await b.untilRest()
        for (name, dy) in [("older", 60.0), ("newer", -60.0)] {
          if dy > 0 { await b.goMiddle() }
          let undrawn = await b.undrawnWhile { await b.gesture(dy: dy, count: 10) }
          c.atMost("\(name): rows on screen without their text, worst frame", Double(undrawn.worst), 0, unit: "")
          if undrawn.worst > 0 {
            c.note("\(name): \(undrawn.frames) of \(undrawn.total) frames had undrawn rows")
            for line in undrawn.diagnostics { c.note(line) }
          }
          await b.untilRest()
        }
      },
      BehaviourCase(
        id: "draw.text-during-jump", area: "Drawing",
        behaviour: "Every row on screen shows its text on every frame of an animated jump and a far jump's slide",
        options: Bench.Options(count: 3000)
      ) { b, c in
        await b.goMiddle()
        let ids = b.chat.ids
        let near = ids[ids.count / 2 - 25]
        let close = await b.undrawnWhile {
          b.list.apply(TimelineTransaction(scroll: .to(near, .center), timing: .standard))
        }
        c.atMost("near jump: rows on screen without their text, worst frame", Double(close.worst), 0, unit: "")
        let far = ids[200]
        let slide = await b.undrawnWhile {
          b.list.apply(TimelineTransaction(scroll: .to(far, .center), timing: .standard))
        }
        c.atMost("far jump: rows on screen without their text, worst frame", Double(slide.worst), 0, unit: "")
      },
    ]
  }
}

extension Bench {
  struct Undrawn {
    var worst = 0
    var frames = 0
    var total = 0
    var diagnostics: [String] = []
  }

  /// Runs `body`, then watches every frame until the list rests: how many message rows on screen (by where they are
  /// shown) have not drawn their text.
  func undrawnWhile(_ body: () async -> Void) async -> Undrawn {
    var result = Undrawn()
    @MainActor func check() {
      var count = 0
      for placement in list.timelineLayout.placements {
        guard let row = list.view(for: placement.id) as? LabRowView, !row.label.isHidden, !row.bubble.isHidden,
              let shown = shown(placement.id), shown.maxY > usableTop, shown.minY < usableBottom
        else { continue }
        if !row.label.showsItsText {
          count += 1
          if result.diagnostics.count < 12 {
            let model = row.convert(row.bounds, to: list.content)
            result.diagnostics.append(String(
              format: "id %d shown %.0f…%.0f model %.0f…%.0f bounds %.0f…%.0f visibleEmpty %d needsDisplay %d drawn %d",
              placement.id, shown.minY, shown.maxY, model.minY, model.maxY, list.content.bounds.minY, list.content.bounds.maxY,
              row.label.visibleRect.isEmpty ? 1 : 0, row.label.needsDisplay ? 1 : 0, row.label.drawnText == nil ? 0 : 1
            ))
          }
        }
      }
      result.total += 1
      if count > 0 { result.frames += 1 }
      result.worst = max(result.worst, count)
    }
    await body()
    for _ in 0 ..< 400 {
      await frames(1)
      check()
      if !list.isMoving, list.layer?.animationKeys()?.isEmpty ?? true, list.content.layer?.animationKeys()?.isEmpty ?? true {
        break
      }
    }
    return result
  }
}
