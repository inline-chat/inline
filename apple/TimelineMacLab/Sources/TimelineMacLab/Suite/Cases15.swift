import AppKit
import TimelineAppKit
import TimelineCore

// Mo (2026-09-26): "preserving a row's pixel offset does not necessarily preserve the passage being read inside a
// huge message". A message taller than the screen, read mid-way, through live-resize steps narrower and wider: the
// passage at the usable top stays there (the host maps offsets across widths: `TimelineRows.passage`).

extension SuiteCases {
  static var passage: [BehaviourCase] {
    [
      BehaviourCase(id: "resize.passage", area: "Resize", behaviour: "Reading inside a message taller than the screen, live resize narrower and wider keeps the passage at the top where it is (within 1 pt) and the rows around it joined", options: Bench.Options(count: 300)) { b, c in
        let ids = b.chat.ids
        let id = ids[ids.count / 2]
        b.setText(id, (0 ..< 90).map { "line \($0) of a very long message that wraps differently at every width" }.joined(separator: " "), timing: .none)
        // Its top 400 pt above the usable top: the reader is inside it.
        b.list.apply(TimelineTransaction(scroll: .to(id, .top(-400))))
        await b.untilRest()
        guard let row = b.shown(id), row.height > b.usableBottom - b.usableTop else { return c.that("a row taller than the screen", false) }
        // The passage at the usable top: its line's first character and the fraction into that line.
        let width = b.list.bounds.width
        let y = b.usableTop - row.minY - LabChat.textTop
        let lines = b.chat.lines(id, width: width)
        let at = lines.lastIndex { $0.y <= y } ?? 0
        let character = lines[at].location
        let fraction = (y - lines[at].y) / lines[at].height
        var worst = 0.0
        var worstAt = ""
        var seam = 0.0
        var trace: [String] = []
        let windowWidth = b.window.frame.width
        let steps = Array(stride(from: 0, through: -150, by: -10)) + Array(stride(from: -150, through: 300, by: 10)) + Array(stride(from: 300, through: 0, by: -10))
        for step in steps {
          b.resize(width: windowWidth + CGFloat(step))
          await b.frames(1)
          guard let now = b.shown(id) else { continue }
          let newLines = b.chat.lines(id, width: b.list.bounds.width)
          guard let line = newLines.last(where: { $0.location <= character }) else { continue }
          let passageTop = now.minY + LabChat.textTop + line.y + fraction * line.height
          let drift = Double(abs(passageTop - b.usableTop))
          if drift > worst { worst = drift; worstAt = "width \(Int(b.list.bounds.width)): passage at \(fmt(Double(passageTop))), usable top \(fmt(Double(b.usableTop)))" }
          if trace.count < 14, drift > 1 || trace.isEmpty { trace.append("w\(Int(b.list.bounds.width)) drift \(fmt(drift)) top \(fmt(Double(now.minY))) h \(fmt(Double(now.height))) pos \(b.list.position)") }
          // The rows around it stay joined.
          let placements = b.list.timelineLayout.placements
          for (a, z) in zip(placements, placements.dropFirst()) { seam = max(seam, Double(abs(z.y - a.maxY))) }
        }
        c.atMost("passage drift at the usable top, worst step", worst, 1)
        if worst > 1 { c.note(worstAt); for t in trace { c.note(t) } }
        c.atMost("rows not joined, worst step", seam, 0.01)
        b.resize(width: windowWidth)
      },
    ]
  }
}
