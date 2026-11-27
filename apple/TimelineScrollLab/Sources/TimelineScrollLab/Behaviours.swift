import AppKit
import QuartzCore
import TimelineCore

// Behaviours on both lists, measured per display frame (presentation layers) and per composited frame (screen):
// history pages and arrivals during a fling (does anything on screen jump?), pinning through arrivals, the composer's
// inset changing, live resize, animated scrolls to a row.

@MainActor
final class EditCount { var n = 0 }

@MainActor
final class EditProbeLog {
  var samples: [(t: CFTimeInterval, y: [Int: CGFloat])] = []
  var roles: [(String, Int)] = []
  var editAt: CFTimeInterval = 0
  var grew: CGFloat = 0
  var note = ""
  var heights: [[Int: CGFloat]] = []
  var scrolls: [Double] = []
  var edits: [CFTimeInterval] = []
  var latencies: [Double] = []
}

/// Answers demands for older history after `latency` with pages of 50, as a database would.
@MainActor
final class PageLoader {
  let run: Run
  let latency: Double
  var stopped = false
  private(set) var inFlight = false
  private(set) var pages = 0
  private(set) var landings: [CFTimeInterval] = []

  init(run: Run, latency: Double) {
    self.run = run
    self.latency = latency
  }

  func demand(_ edges: Set<TimelineEdge>) {
    guard edges.contains(.older), !inFlight, !stopped, pages < 40 else { return }
    inFlight = true
    DispatchQueue.main.asyncAfter(deadline: .now() + latency) { [self] in
      MainActor.assumeIsolated {
        inFlight = false
        guard !stopped else { return }
        run.lab.chat.prepend(50)
        run.lab.subject.apply(rows: run.lab.chat.ids, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: true))
        pages += 1
        landings.append(CACurrentMediaTime())
      }
    }
  }
}

extension Compare {
  static var behaviourKinds: [String] {
    argument("--subjects")?.split(separator: ",").map(String.init) ?? ["engine-flight", "engine-coast", "nsscroll", "tg"]
  }

  static func behaviours() async {
    let only = argument("--behaviour")
    if let only {
      for kind in behaviourKinds {
        switch only {
          case "inset": await insetChange(kind: kind, pinned: true)
          case "pages": await pagesDuringFling(kind: kind)
          case "ends": await flingIntoEnd(kind: kind, oldest: true); await flingIntoEnd(kind: kind, oldest: false)
          case "edits": await editsDuringFling(kind: kind); await editsDuringFling(kind: kind, onScreen: true)
          case "edits-held":
            await editsDuringFling(kind: kind, heldToRest: true); await editsDuringFling(kind: kind, onScreen: true, heldToRest: true)
          case "editprobe":
            for role in (argument("--roles")?.split(separator: ",").map(String.init) ?? ["above", "top", "mid", "anchor", "below"]) {
              await editProbe(kind: kind, role: role)
            }
          default: break
        }
      }
      return
    }
    for kind in behaviourKinds {
      await pagesDuringFling(kind: kind)
      await arrivalsDuringFling(kind: kind)
      await editsDuringFling(kind: kind)
      await editsDuringFling(kind: kind, onScreen: true)
      await pinnedArrivals(kind: kind)
      await insetChange(kind: kind, pinned: true)
      await insetChange(kind: kind, pinned: false)
      await liveResize(kind: kind, pinned: true)
      await liveResize(kind: kind, pinned: false)
      await scrollToRow(kind: kind, rows: 40)
      await scrollToRow(kind: kind, rows: 400)
      await flingIntoEnd(kind: kind, oldest: true)
      await flingIntoEnd(kind: kind, oldest: false)
    }
  }

