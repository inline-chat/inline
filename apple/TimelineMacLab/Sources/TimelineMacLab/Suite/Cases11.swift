import AppKit
import QuartzCore
import TimelineAppKit
import TimelineCore

// Updates under every kind of motion (Mo, 2026-11-26: "reloads, reorders, deletions, size changes and streaming and
// such should behave completely well"; "great coordination across insets, message views, scroll position and
// anchoring, etc in animations and updates").
//
// A matrix: each change (streaming, edits, deletes, reorders, reloads, batches, inset and width changes with updates)
// under each motion (at rest mid-history, pinned to the newest, dragged, flinging, mid animated jump, bouncing past the
// newest end). Every frame is checked from the presentation layers: no overlap between bubbles, no gap opening between
// neighbours beyond their before/after spacing, no blank strip, no row undrawn on screen for two frames, the floating
// date and avatars where their rules put them; then per motion: the reader held (bottom-first rules), pinned staying
// pinned, the motion carrying on with no jump (speed spikes on a row the change leaves alone), a jump landing on its
// target. The `update.none` control runs every motion with no change: its spikes are the motions' own noise.
//
// `update.fuzz`: seeded random changes interleaved with random motions, structural invariants after every step and
// presentation invariants every frame. TL_FUZZ_SEED picks the seed, TL_FUZZ_STEPS the length (default 40).

// MARK: - Motions and changes

enum UpdateMotion: String, CaseIterable {
  case still, pinned, drag, fling, jump, bounce
}

enum UpdateChange: String, CaseIterable {
  case none
  case streamNewest, streamAbove, streamBelow
  case growAbove, shrinkAbove, growVisible, growReader, growBelow
  case deleteReader, deleteVisible, deleteAbove, deleteUnderPointer
  case reorderPending, reorderAdjacent
  case reloadSame, reloadShifted, reloadRenumbered, reloadRenumberedTargeted
  case batch
  case insetWithArrival, insetWithDelete
  case widthDuringGrow

  var behaviour: String {
    switch self {
      case .none: "Control: every motion with no change (its speed spikes are the motion's own)"
      case .streamNewest: "The newest message streams (grows line by line) under every motion"
      case .streamAbove: "A message above the screen streams while the reader reads below it"
      case .streamBelow: "Scrolled up into history, a message below the screen streams: the reader's rows stay still (Telegram does not restore the place here, TableView.swift:2873-2891)"
      case .growAbove: "A message above the screen grows (edit, reaction)"
      case .shrinkAbove: "A message above the screen shrinks"
      case .growVisible: "A message on screen above the reader grows"
      case .growReader: "The reading message itself grows (keeps its top)"
      case .growBelow: "A message below the screen grows"
      case .deleteReader: "The reading message is deleted (its newer neighbour takes its place)"
      case .deleteVisible: "A message on screen above the reader is deleted"
      case .deleteAbove: "A message above the screen is deleted"
      case .deleteUnderPointer: "The message under the pointer is deleted"
      case .reorderPending: "A pending message is confirmed into a different place (moves past its neighbour)"
      case .reorderAdjacent: "Two neighbours on screen swap places (a corrected time)"
      case .reloadSame: "A reload with the same ids and everything marked changed moves nothing"
      case .reloadShifted: "A reload that trims the oldest rows and adds newer ones in one update"
      case .reloadRenumbered: "A reload that renumbers every row (all-new ids, same content), keeping the scroll"
      case .reloadRenumberedTargeted: "A reload that renumbers every row with a scroll target at the reader's new id"
      case .batch: "One update: a page above, a delete above, a message on screen growing, an arrival, a delete near the newest"
      case .insetWithArrival: "The composer shrinks in the same transaction as an arrival (a send)"
      case .insetWithDelete: "The composer grows in the same transaction as a delete above"
      case .widthDuringGrow: "The width changes while a message's height change animates"
    }
  }

  /// Motions that make sense for the change.
  func applies(to motion: UpdateMotion) -> Bool {
    switch (self, motion) {
      // Pinned there is no reader in history and nothing below the screen.
      case (.growBelow, .pinned), (.streamBelow, .pinned), (.streamAbove, .pinned), (.reloadShifted, .bounce): false
      // A reorder of a pending message happens at the newest end.
      case (.reorderPending, .still), (.reorderPending, .drag), (.reorderPending, .jump): false
      default: true
    }
  }
}

/// What one change under one motion showed.
@MainActor
struct UpdateRun {
  var recording: Recording
  /// The longest run of consecutive frames a row showed undrawn in the usable area, and which row.
  var undrawnFrames: Int
  var undrawnRow: Int?
}

@MainActor
final class UndrawnWatch {
  var streaks: [Int: Int] = [:]
  var worst = 0
  var worstRow: Int?

  func sample(_ b: Bench) {
    var seen: Set<Int> = []
    for placement in b.list.timelineLayout.placements {
      guard let row = b.list.view(for: placement.id) as? LabRowView, !row.label.isHidden, !row.bubble.isHidden,
            !row.label.showsItsText, let shown = b.list.presentedFrame(for: placement.id),
            shown.maxY > b.usableTop, shown.minY < b.usableBottom
      else { continue }
      seen.insert(placement.id)
      let n = (streaks[placement.id] ?? 0) + 1
      streaks[placement.id] = n
      if n > worst {
        worst = n
        worstRow = placement.id
      }
    }
    streaks = streaks.filter { seen.contains($0.key) }
  }
}

extension Bench {
  /// Records as `record` does, and also counts frames rows showed undrawn.
  func watch(settle: Bool = true, _ body: () async -> Void) async -> UpdateRun {
    let recorder = Recorder(bench: self)
    let undrawn = UndrawnWatch()
    clock.onFrame = { [unowned self] timestamp in
      recorder.sample(timestamp)
      undrawn.sample(self)
    }
    recorder.sample(CACurrentMediaTime())
    await body()
    if settle { await untilRest() }
    await frames(2)
    clock.onFrame = nil
    return UpdateRun(recording: recorder.recording, undrawnFrames: undrawn.worst, undrawnRow: undrawn.worstRow)
  }

  var messageRows: [TimelinePlacement<Int>] {
    list.timelineLayout.placements.filter { !(chat.row($0.id)?.isDay ?? true) }
  }

  /// The row the engine anchors on (the lowest visible one) when it is a message.
  func anchorRow() -> Int? {
    guard case let .row(id, _) = list.position, chat.row(id)?.isDay == false, let shown = shown(id),
          shown.minY < usableBottom, shown.maxY > usableTop
    else { return nil }
    return id
  }

  /// A message placed wholly above the usable area.
  func rowAboveScreen() -> Int? { messageRows.last(where: { $0.maxY < usableTop - 4 })?.id }

  /// A message placed wholly below the usable area.
  func rowBelowScreen() -> Int? { messageRows.first(where: { $0.y > usableBottom + 4 })?.id }

  /// A message wholly on screen above `reader`.
  func rowVisible(above reader: Int?) -> Int? {
    let readerTop = reader.flatMap { settled($0)?.minY } ?? usableBottom
    return messageRows.last(where: { $0.y >= usableTop && $0.maxY < readerTop - 10 })?.id
  }

  /// The row the pointer is over: synthetic events point at the list's centre.
  func rowUnderPointer() -> Int? {
    let id = list.row(atPresented: NSPoint(x: list.bounds.midX, y: list.bounds.midY))
    return id.flatMap { chat.row($0)?.isDay == false ? $0 : nil }
  }
}