  /// A fling into a real end (the oldest message, or the newest): it must stop there (bouncing, not short of it and
  /// not past it into nothing), and rest with that row on the usable edge.
  static func flingIntoEnd(kind: String, oldest: Bool) async {
    let run = Run(kind: kind, count: 300, rowCost: 1)
    await run.wait(0.3)
    let ids = run.lab.chat.ids
    await run.centre(oldest ? 22 : ids.count - 22)
    let end = oldest ? ids.first! : ids.last!
    var overscroll = 0.0
    run.recorder.extraSample = { _ in
      guard let frame = run.lab.subject.shownRows().first(where: { $0.id == end })?.frame else { return }
      let past = oldest ? Double(frame.minY - run.lab.usableTop) : Double(run.lab.usableBottom - frame.maxY)
      overscroll = max(overscroll, past)
    }
    await run.begin(screen: false)
    let fling = Synth.fling(speed: oldest ? 6000 : -6000)
    let start = await run.play(fling.steps)
    let rest = await run.untilRest()
    await run.end()
    var n = run.numbers(scenario: "fling into \(oldest ? "oldest" : "newest") end", from: start, lift: start + fling.lift, to: rest)
    var restError = Double.nan
    if let frame = run.lab.subject.shownRows().first(where: { $0.id == end })?.frame {
      restError = oldest ? Double(frame.minY - run.lab.usableTop) : Double(run.lab.usableBottom - frame.maxY)
    }
    n.extra["bounce"] = overscroll
    n.extra["restError"] = restError
    n.notes = String(format: "bounce depth %.1f pt, at rest the end row is %.2f pt off the usable edge; ", overscroll, restError) + n.notes
    record(n)
    run.recorder.extraSample = nil
    run.close()
    await run.wait(0.2)
  }