extension Recording {
  /// The largest one-frame spike in a row's speed (pt/s): a frame whose speed differs from both neighbours' in the
  /// same direction. A jump in an otherwise smooth motion (a snap, a frame of compensation) shows here; a steady
  /// deceleration or a lasting change of speed does not.
  func speedSpike(_ id: Int) -> Double {
    var samples: [(t: Double, y: Double)] = []
    for frame in frames { if let rect = frame.rows[id] { samples.append((frame.t, Double(rect.minY))) } }
    guard samples.count > 3 else { return 0 }
    var speeds: [Double] = []
    for (a, b) in zip(samples, samples.dropFirst()) {
      let dt = b.t - a.t
      speeds.append(dt > 0.001 ? (b.y - a.y) / dt : 0)
    }
    var worst = 0.0
    for i in 1 ..< speeds.count - 1 {
      let d1 = speeds[i] - speeds[i - 1]
      let d2 = speeds[i] - speeds[i + 1]
      guard d1.sign == d2.sign else { continue }
      worst = max(worst, min(abs(d1), abs(d2)))
    }
    return worst
  }

  /// The largest blank strip inside the usable area, leaving out the gaps where rows the change removed or moved were
  /// (`touched`, in the order `before` the change): by design those close as the row fades (0.15 s) and its neighbours
  /// close on the row spring. They are judged apart: `reopen` is the most such a gap grew between frames (it must
  /// only close); `whileMoving` the largest it showed on screen while the list moved (Telegram applies updates
  /// without animation while the user scrolls, so it shows none).
  func blankOutsideChanges(oldest: Int, newest: Int, before: [Int], after: [Int] = [], touched: Set<Int>, bottomIsEnd: Bool = false, bottomGap: (Int) -> CGFloat = { _ in 2 }) -> (value: Double, at: String, reopen: Double, whileMoving: Double) {
    let order = Dictionary(before.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let finalOrder = Dictionary(after.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let touchedAt = touched.compactMap { order[$0] }.sorted()
    func spansChange(_ a: Int, _ b: Int) -> Bool {
      guard let i = order[a], let j = order[b] else { return true }
      let (lo, hi) = (min(i, j), max(i, j))
      return touchedAt.contains { $0 > lo && $0 < hi }
    }
    var worst = 0.0
    var at = ""
    var reopen = 0.0
    var whileMoving = 0.0
    var lastGap: [String: Double] = [:]
    for frame in frames {
      // A row reaches at least its bubble's presented bottom (and gap): the row's frame pairs a presented top with
      // the settled height, short of what shows while a row shrinks.
      var extents = frame.rows
      for (id, rect) in frame.rows {
        if let bubble = frame.bubbles[id], bubble.maxY + bottomGap(id) > rect.maxY {
          extents[id] = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bubble.maxY + bottomGap(id) - rect.minY)
        }
      }
      let sorted = extents.sorted { $0.value.minY < $1.value.minY }
      // The bottom end is the row reaching lowest, and a strip is judged between the row reaching lowest so far and the
      // next one: a row that starts above another and reaches past it covers what lies between (a moved row landing on
      // its place while the row above slides off it read as a 24 pt blank in `update.fuzz`, seed 1592598566 step 37).
      guard let first = sorted.first, let last = sorted.max(by: { $0.value.maxY < $1.value.maxY }) else { continue }
      func consider(_ value: CGFloat, _ place: @autoclosure () -> String) {
        guard Double(value) > worst else { return }
        worst = Double(value)
        at = "t \(String(format: "%.3f", frame.t)) \(place())"
      }
      // The ends as the data had them before the change count too: a frame from before it (the recording's first)
      // shows the old ids (every one renumbered: the bounce's overscroll read as a 9–23 pt blank strip).
      if first.key != oldest, first.key != before.first, !touched.contains(first.key) { consider(first.value.minY - frame.usableTop, "top, first \(first.key) at \(first.value.minY)") }
      // The newest shown in this frame (arrivals still to come) counts as the end where the bottom is the end.
      let lastIsNewestShown = bottomIsEnd && (last.key == before.last || last.key == frame.rows.keys.max { (finalOrder[$0] ?? -1) < (finalOrder[$1] ?? -1) })
      if last.key != newest, !touched.contains(last.key), !lastIsNewestShown {
        consider(frame.usableBottom - last.value.maxY, "bottom, last \(last.key) ends \(last.value.maxY)")
      }
      var reaching = first
      var pairs: [(a: (key: Int, value: CGRect), b: (key: Int, value: CGRect))] = []
      for row in sorted.dropFirst() {
        pairs.append((reaching, row))
        if row.value.maxY > reaching.value.maxY { reaching = row }
      }
      for (a, b) in pairs {
        let top = max(a.value.maxY, frame.usableTop)
        let bottom = min(b.value.minY, frame.usableBottom)
        let gap = Double(bottom - top)
        if touched.contains(a.key) || touched.contains(b.key) { continue }
        if spansChange(a.key, b.key) {
          let key = "\(a.key)-\(b.key)"
          let full = Double(b.value.minY - a.value.maxY)
          // Only a gap opening counts: an overlap resolving (a moved row's slide passing off its neighbour, an arrival
          // landing) is not one (3.5–4.3 pt "reopening" in `update.reorderPending` was an overlap shrinking).
          // And only where it shows: two arrivals still rising 215 pt below the screen drifted 2 pt apart (`update.fuzz`
          // seed 2 step 8).
          let shows = b.value.minY > frame.usableTop && a.value.maxY < frame.usableBottom
          if shows, let previous = lastGap[key] { reopen = max(reopen, max(0, full) - max(0, previous)) }
          lastGap[key] = full
          if frame.flinging || frame.tracking, gap > 0 { whileMoving = max(whileMoving, gap) }
          continue
        }
        if gap > 0 { consider(CGFloat(gap), "between \(a.key) \(a.value) and \(b.key) \(b.value)") }
      }
    }
    return (worst, at, reopen, whileMoving)
  }

  /// `StickyRules.avatarError` with where the worst frame was.
  /// `groupsBefore`: the chat's groups before the change, for frames of a far jump's slide, when the change waits for
  /// the slide to end and the list still shows them (judged by the data's new groups, a reorder read 12–36 pt off).
  @MainActor func avatarWorst(
    chat: LabChat, edge: (Frame) -> CGFloat, groupsBefore: [Int: (start: Int, end: Int)] = [:]
  ) -> (error: Double, at: String) {
    var worst = 0.0
    var at = ""
    for frame in frames {
      for (id, avatar) in frame.avatars {
        // The span's top from the group's first row as shown (StickyRules walks up through rows that touch, which a
        // row mid-height-change breaks: presented positions with settled heights); minus infinity when it is not shown
        // (above the placed rows).
        guard let group = (frame.sliding ? groupsBefore[id] : nil) ?? chat.group(id), let row = frame.rows[id], avatar.maxY > frame.usableTop,
              avatar.minY < frame.usableBottom + 40
        else { continue }
        // The avatar rests on its bubble's bottom: the bubble as presented (the row's frame pairs a presented top with
        // the settled height, which mid-height-change is not where the bottom shows).
        let restBottom = frame.bubbles[id]?.maxY ?? row.maxY - LabChat.bottomGap(last: true)
        let spanTop = frame.rows[group.start].map { $0.minY + 2 } ?? -.infinity
        let maxLift = max(0, restBottom - LabChat.avatarSize - spanTop)
        let expected = restBottom - max(0, min(restBottom - edge(frame), maxLift))
        let error = Double(abs(avatar.maxY - expected))
        if error > worst {
          worst = error
          let row = frame.rows[id].map { "row \(fmt(Double($0.minY)))…\(fmt(Double($0.maxY)))" } ?? ""
          at = "t \(String(format: "%.3f", frame.t)) id \(id) shown bottom \(fmt(Double(avatar.maxY))) expected \(fmt(Double(expected))) \(row) \(frame.flinging ? "flinging" : frame.tracking ? "tracking" : "")"
        }
      }
    }
    return (worst, at)
  }

  /// The worst gap between the newest row's bottom and the usable bottom, over frames where `id` shows.
  func gapAboveComposer(_ id: Int) -> Double {
    frames.compactMap { f in f.rows[id].map { Double(f.usableBottom - $0.maxY) } }.max() ?? 0
  }
}

// MARK: - The lab

@MainActor
enum UpdateLab {
  /// The rows a change touched (left out of seam checks) and the row the check follows for speed.
  struct Touched {
    var ids: Set<Int> = []
    /// The reader (or the row that takes its place) and where its top should stay, for still motions.
    var holds: (id: Int, y: CGFloat)?
    /// Held from the composer instead: its distance to the composer's top (scrolled up, the composer moves the reader).
    var holdsFromComposer = false
    /// Rows the change reorders that were not in the chat before it (they arrive and then move within it).
    var moved: Set<Int> = []
    /// When the reorder landed, from the change's start (earlier frames show the arrivals before it).
    var movedAfter: Double = 0
    /// A row the change leaves alone, for speed spikes.
    var follow: Int?
    var skipped: String?
  }