  /// History pages landing above while a fling heads for the loaded edge: the free fling's travel is the reference.
  static func pagesDuringFling(kind: String) async {
    for latency in [0.03, 0.15] {
      let run = Run(kind: kind, count: 400, rowCost: 1, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: true))
      await run.wait(0.3)
      await run.centre(45)
      let loader = PageLoader(run: run, latency: latency)
      run.lab.subject.onDemand = { loader.demand($0) }
      await run.begin(dumpName: "pages_\(Int(latency * 1000))-\(kind)")
      let fling = Synth.fling(speed: 10000)
      let start = await run.play(fling.steps)
      let rest = await run.untilRest()
      loader.stopped = true
      await run.end()
      var n = run.numbers(scenario: "pages \(Int(latency * 1000))ms during fling", from: start, lift: start + fling.lift, to: rest)
      n.extra["pages"] = Double(loader.pages)
      n.notes = "pages landed \(loader.pages) at " + loader.landings.map { String(format: "%+.0f", ($0 - start - fling.lift) * 1000) }
        .joined(separator: ",") + " ms; " + n.notes
      record(n)
      run.close()
      await run.wait(0.2)
    }
  }

  /// New messages arriving at the bottom while a fling runs upwards from near it.
  static func arrivalsDuringFling(kind: String) async {
    let run = Run(kind: kind, count: 3000, rowCost: 1)
    await run.wait(0.3)
    await run.centre(run.lab.chat.ids.count - 30)
    await run.begin(dumpName: "arrivals-\(kind)")
    var fling = Synth.fling(speed: 4000)
    for i in 0 ..< 6 {
      fling.steps.append(Synth.Step(at: fling.lift + 0.05 + Double(i) * 0.08, label: "arrive") {
        let chat = run.lab.chat
        chat.append("arriving \(i) " + String(repeating: "new words ", count: 1 + i % 4), sender: 1 + i % 3)
        run.lab.subject.apply(rows: chat.ids, timing: .standard)
      })
    }
    let start = await run.play(fling.steps)
    let rest = await run.untilRest()
    await run.end()
    record(run.numbers(scenario: "arrivals during fling", from: start, lift: start + fling.lift, to: rest))
    run.close()
    await run.wait(0.2)
  }

  /// Rows changing height while a fling runs (an edit, a reaction): every 80 ms one row above the screen, one on screen
  /// near the top and one mid-screen grow by three lines. Nothing on screen may leap.
  /// `onScreen`: the rows are picked among the rows inside the usable area (the first form picks by order among the
  /// realised rows, which for the NSScrollView prototype reach far beyond the screen).
  /// `heldToRest`: the host holds each edit until the list rests and applies it then (animated, as at rest).
  static func editsDuringFling(kind: String, onScreen: Bool = false, heldToRest: Bool = false) async {
    let run = Run(kind: kind, count: 3000, rowCost: 1)
    await run.wait(0.3)
    await run.centre()
    await run.begin(dumpName: "edits-\(kind)")
    var fling = Synth.fling(speed: 4000)
    let edited = EditCount()
    // Per display frame: the flight's path (presented scroll position) and every shown row's presented frame.
    let lab = run.lab
    let recorder = run.recorder
    let frames = EditProbeLog()
    run.recorder.extraSample = { t in
      var ys: [Int: CGFloat] = [:]
      var hs: [Int: CGFloat] = [:]
      for row in lab.subject.shownRows() {
        ys[row.id] = row.frame.minY
        hs[row.id] = row.frame.height
      }
      frames.samples.append((t, ys))
      frames.heights.append(hs)
      frames.scrolls.append(Double(recorder.scrollPosition()))
    }
    for i in 0 ..< 6 {
      fling.steps.append(Synth.Step(at: fling.lift + 0.05 + Double(i) * 0.08, label: "edit") {
        let chat = run.lab.chat
        let usableTop = run.lab.usableTop
        let usableBottom = run.lab.usableBottom
        let shown = run.lab.subject.shownRows().filter { !(chat.row($0.id)?.isDay ?? true) }
          .filter { !onScreen || ($0.frame.minY >= usableTop && $0.frame.maxY <= usableBottom) }
          .sorted { $0.frame.minY < $1.frame.minY }
        guard shown.count > 6, let top = chat.index(shown[0].id), top > 3 else { return }
        let picks = [chat.ids[top - 3], shown[2].id, shown[shown.count / 2].id]
        @MainActor func edit() {
          for id in picks {
            chat.setText(id, (chat.row(id)?.text ?? "") + " edited " + String(repeating: "more words here ", count: 9))
          }
        }
        edited.n += picks.count
        if heldToRest {
          // The host holds the edit (its data and the list's update) until the list rests.
          let at = CACurrentMediaTime()
          Task { @MainActor in
            while lab.subject.isMoving { try? await Task.sleep(for: .milliseconds(4)) }
            edit()
            frames.edits.append(CACurrentMediaTime())
            frames.latencies.append(CACurrentMediaTime() - at)
            lab.subject.apply(changed: Set(picks), timing: .standard)
          }
          return
        }
        edit()
        frames.edits.append(CACurrentMediaTime())
        run.lab.subject.apply(changed: Set(picks), timing: .standard)
      })
    }
    let start = await run.play(fling.steps)
    var rest = await run.untilRest()
    if heldToRest {
      await run.wait(0.7)
      rest = await run.untilRest()
      rest = max(rest, CACurrentMediaTime() - 0.05)
    }
    await run.end()
    var n = run.numbers(scenario: (onScreen ? "edits during fling, on screen" : "edits during fling") + (heldToRest ? ", held to rest" : ""),
                        from: start, lift: start + fling.lift, to: rest)
    if !frames.latencies.isEmpty {
      n.extra["heldMsMax"] = (frames.latencies.max() ?? 0) * 1000
      n.extra["heldMsMin"] = (frames.latencies.min() ?? 0) * 1000
    }
    n.extra["edited"] = Double(edited.n)
    run.recorder.extraSample = nil
    // What stepped off the flight's path at each edit: rows inside the usable area whose presented top moved more than
    // 6 pt beyond the path over the two frames from the edit on. The area they cover, and the biggest step.
    let usableTop = run.lab.usableTop
    let usableBottom = run.lab.usableBottom
    var areas: [Double] = []
    var worst = 0.0
    for at in frames.edits {
      guard let e = frames.samples.firstIndex(where: { $0.t > at }), e >= 1, e + 1 < frames.samples.count else { continue }
      let a = frames.samples[e - 1].y
      let b = frames.samples[e + 1].y
      let path = -(frames.scrolls[e + 1] - frames.scrolls[e - 1])
      var moved = 0.0
      for (id, y0) in a {
        guard let y1 = b[id], let h = frames.heights[e - 1][id] else { continue }
        let visible = max(0, min(Double(y0 + h), Double(usableBottom)) - max(Double(y0), Double(usableTop)))
        guard visible > 0 else { continue }
        let deviation = Double(y1 - y0) - path
        if abs(deviation) > 6 {
          moved += visible
          worst = max(worst, abs(deviation))
        }
      }
      areas.append(moved / Double(usableBottom - usableTop))
    }
    n.extra["movedShareMean"] = areas.isEmpty ? 0 : areas.reduce(0, +) / Double(areas.count)
    n.extra["movedShareMax"] = areas.max() ?? 0
    n.extra["worstStep"] = worst
    n.notes = "moved share per edit: " + areas.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " ")
      + String(format: ", worst step %.0f pt; ", worst) + n.notes
    record(n)
    run.close()
    await run.wait(0.2)
  }

  /// Which rows move when one row grows mid-fling, and against what: one edit 150 ms after the lift of a 4,000 pt/s
  /// fling, on a row `role` (above the screen, near the top, mid-screen, the reading row, the row below it). Per display
  /// frame, every shown row's presented top; at the edit, each row's step against its own trend (the two frames before).
  static func editProbe(kind: String, role: String) async {
    let run = Run(kind: kind, count: 3000, rowCost: 1)
    await run.wait(0.3)
    await run.centre()
    await run.wait(0.3)
    let lab = run.lab
    let chat = lab.chat
    let log = EditProbeLog()
    run.recorder.extraSample = { t in
      var ys: [Int: CGFloat] = [:]
      for row in lab.subject.shownRows() { ys[row.id] = row.frame.minY }
      log.samples.append((t, ys))
    }
    await run.begin(dumpName: "editprobe_\(role)-\(kind)")
    var fling = Synth.fling(speed: 4000)
    fling.steps.append(Synth.Step(at: fling.lift + 0.15, label: "edit") {
      let top = lab.usableTop
      let bottom = lab.usableBottom
      let shown = lab.subject.shownRows().filter { !(chat.row($0.id)?.isDay ?? true) }.sorted { $0.frame.minY < $1.frame.minY }
      let visible = shown.filter { $0.frame.minY >= top && $0.frame.maxY <= bottom }
      guard visible.count > 6, let first = chat.index(visible[0].id), let last = visible.last else { return }
      var anchor: Int?
      if case let .row(id, _) = lab.subject.layout.position { anchor = id }
      let a = shown[2].frame
      let b = shown[shown.count / 2].frame
      log.note = String(format: "the first check's picks: shown[2] %.0f…%.0f, shown[n/2] %.0f…%.0f (usable %.0f…%.0f; %d rows shown, %d inside)",
                        a.minY, a.maxY, b.minY, b.maxY, top, bottom, shown.count, visible.count)
      let target: Int
      switch role {
        case "above": target = chat.ids[first - 3]
        case "top": target = visible[1].id
        case "mid": target = visible[visible.count / 2].id
        case "anchor": target = anchor ?? last.id
        default:
          let at = anchor.flatMap { chat.index($0) } ?? chat.index(last.id) ?? first
          target = chat.ids[at + 1]
      }
      guard let index = chat.index(target) else { return }
      log.roles = [("grown", target), ("above it", chat.ids[index - 1]), ("below it", chat.ids[index + 1]),
                   ("top visible", visible[0].id), ("bottom visible", last.id)]
      if let anchor { log.roles.append(("reading row", anchor)) }
      let width = lab.subject.view.bounds.width
      let before = chat.height(target, width)
      chat.setText(target, (chat.row(target)?.text ?? "") + " edited " + String(repeating: "more words here ", count: 9))
      log.grew = chat.height(target, width) - before
      log.editAt = CACurrentMediaTime()
      lab.subject.apply(changed: [target], timing: .standard)
    })
    let start = await run.play(fling.steps)
    let rest = await run.untilRest()
    await run.end()
    run.recorder.extraSample = nil
    var n = run.numbers(scenario: "edit probe \(role)", from: start, lift: start + fling.lift, to: rest)
    // At the edit: each role's per-frame steps around it and its deviation from its own trend over the two frames from
    // the edit on (positive: moved further down than its motion).
    let samples = log.samples
    if let e = samples.firstIndex(where: { $0.t > log.editAt }), e >= 3, e + 2 < samples.count {
      var parts: [String] = []
      for (name, id) in log.roles {
        guard let ys = Optional((e - 3 ... e + 2).map { samples[$0].y[id] }), ys.allSatisfy({ $0 != nil }) else {
          parts.append("\(name) n/a")
          continue
        }
        let y = ys.map { Double($0!) }
        let steps = zip(y, y.dropFirst()).map { $1 - $0 }
        let trend = (y[2] - y[0]) / 2
        let deviation = (y[5] - y[2]) - 3 * trend
        n.extra["dev \(name)"] = deviation
        parts.append(String(format: "%@ %+.1f (steps %@)", name, deviation, steps.map { String(format: "%.0f", $0) }.joined(separator: " ")))
      }
      n.notes = String(format: "grew %.0f pt; ", log.grew) + parts.joined(separator: "; ") + "; " + log.note + "; " + n.notes
    } else {
      n.notes = "edit not bracketed by frames; " + n.notes
    }
    n.extra["grew"] = Double(log.grew)
    record(n)
    print("    " + n.notes)
    run.close()
    await run.wait(0.2)
  }

  /// Pinned to the newest message: arrivals keep it on the composer, rising smoothly.
  static func pinnedArrivals(kind: String) async {
    let run = Run(kind: kind, count: 600, rowCost: 1)
    await run.wait(0.4)
    var worstRest = 0.0
    var overshoot = 0.0
    run.recorder.extraSample = { _ in
      let chat = run.lab.chat
      guard let newest = chat.ids.last,
            let frame = run.lab.subject.shownRows().first(where: { $0.id == newest })?.frame else { return }
      // How far the newest row's bottom shows below the usable bottom (under the composer) while it rises in.
      overshoot = max(overshoot, Double(frame.maxY - run.lab.usableBottom))
    }
    await run.begin()
    let start = CACurrentMediaTime()
    for i in 0 ..< 5 {
      let chat = run.lab.chat
      chat.append("pinned arrival \(i) " + String(repeating: "words ", count: 2 + i * 3), sender: 1 + i % 3)
      run.lab.subject.apply(rows: chat.ids, timing: .standard)
      await run.wait(0.45)
      if let newest = chat.ids.last, let frame = run.lab.subject.shownRows().first(where: { $0.id == newest })?.frame {
        worstRest = max(worstRest, abs(Double(frame.maxY - run.lab.usableBottom)))
      }
    }
    let rest = await run.untilRest()
    await run.end()
    var n = run.numbers(scenario: "pinned arrivals", from: start, lift: start, to: rest)
    n.extra["restError"] = worstRest
    n.extra["overshoot"] = overshoot
    n.notes = String(format: "newest bottom off the usable bottom at rest: %.2f pt (worst of 5); below it (rising in) at worst: %.2f pt; ", worstRest, overshoot) + n.notes
    record(n)
    run.recorder.extraSample = nil
    run.close()
    await run.wait(0.2)
  }

  /// The composer grows to four lines and back on a spring; the list's bottom inset moves with it. Pinned: the newest
  /// row stays on the composer; scrolled up: the reading row keeps its distance from the composer.
  static func insetChange(kind: String, pinned: Bool) async {
    let run = Run(kind: kind, count: 600, rowCost: 1)
    await run.wait(0.4)
    if !pinned { await run.centre(400) }
    let reading: Int = {
      if pinned { return run.lab.chat.ids.last! }
      let bottom = run.lab.usableBottom
      return run.lab.subject.shownRows().filter { $0.frame.maxY < bottom - 40 }.max { $0.frame.maxY < $1.frame.maxY }?.id
        ?? run.lab.chat.ids[400]
    }()
    var gaps: [Double] = []
    run.recorder.extraSample = { _ in
      guard let frame = run.lab.subject.shownRows().first(where: { $0.id == reading })?.frame,
            let layer = run.lab.composer.layer else { return }
      let composerTop = (layer.presentation() ?? layer).frame.minY
      gaps.append(Double(composerTop - frame.maxY))
    }
    await run.begin(screen: false)
    let start = CACurrentMediaTime()
    run.lab.setComposerLines(4)
    await run.wait(0.6)
    run.lab.setComposerLines(1)
    await run.wait(0.6)
    let rest = await run.untilRest()
    await run.end()
    var n = run.numbers(scenario: "inset change \(pinned ? "pinned" : "scrolled")", from: start, lift: start, to: rest)
    let first = gaps.first ?? 0
    let drift = gaps.map { abs($0 - first) }.max() ?? 0
    if arguments.contains("--motions") { print("  gaps: " + gaps.map { String(format: "%.0f", $0) }.joined(separator: " ")) }
    n.extra["drift"] = drift
    n.extra["finalDrift"] = abs((gaps.last ?? first) - first)
    n.notes = String(format: "reading row to composer gap drift: worst %.2f pt, at the end %.2f pt (%d frames); ", drift,
                     abs((gaps.last ?? first) - first), gaps.count) + n.notes
    record(n)
    run.recorder.extraSample = nil
    run.close()
    await run.wait(0.2)
  }

  /// The window resized step by step (height, then width), as a live resize lays out each frame.
  static func liveResize(kind: String, pinned: Bool) async {
    let run = Run(kind: kind, count: 600, rowCost: 1)
    await run.wait(0.4)
    if !pinned { await run.centre(400) }
    let reading: Int = {
      if pinned { return run.lab.chat.ids.last! }
      let bottom = run.lab.usableBottom
      return run.lab.subject.shownRows().filter { $0.frame.maxY < bottom - 40 }.max { $0.frame.maxY < $1.frame.maxY }?.id
        ?? run.lab.chat.ids[400]
    }()
    var gaps: [Double] = []
    var heightSteps = true
    run.recorder.extraSample = { _ in
      guard heightSteps, let frame = run.lab.subject.shownRows().first(where: { $0.id == reading })?.frame else { return }
      gaps.append(Double(run.lab.usableBottom - frame.maxY))
    }
    await run.begin(screen: false)
    let start = CACurrentMediaTime()
    let window = run.lab.window
    let original = window.frame
    for i in 1 ... 20 {
      var frame = original
      frame.size.height -= CGFloat(i) * 12
      frame.origin.y += CGFloat(i) * 12
      window.setFrame(frame, display: true)
      await run.wait(1.0 / 60)
    }
    heightSteps = false
    var widthDrift = 0.0
    let before = run.lab.subject.shownRows().first(where: { $0.id == reading })?.frame
    for width in Array(stride(from: 520.0, through: 760, by: 20)) + Array(stride(from: 760.0, through: 420, by: -20)) {
      var frame = window.frame
      frame.size.width = width
      window.setFrame(frame, display: true)
      await run.wait(1.0 / 60)
    }
    var frame = window.frame
    frame.size.width = 520
    window.setFrame(frame, display: true)
    await run.wait(0.3)
    if let before, let after = run.lab.subject.shownRows().first(where: { $0.id == reading })?.frame {
      widthDrift = abs(Double((run.lab.usableBottom - after.maxY) - (run.lab.usableBottom - before.maxY)))
    }
    let rest = await run.untilRest()
    await run.end()
    var n = run.numbers(scenario: "live resize \(pinned ? "pinned" : "scrolled")", from: start, lift: start, to: rest)
    let first = gaps.first ?? 0
    let drift = gaps.map { abs($0 - first) }.max() ?? 0
    n.extra["drift"] = drift
    n.extra["widthDrift"] = widthDrift
    n.notes = String(format: "reading row to usable bottom drift while the height shrank: worst %.2f pt (%d frames); after a width round trip: %.2f pt; ", drift, gaps.count, widthDrift) + n.notes
    record(n)
    run.recorder.extraSample = nil
    run.close()
    await run.wait(0.2)
  }

  /// An animated scroll to a row `rows` above the newest, centred.
  static func scrollToRow(kind: String, rows: Int) async {
    let run = Run(kind: kind, count: 3000, rowCost: 1)
    await run.wait(0.4)
    let ids = run.lab.chat.ids
    let target = ids[ids.count - 1 - rows]
    await run.begin(dumpName: "scrollto_\(rows)-\(kind)")
    let start = CACurrentMediaTime()
    run.lab.subject.apply(scroll: .to(target, .center), timing: .standard)
    let rest = await run.untilRest()
    await run.end()
    var n = run.numbers(scenario: "scroll to row \(rows) up", from: start, lift: start, to: rest)
    if let frame = run.lab.subject.shownRows().first(where: { $0.id == target })?.frame {
      let centre = (run.lab.usableTop + run.lab.usableBottom) / 2
      n.extra["landingError"] = abs(Double(frame.midY - centre))
      n.notes = String(format: "landed %.2f pt off centre after %.0f ms; ", abs(Double(frame.midY - centre)), (rest - start) * 1000) + n.notes
    } else {
      n.notes = "target not shown at rest; " + n.notes
    }
    record(n)
    run.close()
    await run.wait(0.2)
  }
}