  static func spikeLimit(_ motion: UpdateMotion) -> Double {
    switch motion {
      case .still, .pinned: 300
      case .drag: 1500
      case .fling, .jump: 600
      case .bounce: 900
    }
  }

  static func run(_ change: UpdateChange, under motion: UpdateMotion, _ b: Bench, _ c: Checks) async {
    let name = motion.rawValue
    // Start from a known place.
    if b.view.composerLines != 1 { b.view.setComposerLines(1, timing: .none) }
    switch motion {
      case .still, .drag, .fling, .jump: await b.goMiddle()
      case .pinned:
        b.list.apply(TimelineTransaction(scroll: .latest))
        await b.settle()
      case .bounce: await b.goAboveLatest(300)
    }
    await b.untilRest()

    var jumpTarget: Int?
    // Get the motion going, up to the moment the change lands.
    switch motion {
      case .still, .pinned: break
      case .drag: await b.gesture(dy: 2, count: 12, lift: false)
      case .fling:
        await b.gesture(dy: 30, count: 10)
        await b.wait(0.1)
      case .jump:
        let ids = b.chat.ids
        if let reader = b.readingRow(), let at = b.chat.index(reader) {
          jumpTarget = ids[min(ids.count - 1, at + 30)]
          b.list.apply(TimelineTransaction(scroll: .to(jumpTarget!, .top(150)), timing: .standard))
          await b.wait(0.08)
        }
      case .bounce:
        await b.gesture(dy: -40, count: 10)
        for _ in 0 ..< 120 {
          await b.frames(1)
          if Double(b.usableBottom - (b.shown(b.newest)?.maxY ?? b.usableBottom)) > 6 { break }
        }
    }

    var touched = Touched()
    let before = b.chat.ids
    var groupsBefore: [Int: (start: Int, end: Int)] = [:]
    for id in before { if let group = b.chat.group(id) { groupsBefore[id] = group } }
    // The reader is the engine's own: the lowest visible row (`TimelineSolver`), even a sliver at the bottom.
    let reader = b.anchorRow() ?? b.readingRow()
    let readerY = reader.flatMap { b.shown($0)?.minY }
    let run = await b.watch {
      touched = await apply(change, b, reader: reader, readerY: readerY, motion: motion)
      if motion == .drag {
        await b.gesture(dy: 2, count: 12, lift: false, touch: false)
        b.send(Synth.trackpad(0, phase: .ended))
      }
    }
    if let skipped = touched.skipped {
      c.note("\(name): skipped, \(skipped)")
      return
    }
    let r = run.recording
    let ids = b.chat.ids
    // Gaps are judged apart only where a row left or moved; a row that grew or shrank keeps its neighbours touching.
    let afterIndex = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let beforeIndex = Dictionary(before.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let leftOrMoved = touched.ids.filter { id in
      guard let now = afterIndex[id] else { return true }
      guard let then = beforeIndex[id] else { return false }
      let neighboursThen = (then > 0 ? before[then - 1] : nil, then + 1 < before.count ? before[then + 1] : nil)
      let neighboursNow = (now > 0 ? ids[now - 1] : nil, now + 1 < ids.count ? ids[now + 1] : nil)
      return neighboursThen != neighboursNow && touched.ids.count > 1
    }.union(touched.moved)
    // Seams between neighbours as shown, leaving out rows that left, moved or arrived (a reorder's slide passes over
    // its neighbour; an arrival rises from below with a gap, as Telegram's does). A row the change grew or shrank in
    // place keeps both its seams (it was left out, and its neighbours paired across it: its own height read as a gap).
    var leaving: Set<Int> = []
    for frame in r.frames { for id in frame.rows.keys where !ids.contains(id) { leaving.insert(id) } }
    let seams = r.bubbleSeams(
      excluding: leaving.union(leftOrMoved).union(touched.ids.subtracting(before)), acrossExcluded: false
    )
    c.atMost("\(name): bubbles overlapping", seams.overlap, 0.5)
    c.atMost("\(name): space between bubbles opening up", seams.gapExcess, 0.5)
    // Past the newest end (a bounce) the space below the newest is the overscroll, not a blank strip.
    let blank = r.blankOutsideChanges(
      oldest: ids[0], newest: ids[ids.count - 1], before: before, after: ids, touched: Set(leftOrMoved),
      bottomIsEnd: motion == .bounce || motion == .pinned, bottomGap: { LabChat.bottomGap(last: b.chat.isLastInGroup($0)) }
    )
    let blankLimit: Double = (change == .insetWithDelete || change == .insetWithArrival) && motion == .jump ? 1.5 : 0.5
    c.atMost("\(name): blank strip", blank.value, blankLimit)
    if blank.value > blankLimit { c.note("\(name): blank \(fmt(blank.value)) at \(blank.at)") }
    // A reorder is a delete and an insert: the moved row lands at its new place fading in, and its old place keeps a
    // picture of it fading out while the neighbours close over it (the gaps next to moved rows are judged apart above).
    // Without the picture the old place showed blank: 50–81 pt in `reorderAdjacent`, 22–25 pt in `reorderPending`.
    if change == .reorderPending || change == .reorderAdjacent {
      // The largest stretch of the usable area nothing covers (rows overlap mid-move: their union, with the pictures),
      // worst frame.
      var worst = 0.0
      var at = ""
      // The gap above a row still arriving (or its picture) is the arrival's rise, not a vacated place (the incoming
      // message in `reorderPending` was still rising when the reorder came).
      let arriving = touched.ids.subtracting(before)
      for frame in r.frames.dropFirst() where frame.t >= touched.movedAfter {
        let spans = (frame.rows.map { ($0.key, $0.value) } + frame.ghosts.map { ($0.id, $0.frame) })
          .map { (id: $0.0, top: max($0.1.minY, frame.usableTop), bottom: min($0.1.maxY, frame.usableBottom)) }
          .filter { $0.bottom > $0.top }.sorted { $0.top < $1.top }
        var reach = frame.usableTop
        for span in spans {
          if !arriving.contains(span.id), Double(span.top - reach) > worst { worst = Double(span.top - reach); at = "t \(String(format: "%.3f", frame.t)) at \(fmt(Double(reach)))" }
          reach = max(reach, span.bottom)
        }
        if motion != .bounce, Double(frame.usableBottom - reach) > worst { worst = Double(frame.usableBottom - reach); at = "t \(String(format: "%.3f", frame.t)) at the bottom \(fmt(Double(reach)))" }
      }
      c.atMost("\(name): the moved rows' old places uncovered, worst frame", worst, 0.5)
      if worst > 0.5 { c.note("\(name): uncovered \(fmt(worst)) pt at \(at)") }
    }
    c.atMost("\(name): a removed row's gap reopening", blank.reopen, 0.5)
    if blank.whileMoving > 0.5 { c.note("\(name): a removed or moved row's closing gap showed \(fmt(blank.whileMoving)) pt on screen while the list moved") }
    c.atMost("\(name): frames a row showed undrawn (longest run)", Double(run.undrawnFrames), 1, unit: "")
    let header = StickyRules.headerError(r, chat: b.chat)
    c.atMost("\(name): floating date position error", header.position, 0.75)
    c.atMost("\(name): floating date shown or hidden wrongly (frames)", Double(header.wrongVisibility), 2, unit: "")
    if header.wrongVisibility > 2 {
      var wrong: [String] = []
      for frame in r.frames {
        if frame.header != nil, frame.headerAlpha < 0.01 { continue }
        let expected = StickyRules.expectedHeader(in: frame, chat: b.chat)
        if (expected == nil) != (frame.header == nil), wrong.count < 6 {
          let tops = frame.rows.sorted { $0.value.minY < $1.value.minY }.filter { $0.value.maxY > frame.usableTop }.prefix(2)
            .map { "\($0.key)\(b.chat.row($0.key)?.isDay == true ? "D" : "")@\(fmt(Double($0.value.minY)))" }.joined(separator: " ")
          wrong.append(String(format: "t %.3f", frame.t) + " expected \(expected.map { "\(fmt(Double($0.y))) \($0.title)" } ?? "hidden") shown \(frame.header.map { "\(fmt(Double($0.minY))) \(frame.headerTitle ?? "")" } ?? "hidden") alpha \(fmt(Double(frame.headerAlpha))) tops \(tops)")
        }
      }
      c.note("\(name): floating date wrong at " + wrong.joined(separator: " | "))
    }
    // From the first frame after the change: the first is recorded before it lands, and the chat's groups are after.
    // A group whose first row the change removed: its avatar eases to the group's new top on the change's spring while
    // the removed row fades in place, so it is judged once the removal has settled (0.5 s), not against an instant
    // snap the recorded frames suggest (the fading row is not in them): `update.deleteReader`, 14.5 pt mid-ease.
    let removed = Set(before).subtracting(ids)
    let beforeAt = Dictionary(before.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    let regrouped: (Int) -> Bool = { id in
      guard let start = b.chat.group(id)?.start, let at = beforeAt[start], at > 0 else { return false }
      return removed.contains(before[at - 1])
    }
    let settledAfterRemoval = (r.frames.first?.t ?? 0) + 0.5
    let avatars = Recording(frames: Array(r.frames.dropFirst()).map { frame in
      var frame = frame
      if frame.t < settledAfterRemoval { frame.avatars = frame.avatars.filter { !regrouped($0.key) } }
      return frame
    }).avatarWorst(chat: b.chat, edge: SuiteCases.avatarEdge(b), groupsBefore: groupsBefore)
    // Tolerances, from measurements (2026-11-27), each with its reason:
    // - bounce with the newest streaming: 1.5 pt. The lift is baked on the fling's samples; on a fast bounce, linear
    //   interpolation between them is off by up to 1.2 pt (was 4.8–23 pt before the single bake).
    // - an inset change during a far jump's slide: 4 pt avatar, 1.5 pt blank. The composer's spring and the slide's
    //   strips meet the moving edge at slightly different times (measured 3.2 and 1.2 pt; 28–31 pt before).
    let avatarLimit: Double = switch (change, motion) {
      case (.streamNewest, .bounce): 1.5
      case (.insetWithDelete, .jump), (.insetWithArrival, .jump): 4
      default: 1
    }
    c.atMost("\(name): avatar error, worst frame", avatars.error, avatarLimit)
    if avatars.error > avatarLimit { c.note("\(name): avatar \(avatars.at)") }
    // The original rule (span walked up through touching rows, rest from the row's frame): with presented heights it
    // reads rows mid height change right; noted to compare with the bubble-based check above.
    let walked = StickyRules.avatarError(Recording(frames: Array(r.frames.dropFirst())), chat: b.chat, edge: SuiteCases.avatarEdge(b))
    if abs(walked.error - avatars.error) > 1 { c.note("\(name): avatar by row frames \(fmt(walked.error)) pt vs by bubbles \(fmt(avatars.error)) pt") }
    // At rest, what shows is what is settled: no animation left an offset behind.
    var stuck = 0.0
    for (id, _) in b.list.placedViews {
      guard let shown = b.shown(id), let settled = b.settled(id) else { continue }
      stuck = max(stuck, Double(abs(shown.minY - settled.minY)))
    }
    c.atMost("\(name): at rest, shown − settled", stuck, 0.5)

    switch motion {
      case .still:
        if let holds = touched.holds {
          if change == .reloadRenumbered {
            // No id survives and no target was given: the engine cannot know the place. A host that renumbers passes
            // a target (`reloadRenumberedTargeted`); the shell's ids are stable message ids.
            c.note("\(name): untargeted renumber, reader's content moved \(fmt(min(9999, r.deviation(holds.id, from: Double(holds.y))))) pt (expected: no id survives)")
          } else if touched.holdsFromComposer {
            c.atMost("\(name): reader's distance to the composer drift", r.distanceToComposerDeviation(holds.id), 0.5)
          } else {
            c.atMost("\(name): reader drift", min(9999, r.deviation(holds.id, from: Double(holds.y))), 0.5)
          }
        }
      case .pinned, .bounce:
        let newest = b.newest
        if motion == .pinned, !touched.ids.contains(newest) || change == .streamNewest {
          c.atMost("\(name): gap above the composer, worst frame", r.gapAboveComposer(newest), 0.5)
        }
        c.that("\(name): pinned at rest", b.isPinned)
        c.near("\(name): rest, newest bottom − usable bottom", Double((b.shown(newest)?.maxY ?? 0) - b.usableBottom), 0, within: 0.5)
      case .drag, .fling, .jump:
        break
    }
    if let follow = touched.follow, motion != .still {
      c.atMost("\(name): speed spike on a row the change left alone", r.speedSpike(follow), spikeLimit(motion), unit: "pt/s")
    }
    if motion == .jump, change != .insetWithArrival, let target = jumpTarget, ids.contains(target), !touched.ids.contains(target) {
      c.near("\(name): jump lands on its target (top − usable top)", Double((b.shown(target)?.minY ?? 0) - b.usableTop), 150, within: 0.5)
    }
  }

  /// Applies the change now (some changes take a while: streaming). Returns what it touched.
  static func apply(_ change: UpdateChange, _ b: Bench, reader: Int?, readerY: CGFloat?, motion: UpdateMotion) async -> Touched {
    var t = Touched()
    let holdsReader: (Int, CGFloat)? = reader.flatMap { r in readerY.map { (r, $0) } }
    t.holds = holdsReader.map { (id: $0.0, y: $0.1) }
    t.follow = reader ?? b.messageRows.last?.id
    func grow(_ id: Int, by words: Int = 24) {
      b.setText(id, (b.chat.row(id)?.text ?? "") + String(repeating: " grown", count: words))
    }
    switch change {
      case .none:
        break

      case .streamNewest:
        let id = b.newest
        t.ids = [id]
        if t.follow == id { t.follow = b.messageRows.dropLast().last?.id }
        for i in 0 ..< 10 {
          b.setText(id, (b.chat.row(id)?.text ?? "") + " streamed words \(i) that wrap", timing: .streamingLine)
          await b.wait(0.06)
        }

      case .streamAbove:
        guard let id = b.rowAboveScreen() else { t.skipped = "no row above the screen"; return t }
        t.ids = [id]
        for i in 0 ..< 10 {
          b.setText(id, (b.chat.row(id)?.text ?? "") + " streamed words \(i) that wrap", timing: .streamingLine)
          await b.wait(0.06)
        }

      case .streamBelow:
        guard let id = b.rowBelowScreen() else { t.skipped = "no row below the screen"; return t }
        t.ids = [id]
        for i in 0 ..< 10 {
          b.setText(id, (b.chat.row(id)?.text ?? "") + " streamed words \(i) that wrap", timing: .streamingLine)
          await b.wait(0.06)
        }

      case .growAbove:
        guard let id = b.rowAboveScreen() else { t.skipped = "no row above the screen"; return t }
        t.ids = [id]
        grow(id)

      case .shrinkAbove:
        guard let id = b.rowAboveScreen() else { t.skipped = "no row above the screen"; return t }
        t.ids = [id]
        b.setText(id, "short")

      case .growVisible:
        guard let id = b.rowVisible(above: reader) else { t.skipped = "no row on screen above the reader"; return t }
        t.ids = [id]
        grow(id)

      case .growReader:
        guard let id = reader ?? b.messageRows.last?.id else { t.skipped = "no reader"; return t }
        t.ids = [id]
        t.follow = b.rowVisible(above: id)
        grow(id)

      case .growBelow:
        guard let id = b.rowBelowScreen() else { t.skipped = "no row below the screen"; return t }
        t.ids = [id]
        grow(id)

      case .deleteReader:
        guard let id = reader ?? b.messageRows.dropLast().last?.id, let at = b.chat.index(id), at + 1 < b.chat.ids.count
        else { t.skipped = "no reader"; return t }
        let newer = b.chat.ids[at + 1]
        t.ids = [id]
        t.holds = b.shown(newer).map { (id: newer, y: $0.minY) }
        t.follow = newer
        b.delete(id)

      case .deleteVisible:
        guard let id = b.rowVisible(above: reader) else { t.skipped = "no row on screen above the reader"; return t }
        t.ids = [id]
        b.delete(id)

      case .deleteAbove:
        guard let id = b.rowAboveScreen() else { t.skipped = "no row above the screen"; return t }
        t.ids = [id]
        b.delete(id)

      case .deleteUnderPointer:
        guard let id = b.rowUnderPointer(), let at = b.chat.index(id), at + 1 < b.chat.ids.count
        else { t.skipped = "no message under the pointer"; return t }
        t.ids = [id]
        if id == reader {
          let newer = b.chat.ids[at + 1]
          t.holds = b.shown(newer).map { (id: newer, y: $0.minY) }
          t.follow = newer
        }
        b.delete(id)

      case .reorderPending:
        // A pending message of mine at the newest end, then an incoming one below it; the pending one is confirmed
        // after the incoming one: it moves down past it.
        let began = CACurrentMediaTime()
        let pending = b.arrive("my pending message, sent just now", sender: 0)
        await b.wait(0.05)
        let incoming = b.arrive("an incoming message that came in meanwhile", sender: 2)
        await b.wait(0.12)
        t.ids = [pending, incoming]
        t.moved = [pending, incoming]
        t.movedAfter = CACurrentMediaTime() - began
        t.follow = b.messageRows.dropLast(3).last?.id
        b.chat.move(pending, toIndex: b.chat.ids.count)
        b.list.apply(TimelineTransaction(rows: b.chat.ids, timing: .standard))

      case .reorderAdjacent:
        guard let a = b.rowVisible(above: reader), let at = b.chat.index(a), at > 1,
              b.chat.row(b.chat.ids[at - 1])?.isDay == false
        else { t.skipped = "no two neighbours on screen above the reader"; return t }
        let earlier = b.chat.ids[at - 1]
        t.ids = [a, earlier]
        b.chat.move(a, toIndex: at - 1)
        b.list.apply(TimelineTransaction(rows: b.chat.ids, timing: .standard))

      case .reloadSame:
        let placed = Set(b.list.placedViews.map(\.0))
        b.list.apply(TimelineTransaction(rows: b.chat.ids, changed: placed))

      case .reloadShifted:
        // The window slides: the oldest rows go and newer history lands, in one update (not arrivals).
        b.chat.trimOldest(30)
        _ = b.chat.appendPage(30)
        b.list.apply(TimelineTransaction(rows: b.chat.ids, arrives: false))

      case .reloadRenumbered, .reloadRenumberedTargeted:
        let map = b.chat.renumber()
        t.holds = holdsReader.flatMap { r in map[r.0].map { (id: $0, y: r.1) } }
        t.follow = t.holds?.id ?? b.messageRows.last.flatMap { map[$0.id] }
        if change == .reloadRenumberedTargeted, let holds = t.holds, motion == .still {
          b.list.apply(TimelineTransaction(rows: b.chat.ids, scroll: .to(holds.id, .top(holds.y - b.usableTop)), arrives: false))
        } else if change == .reloadRenumberedTargeted, motion == .pinned || motion == .bounce {
          b.list.apply(TimelineTransaction(rows: b.chat.ids, scroll: .latest, arrives: false))
        } else {
          b.list.apply(TimelineTransaction(rows: b.chat.ids, arrives: false))
        }
        // The old ids are gone: the speed check follows the new one, from the first frame it shows.

      case .batch:
        let above = b.rowAboveScreen()
        let visible = b.rowVisible(above: reader)
        let nearNewest = b.chat.ids.count > 3 ? b.chat.ids[b.chat.ids.count - 2] : nil
        _ = b.chat.prepend(40)
        if let above { b.chat.delete(above) }
        if let visible { b.chat.setText(visible, (b.chat.row(visible)?.text ?? "") + String(repeating: " grown", count: 24)) }
        let arrival = b.chat.append("an arrival in the same update", sender: 2)
        if let nearNewest, nearNewest != reader { b.chat.delete(nearNewest) }
        t.ids = Set([above, visible, nearNewest, arrival].compactMap { $0 })
        if t.follow.map({ t.ids.contains($0) }) ?? false { t.follow = nil }
        b.list.apply(TimelineTransaction(rows: b.chat.ids, changed: visible.map { [$0] } ?? [], timing: .standard))

      case .insetWithArrival:
        b.view.setComposerLines(3, timing: .none)
        await b.untilRest()
        t.holds = reader.flatMap { r in b.shown(r).map { (id: r, y: $0.minY) } }
        t.holdsFromComposer = true
        let id = b.chat.append("my sent message, landing as the composer shrinks", sender: 0)
        t.ids = [id]
        b.view.setComposerLines(1, timing: .standard, rows: b.chat.ids, changed: [])

      case .insetWithDelete:
        guard let id = b.rowAboveScreen() ?? b.rowVisible(above: reader) else { t.skipped = "no row above"; return t }
        t.ids = [id]
        t.holdsFromComposer = true
        b.chat.delete(id)
        b.view.setComposerLines(4, timing: .standard, rows: b.chat.ids, changed: [])

      case .widthDuringGrow:
        guard let id = b.rowVisible(above: reader) ?? b.messageRows.dropLast().last?.id else { t.skipped = "no row"; return t }
        t.ids = [id]
        let width = b.window.frame.width
        grow(id)
        await b.wait(0.05)
        // A rewrap moves every row but the anchor (as at rest, and as NSScrollView and Telegram do, unanimated): the
        // speed check follows the anchor of the moment.
        if case let .row(anchor, _) = b.list.position { t.follow = anchor }
        b.resize(width: width - 60)
        await b.wait(0.1)
        b.resize(width: width)
        // Rows rewrap: every row's height may change twice; the reader's top still holds (bottom-first).
    }
    return t
  }
}

// MARK: - Cases

extension SuiteCases {
  static var updates: [BehaviourCase] {
    UpdateChange.allCases.map { change in
      BehaviourCase(
        id: "update.\(change.rawValue)", area: "Updates under motion", behaviour: change.behaviour,
        options: Bench.Options(count: 800)
      ) { b, c in
        for motion in UpdateMotion.allCases where change.applies(to: motion) {
          await UpdateLab.run(change, under: motion, b, c)
        }
      }
    } + [fuzz, streamRapidPinned, readingAnchorAB]
  }

  /// Which row a layout should anchor on (coordinator, 2026-11-27): the lowest visible row (a sliver included) against
  /// the lowest showing at least min(its height, 44 pt), or half of itself. A row R fully shown with the next row S
  /// showing a sliver below it; R grows (an edit, a stream), S grows, or a row above R grows. Drift of R's and S's tops,
  /// worst frame, for slivers of 5–60 pt.
  static var readingAnchorAB: BehaviourCase {
    BehaviourCase(
      id: "update.readingAnchorAB", area: "Updates under motion",
      behaviour: "A/B of the reading anchor: with the next row showing a sliver below the row being read, growing the read row keeps its top under the chosen rule; rows below grow downward (bottom-first) under every rule",
      options: Bench.Options(count: 400)
    ) { b, c in
      let rules: [(String, TimelineReadingAnchor)] = [("lowest visible", .lowestVisible), ("44 pt", .lowestShowing(44)), ("half", .lowestShowingHalf)]
      for (ruleName, rule) in rules {
        b.list.readingAnchor = rule
        var readDrift = 0.0
        var belowKeepsRead = 0.0
        var aboveKeepsRead = 0.0
        var run = 0
        for sliver: CGFloat in [5, 15, 30, 43, 60] {
          for change in ["edit read", "stream read", "grow below", "grow above"] {
            // A fresh stretch of the chat each time (earlier runs grew their rows).
            run += 1
            let ids = b.chat.ids
            let start = ids[min(ids.count - 1, 20 + (run + rules.firstIndex(where: { $0.0 == ruleName })! * 20) * 9 % (ids.count - 60))]
            b.list.apply(TimelineTransaction(scroll: .to(start, .top(100))))
            await b.untilRest()
            // R and S: neighbouring messages (same chat order), S taller than the sliver, R shorter than the screen.
            let rows = b.messageRows
            guard let at = rows.indices.first(where: { i in
              i > 2 && i + 1 < rows.count && rows[i].y > b.usableTop + 150 && rows[i + 1].height > sliver + 8
                && rows[i].height < 200 && b.chat.index(rows[i + 1].id) == b.chat.index(rows[i].id).map { $0 + 1 }
            }) else {
              c.note("\(ruleName), sliver \(Int(sliver)) pt, \(change): skipped, no pair")
              continue
            }
            let read = rows[at].id
            let below = rows[at + 1].id
            let above = rows[at - 2].id
            b.list.apply(TimelineTransaction(scroll: .to(below, .top(b.usableBottom - b.usableTop - sliver))))
            await b.untilRest()
            guard let readTop = b.shown(read)?.minY, let belowTop = b.shown(below)?.minY else {
              c.note("\(ruleName), sliver \(Int(sliver)) pt, \(change): skipped, rows not shown")
              continue
            }
            c.note("\(ruleName), sliver \(Int(sliver)) pt, \(change): anchor \(b.list.position) read \(read) below \(below)")
            let r = await b.record {
              switch change {
                case "edit read":
                  b.setText(read, (b.chat.row(read)?.text ?? "") + String(repeating: " grown", count: 24))
                case "stream read":
                  for i in 0 ..< 8 {
                    b.setText(read, (b.chat.row(read)?.text ?? "") + " streamed words \(i) that wrap", timing: .streamingLine)
                    await b.wait(0.06)
                  }
                case "grow below":
                  b.setText(below, (b.chat.row(below)?.text ?? "") + String(repeating: " grown", count: 24))
                default:
                  b.setText(above, (b.chat.row(above)?.text ?? "") + String(repeating: " grown", count: 24))
              }
            }
            let rd = min(9999, r.deviation(read, from: Double(readTop)))
            let bd = min(9999, r.deviation(below, from: Double(belowTop)))
            switch change {
              case "edit read", "stream read": readDrift = max(readDrift, rd)
              case "grow below": belowKeepsRead = max(belowKeepsRead, rd)
              default: aboveKeepsRead = max(aboveKeepsRead, rd)
            }
            c.note("\(ruleName), sliver \(Int(sliver)) pt, \(change): read row drift \(fmt(rd)) pt, row below \(fmt(bd)) pt")
          }
        }
        c.note("\(ruleName): read row grows → its drift \(fmt(readDrift)) pt; a row below grows → read row \(fmt(belowKeepsRead)) pt; a row above grows → read row \(fmt(aboveKeepsRead)) pt")
        c.atMost("\(ruleName): a row below the read row grows: the read row stays (bottom-first)", belowKeepsRead, 0.5)
        c.atMost("\(ruleName): a row above the read row grows: the read row stays", aboveKeepsRead, 0.5)
      }
      b.list.readingAnchor = .lowestShowing(44)
    }
  }

  /// The harness's `stream` scenario on real rows (Inline Debug, 50 growing edits 60 ms apart, pinned): the newest
  /// row's bottom moved up to 28 pt during the height animations. Here: what shows (the bubble's bottom) against the
  /// row's presented frame (presented top + settled height, what the harness measured), with a host that animates its
  /// insides on the change's timing and one that lays them out at once, on `.standard` (the shell's timing for edits)
  /// and `.streamingLine`, edits 60 ms apart (the next lands mid-animation).
  static var streamRapidPinned: BehaviourCase {
    BehaviourCase(
      id: "update.streamRapidPinned", area: "Updates under motion",
      behaviour: "Pinned, the newest message streams 30 growing edits 60 ms apart: its bubble's bottom stays on the usable bottom every frame (the row grows upward)",
      options: Bench.Options(count: 300)
    ) { b, c in
      for (name, timing, insides) in [
        ("standard, host animates", TimelineTiming.standard, true), ("streamingLine, host animates", .streamingLine, true),
        ("standard, host lays out at once", .standard, false), ("streamingLine, host lays out at once", .streamingLine, false),
      ] {
        b.chat.animatesInsides = insides
        b.list.apply(TimelineTransaction(scroll: .latest))
        let id = b.arrive("a streamed reply", sender: 2)
        await b.untilRest()
        let rest = b.usableBottom - LabChat.bottomGap(last: true)
        let r = await b.record {
          for i in 0 ..< 30 {
            // Every other edit adds a line; the rest only words (no height change), as tokens do.
            let words = i % 2 == 0 ? " and a few more streamed words to wrap onto the next line \(i)" : " tok\(i)"
            b.setText(id, (b.chat.row(id)?.text ?? "") + words, timing: timing)
            await b.wait(0.06)
          }
        }
        let bubbleError = r.frames.compactMap { f in f.bubbles[id].map { Double(abs($0.maxY - rest)) } }.max() ?? .infinity
        let rowError = r.frames.compactMap { f in f.rows[id].map { Double(abs($0.maxY - LabChat.bottomGap(last: true) - rest)) } }.max() ?? .infinity
        if insides {
          c.atMost("\(name): bubble bottom off the usable bottom, worst frame", min(9999, bubbleError), 0.5)
        } else {
          // A host the lab cannot fix: what a message view laying itself out at once shows (the harness's 28 pt).
          c.note("\(name): bubble bottom off the usable bottom by up to \(fmt(min(9999, bubbleError))) pt")
        }
        c.note("\(name): row frame bottom (presented top + settled height) off by up to \(fmt(rowError)) pt")
        c.that("\(name): pinned at rest", b.isPinned)
      }
      b.chat.animatesInsides = true
    }
  }

  static var fuzz: BehaviourCase {
    BehaviourCase(
      id: "update.fuzz", area: "Updates under motion",
      behaviour: "Seeded random changes interleaved with random motions: after every step the settled layout is contiguous, ordered and covers the screen; every frame shows no blank strip and no row undrawn for two frames; at rest nothing is left offset",
      options: Bench.Options(count: 600)
    ) { b, c in
      let env = ProcessInfo.processInfo.environment
      let seed = env["TL_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x5EED_2026
      let steps = env["TL_FUZZ_STEPS"].flatMap { Int($0) } ?? 40
      var rng = SplitMix(seed: seed)
      func pick(_ n: Int) -> Int { Int(rng.next() % UInt64(max(1, n))) }
      var log: [String] = []
      var failures: [String] = []
      var worstBlank = 0.0
      var worstUndrawn = 0
      var worstStuck = 0.0
      var worstLayout = 0.0
      var outOfOrder = 0
      var neverRested = 0
      var readerDrift = 0.0
      var worstReopen = 0.0

      for step in 0 ..< steps {
        let motion = pick(6)
        let changes = 1 + pick(3)
        var actions: [String] = []
        let reader = b.readingRow()
        let readerY = reader.flatMap { b.shown($0)?.minY }
        let wasStillInHistory = motion == 0 && !b.isPinned
        var touchedReader = false
        let stepBefore = b.chat.ids
        var leftOrMoved: Set<Int> = []
        let run = await b.watch {
          switch motion {
            case 1:
              actions.append("fling \(pick(2) == 0 ? "older" : "newer")")
              await b.gesture(dy: actions.last!.hasSuffix("older") ? 30 : -30, count: 8)
            case 2:
              actions.append("drag")
              await b.gesture(dy: Double(pick(5)) - 2, count: 10, lift: false)
            case 3:
              let ids = b.chat.ids
              let target = ids[pick(ids.count)]
              actions.append("jump \(target)")
              b.list.apply(TimelineTransaction(scroll: .to(target, .top(CGFloat(pick(300)))), timing: pick(2) == 0 ? .standard : .none))
            case 4:
              actions.append("latest")
              b.list.apply(TimelineTransaction(scroll: .latest, timing: .standard))
            case 5:
              actions.append("wheel")
              b.wheel(lines: Int32(pick(9)) - 4)
            default:
              actions.append("still")
          }
          await b.wait(Double(pick(150)) / 1000)
          for _ in 0 ..< changes {
            let placed = b.messageRows.map(\.id)
            let ids = b.chat.ids
            guard !placed.isEmpty, ids.count > 20 else { break }
            let any = placed[pick(placed.count)]
            if any == reader { touchedReader = true }
            switch pick(11) {
              case 0:
                b.setText(any, (b.chat.row(any)?.text ?? "") + String(repeating: " grown", count: 1 + pick(30)), timing: pick(2) == 0 ? .standard : .streamingLine)
                actions.append("grow \(any)")
              case 1:
                b.setText(any, "short", timing: .standard)
                actions.append("shrink \(any)")
              case 2:
                b.delete(any)
                leftOrMoved.insert(any)
                actions.append("delete \(any)")
              case 3:
                _ = b.arrive(nil, sender: pick(3))
                actions.append("arrive")
              case 4:
                b.prependPage(20 + pick(40))
                actions.append("page above")
              case 5:
                let at = b.chat.index(any) ?? 0
                let to = max(1, min(ids.count - 1, at + pick(5) - 2))
                b.chat.move(any, toIndex: to)
                leftOrMoved.insert(any)
                b.list.apply(TimelineTransaction(rows: b.chat.ids, timing: .standard))
                actions.append("move \(any) → \(to)")
                touchedReader = true
              case 6:
                let trim = 10 + pick(20)
                leftOrMoved.formUnion(b.chat.ids.prefix(trim))
                b.chat.trimOldest(trim)
                _ = b.chat.appendPage(10 + pick(20))
                b.list.apply(TimelineTransaction(rows: b.chat.ids, arrives: false))
                actions.append("shift window")
                touchedReader = true
              case 7:
                let lines = 1 + pick(4)
                b.view.setComposerLines(lines, timing: .standard, rows: b.chat.ids, changed: [])
                actions.append("composer \(lines)")
                touchedReader = true
              case 8:
                let width = CGFloat(420 + pick(200))
                b.resize(width: width)
                actions.append("width \(Int(width))")
                touchedReader = true
              case 9:
                let id = b.newest
                for i in 0 ..< 3 + pick(5) {
                  b.setText(id, (b.chat.row(id)?.text ?? "") + " stream \(i)", timing: .streamingLine)
                  await b.wait(0.04)
                }
                actions.append("stream newest")
              default:
                let batch = placed.shuffled(using: &rng).prefix(3)
                for id in batch { b.chat.setText(id, (b.chat.row(id)?.text ?? "") + " batch") }
                if let victim = placed.first(where: { !batch.contains($0) }) {
                  b.chat.delete(victim)
                  leftOrMoved.insert(victim)
                  if victim == reader { touchedReader = true }
                }
                _ = b.chat.append("batched arrival", sender: 1)
                b.list.apply(TimelineTransaction(rows: b.chat.ids, changed: Set(batch), timing: .standard))
                actions.append("batch")
                if batch.contains(where: { $0 == reader }) { touchedReader = true }
            }
            await b.wait(Double(pick(120)) / 1000)
          }
          if motion == 2 { b.send(Synth.trackpad(0, phase: .ended)) }
        }
        log.append("step \(step): \(actions.joined(separator: ", "))")
        // An idle fade can start between the rest and this check (the scroll indicator hides 0.8 s after a rest; seed
        // 1592598566 step 4 rested in 0.45 s, then its indicator from the step before began fading): wait for rest
        // again before calling it a step that never rests.
        if !b.isStill() { await b.untilRest() }
        if !b.isStill() {
          neverRested += 1
          // What still moves: the list's motion, rows lingering, and every layer with animations (keys).
          var animating: [String] = []
          func walk(_ layer: CALayer, _ path: String) {
            if !layer.isHidden, let keys = layer.animationKeys(), !keys.isEmpty {
              let now = layer.convertTime(CACurrentMediaTime(), from: nil)
              let durations = keys.compactMap { layer.animation(forKey: $0) }.map {
                String(format: "%.2f begin %.3f now %.3f speed %.1f removes %d fill %@ alpha %.2f", $0.duration, $0.beginTime, now, $0.speed, $0.isRemovedOnCompletion ? 1 : 0, $0.fillMode.rawValue, layer.opacity)
              }
              animating.append("\(path)[\(keys.joined(separator: ","))|\(durations.joined(separator: ","))]")
            }
            for (i, sub) in (layer.sublayers ?? []).enumerated() where animating.count < 12 { walk(sub, path + "/\(i)") }
          }
          if let layer = b.list.layer { walk(layer, "list") }
          let d = b.list.diagnostics
          let layout = b.list.timelineLayout
          let performs = d.performCount
          let layouts = d.layoutPasses
          var flights = 0
          for _ in 0 ..< 75 {
            await b.frames(1)
            if b.list.diagnostics.isFlinging { flights += 1 }
          }
          // When the content and rows last moved in the step's recording, and how long the step ran.
          let frames = run.recording.frames
          var lastMove = 0.0
          var moves: [String] = []
          for (a, z) in zip(frames, frames.dropFirst()) {
            let moved = z.rows.contains { id, rect in a.rows[id].map { abs($0.minY - rect.minY) > 0.01 } ?? false }
            if moved || abs(z.origin - a.origin) > 0.01 {
              lastMove = z.t
              if moves.count < 40, Int(z.t * 10) != Int(a.t * 10) { moves.append(String(format: "%.1f%@", z.t, z.flinging ? "f" : "")) }
            }
          }
          failures.append("step \(step): recorded \(String(format: "%.2f", run.recording.duration)) s, last move at \(String(format: "%.2f", lastMove)) s; moving at " + moves.joined(separator: " "))
          if let indicator = b.list.layer?.sublayers?.dropFirst(2).first {
            var begins: [String] = []
            for _ in 0 ..< 10 {
              await b.frames(1)
              if let a = indicator.animation(forKey: "opacity") as? CABasicAnimation {
                begins.append(String(format: "%.3f %@→%@ %@", a.beginTime, String(describing: a.fromValue ?? "nil"), String(describing: a.toValue ?? "nil"), String(describing: type(of: indicator.delegate as Any))))
              }
            }
            failures.append("step \(step) sublayer 2 opacity over 10 frames: " + begins.joined(separator: " | "))
          }
          failures.append("step \(step) layout: restShift \(fmt(Double(layout.restShift))) toOldest \(layout.distanceToOldest.map { fmt(Double($0)) } ?? "-") toNewest \(layout.distanceToNewest.map { fmt(Double($0)) } ?? "-") position \(b.list.position); in the next second \(b.list.diagnostics.performCount - performs) performs, \(b.list.diagnostics.layoutPasses - layouts) layout passes, \(flights) frames flinging")
          failures.append("step \(step) never rested: moving \(b.list.isMoving) flinging \(d.isFlinging) tracking \(d.isTracking) lingering \(d.lingeringCount); animating \(animating.prefix(8).joined(separator: " "))")
        }

        // Presentation invariants over the step's frames.
        let ids = b.chat.ids
        let blank = run.recording.blankOutsideChanges(
          oldest: ids[0], newest: ids[ids.count - 1], before: stepBefore, after: ids, touched: leftOrMoved, bottomIsEnd: true,
          bottomGap: { LabChat.bottomGap(last: b.chat.isLastInGroup($0)) }
        )
        // A width change rewraps every row in one frame (as at rest, as NSScrollView and Telegram do), moving rows by
        // their own height changes: gaps and blanks are not judged in such a step (seed 1592598566 step 3: a move, a
        // shifted window and a width change, 20.6 pt "reopening" from the rewrap).
        let rewraps = actions.contains { $0.hasPrefix("width") }
        if !rewraps {
          if blank.value > 0.5 { failures.append("step \(step): blank \(fmt(blank.value)) at \(blank.at)") }
          if blank.reopen > 0.5 { failures.append("step \(step): a removed row's gap reopened by \(fmt(blank.reopen))") }
          worstReopen = max(worstReopen, blank.reopen)
        }
        if !rewraps { worstBlank = max(worstBlank, blank.value) }
        worstUndrawn = max(worstUndrawn, run.undrawnFrames)
        if run.undrawnFrames > 1 { failures.append("step \(step): row \(run.undrawnRow ?? -1) undrawn \(run.undrawnFrames) frames") }

        // Structural invariants at rest.
        let layout = b.list.timelineLayout
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var previous: TimelinePlacement<Int>?
        for placement in layout.placements {
          guard let at = index[placement.id] else { failures.append("step \(step): placed \(placement.id) is not in the data"); outOfOrder += 1; continue }
          if let previous {
            if index[previous.id].map({ $0 + 1 != at }) ?? true { outOfOrder += 1; failures.append("step \(step): \(previous.id) then \(placement.id) out of order") }
            let seam = abs(placement.y - previous.maxY)
            worstLayout = max(worstLayout, Double(seam))
            if seam > 0.01 { failures.append("step \(step): settled seam \(fmt(Double(seam))) between \(previous.id) and \(placement.id)") }
          }
          previous = placement
        }
        if let first = layout.placements.first, let last = layout.placements.last {
          let coversTop = first.y <= b.usableTop + 0.5 || first.id == ids[0]
          let coversBottom = last.maxY >= b.usableBottom - 0.5 || last.id == ids[ids.count - 1]
          if !coversTop || !coversBottom { failures.append("step \(step): settled rows do not cover the screen (\(fmt(Double(first.y)))…\(fmt(Double(last.maxY))))") }
        }
        for (id, _) in b.list.placedViews {
          guard let shown = b.shown(id), let settled = b.settled(id) else { continue }
          let d = Double(abs(shown.minY - settled.minY))
          worstStuck = max(worstStuck, d)
          if d > 0.5 { failures.append("step \(step): row \(id) shown \(fmt(d)) pt off its settled place") }
        }
        if wasStillInHistory, !touchedReader, let reader, let readerY, ids.contains(reader), let now = b.shown(reader)?.minY {
          let d = Double(abs(now - readerY))
          readerDrift = max(readerDrift, d)
          if d > 0.5 { failures.append("step \(step): reader \(reader) drifted \(fmt(d))") }
        }
        if failures.count > 30 { break }
      }
      c.note("seed \(seed), \(steps) steps")
      if !failures.isEmpty {
        for line in failures.prefix(12) { c.note(line) }
        let firstStep = failures.first.flatMap { $0.split(separator: ":").first }.map(String.init) ?? ""
        for line in log where line.hasPrefix(firstStep.replacingOccurrences(of: " never rested", with: "")) { c.note("log: \(line)") }
      }
      c.atMost("blank strip, worst frame", worstBlank, 0.5)
      c.atMost("a removed row's gap reopening", worstReopen, 0.5)
      c.atMost("frames a row showed undrawn (longest run)", Double(worstUndrawn), 1, unit: "")
      c.atMost("settled seams", worstLayout, 0.01)
      c.atMost("rows out of order or not in the data", Double(outOfOrder), 0, unit: "")
      c.atMost("at rest, shown − settled", worstStuck, 0.5)
      c.atMost("steps that never rested", Double(neverRested), 0, unit: "")
      c.atMost("reader drift on still steps that left it alone", readerDrift, 0.5)
    }
  }
}
extension SplitMix: RandomNumberGenerator {}
