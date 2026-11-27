import AppKit
import QuartzCore
import TimelineAppKit
import TimelineCore

// Stress: fast flings under realistic costs. Every combination runs in a fresh lab chat window. The budgets are what
// the product needs (no blank strip, no undrawn row, no stop at a loaded edge that is not a real end); every case notes
// its measured numbers so a failure says where rows fall behind (realisation lookahead, drawing, load latency).
//
// Two views of the screen:
// - commits: right after each Core Animation commit (a run loop observer behind CA's own), the rows the render server
//   now has, in content coordinates, and which of them have not drawn their text. Until the next commit the screen
//   shows exactly those rows at the content's moving origin, whatever the main thread does meanwhile (rows costing
//   milliseconds, a stall), so each interval is judged at both of its ends. This is the authoritative measure.
// - display frames: the suite's recorder and a sample at each display link callback. A frame sample taken after the
//   list's own tick in the same pass (its rows not yet committed or drawn) is not counted for undrawn rows or speeds.

extension SuiteCases {
  static var stress: [BehaviourCase] {
    [stressFlingRowCost, stressFlingIntoLoadingEdge, stressMainThreadStall]
  }

  /// The runner's own window is not used: each combination opens its own.
  private static var spare: Bench.Options { Bench.Options(count: 40) }

  static var stressFlingRowCost: BehaviourCase {
    BehaviourCase(
      id: "stress.fling-row-cost", area: "Stress",
      behaviour: "Flings at 2,000, 5,000 and 8,000 pt/s (finger speed) both ways, with rows costing 0, 1, 3 and 6 ms to make: no blank strip and no row on screen without its text, on any frame or between any two commits",
      options: spare
    ) { b, c in
      b.window.orderOut(nil)
      for cost in [0.0, 1, 3, 6] {
        for speed in [2000.0, 5000, 8000] {
          for older in [true, false] {
            let bench = Bench(Bench.Options(count: 3000, rowCost: cost))
            await bench.frames(3)
            await bench.goMiddle()
            await bench.frames(5)
            let run = await bench.stressRun { _ in await bench.stressFling(speed: older ? speed : -speed, cost: cost) }
            let n = run.numbers(towardsOlder: older, top: bench.usableTop, bottom: bench.usableBottom)
            bench.close()
            let name = "\(older ? "older" : "newer") \(Int(speed)) pt/s, \(fmt(cost)) ms/row"
            c.atMost("\(name): blank strip", n.blank, 0)
            c.atMost("\(name): undrawn rows on screen", Double(n.undrawn), 0, unit: "")
            c.note("\(name): \(n.summary)")
            try? await Task.sleep(nanoseconds: 100_000_000)
          }
        }
      }
    }
  }

  static var stressFlingIntoLoadingEdge: BehaviourCase {
    BehaviourCase(
      id: "stress.fling-into-loading-edge", area: "Stress",
      behaviour: "A fast fling towards the oldest loaded row of a chat with more history, pages answering after 30 ms and 150 ms: the fling never stops, bounces or slows at the loaded edge, no content is missing at the top, no blank strip",
      options: spare
    ) { b, c in
      b.window.orderOut(nil)
      for speed in [5000.0, 8000] {
        // The same fling with no edge anywhere near: what the loaded edge must not change.
        let free = Bench(Bench.Options(count: 3000))
        await free.frames(3)
        await free.goMiddle()
        await free.frames(5)
        let control = await free.stressRun { _ in await free.stressFling(speed: speed, cost: 0) }
        let f = control.numbers(towardsOlder: true, top: free.usableTop, bottom: free.usableBottom)
        free.close()
        c.note("\(Int(speed)) pt/s free fling: \(f.summary); speed at +100/+200/+300 ms \(control.speedsAt([0.1, 0.2, 0.3]))")
        try? await Task.sleep(nanoseconds: 100_000_000)
        for latency in [0.03, 0.15] {
          for distance in [1500.0, 2500] {
            let bench = Bench(Bench.Options(count: 200, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: true)))
            await bench.frames(3)
            // Let go `distance` below the oldest loaded row: the drag's own travel is added.
            await bench.goOldest()
            bench.list.apply(TimelineTransaction(scroll: .by(-(distance + speed / 120 * 12))))
            await bench.frames(5)
            let loader = StressLoader(bench: bench, latency: latency)
            bench.list.onDemand = { edges in loader.demand(edges) }
            let run = await bench.stressRun { _ in await bench.stressFling(speed: speed, cost: 0) }
            loader.stopped = true
            bench.list.onDemand = nil
            let n = run.numbers(towardsOlder: true, top: bench.usableTop, bottom: bench.usableBottom)
            let e = run.edge(top: bench.usableTop)
            bench.close()
            // Travel per unit of release speed, against the free fling's: the release estimate varies a few percent.
            let share = f.travel > 0 && n.releaseSpeed > 0 ? (n.travel / n.releaseSpeed) / (f.travel / f.releaseSpeed) * 100 : 0
            let name = "\(Int(latency * 1000)) ms pages, \(Int(speed)) pt/s from \(Int(distance)) pt"
            c.that("\(name): never stops or bounces at the loaded edge", !e.stopped && e.reversals == 0)
            if e.reversals > 0 { c.note("\(name): turned back at \(run.reversalDetail().joined(separator: ", "))") }
            c.atLeast("\(name): travel against a free fling", share, 95, unit: "%")
            c.atMost("\(name): longest time content missing at the top", e.missingMs, 0, unit: "ms")
            c.atMost("\(name): blank strip", n.blank, 0)
            let requests = loader.requests.map { String(format: "%+.0f", ($0 - run.lift) * 1000) }.joined(separator: ", ")
            let landings = loader.landings.map { String(format: "%+.0f", ($0 - run.lift) * 1000) }.joined(separator: ", ")
            c.note(
              "\(name): stopped at a loaded edge \(e.stopped ? "yes" : "no"), \(e.reversals) reversals, "
                + String(format: "travel %.0f%% of free, ", share)
                + "loaded edge in view \(String(format: "%.0f", e.contactMs)) ms"
                + (e.firstContactMs.map { String(format: " from %+.0f ms", $0) } ?? "")
                + String(format: ", content missing at the top %.0f ms at most (worst %.0f pt); ", e.missingMs, e.worstTopGap)
                + "\(loader.pages) pages, requested at [\(requests)] ms, landed at [\(landings)] ms after the lift; "
                + "speed at +100/+200/+300 ms \(run.speedsAt([0.1, 0.2, 0.3])); \(n.summary)"
            )
            try? await Task.sleep(nanoseconds: 300_000_000)
          }
        }
      }
    }
  }

  static var stressMainThreadStall: BehaviourCase {
    BehaviourCase(
      id: "stress.main-thread-stall", area: "Stress",
      behaviour: "A fast fling (5,000 and 8,000 pt/s, rows 1 ms) with the main thread blocked for 50 ms or 150 ms, soon after the lift or mid-fling: the render server plays through it with rows already there, no blank strip, no undrawn row",
      options: spare
    ) { b, c in
      b.window.orderOut(nil)
      let plans: [(stall: Double, delay: Double)] = [(0, 0), (0.05, 0.03), (0.05, 0.2), (0.15, 0.03), (0.15, 0.2)]
      for speed in [5000.0, 8000] {
        for plan in plans {
          let bench = Bench(Bench.Options(count: 3000, rowCost: 1))
          await bench.frames(3)
          await bench.goMiddle()
          await bench.frames(5)
          let run = await bench.stressRun { watch in
            let lift = await bench.stressFling(speed: speed, cost: 1)
            if plan.stall > 0 {
              DispatchQueue.main.asyncAfter(deadline: .now() + plan.delay) {
                MainActor.assumeIsolated { bench.stressStall(plan.stall, watch: watch) }
              }
            }
            return lift
          }
          let n = run.numbers(towardsOlder: true, top: bench.usableTop, bottom: bench.usableBottom)
          bench.close()
          let name = plan.stall == 0
            ? "\(Int(speed)) pt/s, no stall"
            : "\(Int(speed)) pt/s, \(Int(plan.stall * 1000)) ms stall at +\(Int(plan.delay * 1000)) ms"
          c.atMost("\(name): blank strip", n.blank, 0)
          c.atMost("\(name): undrawn rows on screen", Double(n.undrawn), 0, unit: "")
          var note = "\(name): "
          if let s = run.stallNumbers(towardsOlder: true, top: bench.usableTop) { note += s + "; " }
          c.note(note + n.summary)
          try? await Task.sleep(nanoseconds: 100_000_000)
        }
      }
    }
  }
}

// MARK: - Sampling

/// What the screen showed at a display frame (or inside a stall), from the presentation layers.
struct StressSample {
  var t: CFTimeInterval
  /// How far the content has travelled on screen (positive: down, towards older rows).
  var motion: CGFloat
  /// How much of the usable area's top no row covers (0: covered).
  var topGap: CGFloat
  /// The oldest loaded row's top on screen, when it is shown.
  var oldestTop: CGFloat?
  var undrawn: Int
  /// Everything the list did is committed: no tick of the list ran in this pass before the sample.
  var clean: Bool
  var inStall: Bool
}

/// What the render server has right after a commit, in content coordinates (screen y = content y − origin).
struct StressCommit {
  struct Row {
    var id: Int
    var top: CGFloat
    var bottom: CGFloat
  }

  var t: CFTimeInterval
  var origin: CGFloat
  /// Where AppKit's geometry (the content's model bounds, which decides what it draws) puts a row, from where it is
  /// shown: positive, lower on screen.
  var modelOffset: CGFloat
  /// Shown rows, top to bottom.
  var rows: [Row]
  /// Message rows whose text is not drawn.
  var undrawn: [Row]
  var undrawnDetail: [Int: String]
  var oldest: Int
  var newest: Int
  var performs: Int
}

@MainActor
final class StressWatch {
  unowned let bench: Bench
  private(set) var samples: [StressSample] = []
  private(set) var commits: [StressCommit] = []
  var inStall = false
  var stall: (began: CFTimeInterval, ended: CFTimeInterval)?
  /// The display link's frame times (the vsyncs the render server shows frames at).
  var vsyncs: [CFTimeInterval] = []
  private var observer: CFRunLoopObserver?

  init(bench: Bench) { self.bench = bench }

  /// Samples after every Core Animation commit (CA commits at order 2,000,000 before the run loop waits).
  func observeCommits() {
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_001
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.commit() }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
  }

  func stopObserving() {
    if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    observer = nil
  }

  func commit() {
    let list = bench.list
    let origin = list.diagnostics.presentedScrollPosition
    var rows: [StressCommit.Row] = []
    for (id, _) in list.shownViews {
      guard let frame = list.presentedFrame(for: id) else { continue }
      rows.append(StressCommit.Row(id: id, top: frame.minY + origin, bottom: frame.maxY + origin))
    }
    rows.sort { $0.top < $1.top }
    var undrawn: [StressCommit.Row] = []
    var detail: [Int: String] = [:]
    for placement in list.timelineLayout.placements {
      guard let row = list.view(for: placement.id) as? LabRowView, !row.label.isHidden, !row.bubble.isHidden,
            !row.label.showsItsText, let frame = list.presentedFrame(for: placement.id)
      else { continue }
      undrawn.append(StressCommit.Row(id: placement.id, top: frame.minY + origin, bottom: frame.maxY + origin))
      detail[placement.id] = "drawn before \(row.label.drawnText == nil ? 0 : 1), needsDisplay \(row.label.needsDisplay ? 1 : 0), visibleRect empty \(row.label.visibleRect.isEmpty ? 1 : 0)"
    }
    let ids = bench.chat.ids
    commits.append(StressCommit(
      t: CACurrentMediaTime(), origin: origin, modelOffset: origin - list.content.bounds.origin.y, rows: rows, undrawn: undrawn, undrawnDetail: detail, oldest: ids[0],
      newest: ids[ids.count - 1], performs: list.diagnostics.performCount
    ))
    // Reading presentation layers opened a transaction: close it, or the next pass would run on its stale time.
    CATransaction.flush()
  }

  func sample(at time: CFTimeInterval = CACurrentMediaTime()) {
    let list = bench.list
    let top = bench.usableTop
    let bottom = bench.usableBottom
    var covered = false
    var firstBelowTop = CGFloat.infinity
    for (id, _) in list.shownViews {
      guard let frame = list.presentedFrame(for: id), frame.maxY > top, frame.minY < bottom else { continue }
      if frame.minY <= top + 0.5 { covered = true } else { firstBelowTop = min(firstBelowTop, frame.minY) }
    }
    var undrawn = 0
    for placement in list.timelineLayout.placements {
      guard let row = list.view(for: placement.id) as? LabRowView, !row.label.isHidden, !row.bubble.isHidden,
            !row.label.showsItsText, let shown = list.presentedFrame(for: placement.id), shown.maxY > top, shown.minY < bottom
      else { continue }
      undrawn += 1
    }
    let oldest = bench.chat.ids[0]
    let performs = list.diagnostics.performCount
    samples.append(StressSample(
      t: time, motion: -list.diagnostics.presentedScrollPosition, topGap: covered ? 0 : min(bottom - top, firstBelowTop - top),
      oldestTop: list.presentedFrame(for: oldest)?.minY, undrawn: undrawn,
      clean: inStall || commits.last.map { $0.performs == performs } ?? true, inStall: inStall
    ))
  }
}

/// A loader that answers `onDemand` for older history after `latency`, one page of 50 at a time, as the lab prepends
/// pages. More history always exists.
@MainActor
final class StressLoader {
  let bench: Bench
  let latency: Double
  var stopped = false
  private(set) var inFlight = false
  private(set) var pages = 0
  private(set) var requests: [CFTimeInterval] = []
  private(set) var landings: [CFTimeInterval] = []

  init(bench: Bench, latency: Double) {
    self.bench = bench
    self.latency = latency
  }

  func demand(_ edges: Set<TimelineEdge>) {
    guard edges.contains(.older), !inFlight, !stopped, pages < 40 else { return }
    inFlight = true
    requests.append(CACurrentMediaTime())
    DispatchQueue.main.asyncAfter(deadline: .now() + latency) { [self] in
      MainActor.assumeIsolated {
        inFlight = false
        guard !stopped else { return }
        bench.prependPage(50, coverage: TimelineCoverage(reachesOldest: false, reachesNewest: true))
        pages += 1
        landings.append(CACurrentMediaTime())
      }
    }
  }
}

struct StressRun {
  var recording: Recording
  var samples: [StressSample]
  var commits: [StressCommit]
  var vsyncs: [CFTimeInterval]
  var lift: CFTimeInterval
  var stall: (began: CFTimeInterval, ended: CFTimeInterval)?
  var makes: Int
  var hostSeconds: Double
}

extension Bench {
  /// Records while `body` runs (it returns when the fingers lifted) and until the list rests: the suite's frame
  /// recording, frame samples at the same display frames, and the state after every commit.
  func stressRun(timeout: Double = 8, _ body: (StressWatch) async -> CFTimeInterval) async -> StressRun {
    let watch = StressWatch(bench: self)
    let makes = chat.makes
    let host = chat.hostSeconds
    watch.commit()
    watch.observeCommits()
    startRecording()
    let recorderFrame = clock.onFrame
    clock.onFrame = { [weak watch] time in
      recorderFrame?(time)
      watch?.vsyncs.append(time)
      watch?.sample()
    }
    let lift = await body(watch)
    await untilRest(timeout: timeout)
    await frames(2)
    let recording = stopRecording()
    watch.stopObserving()
    return StressRun(
      recording: recording, samples: watch.samples, commits: watch.commits, vsyncs: watch.vsyncs, lift: lift,
      stall: watch.stall,
      makes: chat.makes - makes, hostSeconds: chat.hostSeconds - host
    )
  }

  /// A trackpad fling at `speed` (the finger's, pt/s; positive: towards older rows): 12 moves at 120 Hz, then the
  /// lift. The drag runs with rows free, so every combination lets go at the same speed: the lab stamps each event
  /// as it sends it, and a busy main thread would bunch them (real trackpad events carry their own times). `cost`
  /// applies from the lift. Returns the lift's time.
  func stressFling(speed: Double, cost: Double) async -> CFTimeInterval {
    chat.rowCost = 0
    await gesture(dy: speed / 120, count: 12, lift: false)
    chat.rowCost = cost
    send(Synth.trackpad(0, phase: .ended))
    return CACurrentMediaTime()
  }

  /// Blocks the main thread for `seconds` (a busy wait, as a heavy synchronous job does). Pending layer changes are
  /// committed first (so the stall shows what the list had realised before it) and recorded as a commit; meanwhile
  /// the screen is sampled every 4 ms, each sample on a fresh transaction so the presented values are current.
  func stressStall(_ seconds: Double, watch: StressWatch) {
    CATransaction.flush()
    watch.commit()
    let began = CACurrentMediaTime()
    let end = began + seconds
    var next = began
    watch.inStall = true
    while true {
      let now = CACurrentMediaTime()
      if now >= end { break }
      if now >= next {
        CATransaction.flush()
        recorder?.sample(now)
        watch.sample(at: now)
        CATransaction.flush()
        next = now + 0.004
      }
    }
    watch.inStall = false
    watch.stall = (began, CACurrentMediaTime())
  }
}

// MARK: - Numbers

struct StressNumbers {
  /// Worst over display frames and commit intervals.
  var blank: Double
  var undrawn: Int
  var frameBlank: Double
  var frameBlankAt: String
  var commitBlank: Double
  var commitBlankAt: String
  var frameUndrawn: Int
  var commitUndrawn: Int
  var commitUndrawnDepth: Double
  var commitUndrawnAt: String
  var releaseSpeed: Double
  var travel: Double
  var duration: Double
  var minLead: Double
  var minLeadAfter: Double
  var minLeadSpeed: Double
  var longestCommitGap: Double
  var longestCommitGapAfter: Double
  var commitsMoving: Int
  var modelTrailing: Double
  var modelTrailingEarly: Double
  var uncleanFrames: Int
  var frames: Int
  var makes: Int
  var hostSeconds: Double

  var summary: String {
    var parts: [String] = []
    parts.append(String(format: "release %.0f pt/s, travel %.0f pt in %.2f s", releaseSpeed, travel, duration))
    parts.append(
      blank > 0.01
        ? String(format: "blank at vsyncs %.0f pt (%@), at frame samples %.0f pt (%@)", commitBlank, commitBlankAt, frameBlank, frameBlankAt)
        : "no blank"
    )
    parts.append(
      undrawn > 0
        ? "undrawn rows at vsyncs \(commitUndrawn), reaching \(fmt(commitUndrawnDepth.rounded())) pt into the usable area (\(commitUndrawnAt)), at frame samples \(frameUndrawn)"
        : "no undrawn row"
    )
    if minLead.isFinite {
      parts.append(String(
        format: "tightest lead at a vsync %.0f pt (%.0f ms of travel) at %+.0f ms, %.0f pt/s", minLead,
        minLeadSpeed > 0 ? minLead / minLeadSpeed * 1000 : 0, minLeadAfter, minLeadSpeed
      ))
    }
    parts.append(String(
      format: "longest time on one commit while moving %.0f ms (at %+.0f ms), %d commits", longestCommitGap,
      longestCommitGapAfter, commitsMoving
    ))
    parts.append(String(
      format: "AppKit's geometry trails the leading edge by up to %.0f pt in the first 50 ms, %.0f pt after", modelTrailingEarly,
      modelTrailing
    ))
    parts.append("\(uncleanFrames) of \(frames) frame samples after the list's tick")
    parts.append(String(format: "%d rows made, %.0f ms in rows", makes, hostSeconds * 1000))
    return parts.joined(separator: "; ")
  }
}

extension StressRun {
  /// Clean samples from the lift on, with the content's speed since the clean sample before (pt/s, positive: towards
  /// older).
  var moving: [(sample: StressSample, v: Double)] {
    var out: [(sample: StressSample, v: Double)] = []
    var previous: StressSample?
    for s in samples where s.clean {
      defer { previous = s }
      guard let p = previous, s.t >= lift - 0.0005, s.t - p.t > 0.0005 else { continue }
      out.append((s, Double(s.motion - p.motion) / (s.t - p.t)))
    }
    return out
  }

  /// The content's average speed between two times after the lift (pt/s, positive: towards older), from the presented
  /// origin at frames and commits (commits also land while the main thread is too busy for frame callbacks).
  func speed(from a: Double, to b: Double) -> Double {
    let points = originTimeline
    return -Double(Self.origin(at: lift + b, in: points) - Self.origin(at: lift + a, in: points)) / (b - a)
  }

  func speedsAt(_ times: [Double]) -> String {
    times.map { String(format: "%.0f", abs(speed(from: $0 - 0.02, to: $0 + 0.02))) }.joined(separator: "/") + " pt/s"
  }

  /// The content's presented origin at any time, linear between the samples and commits around it.
  var originTimeline: [(t: Double, origin: CGFloat)] {
    (commits.map { (t: $0.t, origin: $0.origin) } + samples.map { (t: $0.t, origin: -$0.motion) }).sorted { $0.t < $1.t }
  }

  static func origin(at t: Double, in points: [(t: Double, origin: CGFloat)]) -> CGFloat {
    guard let first = points.first, let last = points.last else { return 0 }
    if t <= first.t { return first.origin }
    if t >= last.t { return last.origin }
    var lo = 0
    var hi = points.count - 1
    while hi - lo > 1 {
      let mid = (lo + hi) / 2
      if points[mid].t <= t { lo = mid } else { hi = mid }
    }
    let a = points[lo]
    let b = points[hi]
    return a.origin + (b.origin - a.origin) * CGFloat((t - a.t) / max(b.t - a.t, 1e-9))
  }

  var vsyncPeriod: Double {
    let gaps = zip(vsyncs, vsyncs.dropFirst()).map { $1 - $0 }.filter { $0 > 0.002 && $0 < 0.03 }.sorted()
    return gaps.isEmpty ? 1.0 / 60 : gaps[gaps.count / 2]
  }

  /// The first and last vsync in `a ..< b` (on the display link's grid, also where no callback ran): the frames a
  /// commit made at `a` and replaced at `b` was shown at, taking it to reach the render server at once.
  func shownAt(from a: Double, to b: Double, period: Double) -> (first: Double, last: Double)? {
    guard let ref = vsyncs.last(where: { $0 <= a }) ?? vsyncs.first else { return nil }
    let first = ref + (((a - ref) / period) - 1e-6).rounded(.up) * period
    let last = ref + (((b - ref) / period) - 1e-6).rounded(.down) * period
    return last >= first - 1e-6 ? (first, last) : nil
  }

  /// The screen while commit `a` was the render server's, at origin `o`: the largest blank strip in the usable area
  /// (not past the loaded ends) and the undrawn message rows in it.
  static func judge(_ a: StressCommit, origin o: CGFloat, top: CGFloat, bottom: CGFloat) -> (blank: CGFloat, where: String, undrawn: [StressCommit.Row], depth: CGFloat) {
    var worst: CGFloat = 0
    var place = ""
    let rows = a.rows
    if let first = rows.first, first.id != a.oldest, first.top - o - top > worst {
      worst = first.top - o - top
      place = "top"
    }
    if let last = rows.last, last.id != a.newest, bottom - (last.bottom - o) > worst {
      worst = bottom - (last.bottom - o)
      place = "bottom"
    }
    for (x, y) in zip(rows, rows.dropFirst()) {
      let gap = min(y.top - o, bottom) - max(x.bottom - o, top)
      if gap > worst {
        worst = gap
        place = "between \(x.id) and \(y.id)"
      }
    }
    let undrawn = a.undrawn.filter { $0.top - o < bottom && $0.bottom - o > top }
    let depth = undrawn.map { min($0.bottom - o, bottom) - max($0.top - o, top) }.max() ?? 0
    return (worst, place, undrawn, depth)
  }

  func numbers(towardsOlder: Bool, top: CGFloat, bottom: CGFloat) -> StressNumbers {
    let frames = recording.blankWorst(oldest: commits.last?.oldest ?? 0, newest: commits.last?.newest ?? 0)
    let after = samples.filter { $0.t >= lift - 0.0005 }
    let clean = after.filter(\.clean)
    let release = abs(speed(from: 0.01, to: 0.05))
    let stop = moving.last { abs($0.v) > 30 }?.sample.t ?? lift
    let start = samples.last { $0.t < lift && $0.clean }?.motion ?? after.first?.motion ?? 0
    let travel = Double((clean.last?.motion ?? start) - start)

    var commitBlank: CGFloat = 0
    var commitBlankAt = ""
    var commitUndrawn = 0
    var commitUndrawnDepth: CGFloat = 0
    var commitUndrawnAt = ""
    var minLead = Double.infinity
    var minLeadAfter = 0.0
    var minLeadSpeed = 0.0
    var longest = 0.0
    var longestAfter = 0.0
    var moved = 0
    var trailing: CGFloat = 0
    var trailingEarly: CGFloat = 0
    let points = originTimeline
    let period = vsyncPeriod
    for (a, b) in zip(commits, commits.dropFirst()) where b.t >= lift {
      let duration = b.t - a.t
      let travelled = Double(a.origin - b.origin)
      if abs(travelled) > 1 {
        moved += 1
        if duration * 1000 > longest {
          longest = duration * 1000
          longestAfter = (a.t - lift) * 1000
        }
      }
      guard let shown = shownAt(from: a.t, to: b.t, period: period) else { continue }
      let speed = abs(travelled) / max(duration, 0.001)
      // How far AppKit's geometry trails the shown rows at the leading edge, at this commit's last frame: rows that
      // close to the leading edge are on screen but outside what AppKit considers visible, so it does not draw them.
      if abs(travelled) > 1 {
        let offset = a.modelOffset + (Self.origin(at: shown.last, in: points) - a.origin)
        if shown.last - lift < 0.05 {
          trailingEarly = max(trailingEarly, towardsOlder ? -offset : offset)
        } else {
          trailing = max(trailing, towardsOlder ? -offset : offset)
        }
      }
      // The leading edge at the last frame this commit showed: rows realised beyond the usable area, in the direction
      // of travel.
      let end = Self.origin(at: shown.last, in: points)
      if abs(travelled) > 1, (travelled > 0) == towardsOlder, let first = a.rows.first, let last = a.rows.last {
        let lead = Double(towardsOlder ? top - (first.top - end) : (last.bottom - end) - bottom)
        if lead < minLead {
          minLead = lead
          minLeadAfter = (shown.last - lift) * 1000
          minLeadSpeed = speed
        }
      }
      for t in [shown.first, shown.last] {
        let o = Self.origin(at: t, in: points)
        let j = Self.judge(a, origin: o, top: top, bottom: bottom)
        if j.blank > commitBlank {
          commitBlank = j.blank
          commitBlankAt = String(
            format: "%@ at %+.0f ms, %.0f pt/s, the screen on one commit for %.0f ms", j.where, (t - lift) * 1000, speed,
            duration * 1000
          )
        }
        if j.undrawn.count > commitUndrawn || (j.undrawn.count == commitUndrawn && j.depth > commitUndrawnDepth) {
          commitUndrawn = j.undrawn.count
          commitUndrawnDepth = j.depth
          let row = j.undrawn.max { min($0.bottom - o, bottom) - max($0.top - o, top) < min($1.bottom - o, bottom) - max($1.top - o, top) }!
          commitUndrawnAt = String(
            format: "worst at %+.0f ms, %.0f pt/s, the screen on one commit for %.0f ms; e.g. id %d shown %.0f…%.0f, %@; AppKit's geometry %+.0f pt from what is shown",
            (t - lift) * 1000, speed, duration * 1000, row.id, row.top - o, row.bottom - o, a.undrawnDetail[row.id] ?? "",
            a.modelOffset + (o - a.origin)
          )
        }
      }
    }
    let frameUndrawn = clean.map(\.undrawn).max() ?? 0
    return StressNumbers(
      blank: max(frames.value, Double(commitBlank)), undrawn: max(frameUndrawn, commitUndrawn), frameBlank: frames.value,
      frameBlankAt: frames.at, commitBlank: Double(commitBlank), commitBlankAt: commitBlankAt, frameUndrawn: frameUndrawn,
      commitUndrawn: commitUndrawn, commitUndrawnDepth: Double(commitUndrawnDepth), commitUndrawnAt: commitUndrawnAt, releaseSpeed: release, travel: travel,
      duration: stop - lift, minLead: minLead, minLeadAfter: minLeadAfter, minLeadSpeed: minLeadSpeed,
      longestCommitGap: longest, longestCommitGapAfter: longestAfter, commitsMoving: moved, modelTrailing: Double(trailing),
      modelTrailingEarly: Double(trailingEarly),
      uncleanFrames: after.filter { !$0.clean }.count, frames: after.count, makes: makes, hostSeconds: hostSeconds
    )
  }

  /// At a loaded edge: whether the content stopped or turned back while the oldest loaded row's top was at (or below)
  /// the usable top, how long that edge was in view, and the longest time part of the usable top showed nothing.
  /// Where the motion turned back (ms after the lift, the speed then, and the content's speed the sample before).
  func reversalDetail() -> [String] {
    var out: [String] = []
    var sign = 0
    var last = 0.0
    for (sample, v) in moving where abs(v) > 30 {
      let s = v > 0 ? 1 : -1
      if sign != 0, s != sign { out.append(String(format: "%+.0f ms at %.0f pt/s after %.0f", (sample.t - lift) * 1000, v, last)) }
      sign = s
      last = v
    }
    return out
  }

  func edge(top: CGFloat) -> (stopped: Bool, reversals: Int, contactMs: Double, firstContactMs: Double?, missingMs: Double, worstTopGap: Double) {
    let after = samples.filter { $0.t >= lift - 0.0005 && $0.clean }
    func atEdge(_ s: StressSample, within: CGFloat) -> Bool { s.oldestTop.map { $0 >= top - within } ?? false }
    let moving = self.moving
    let stopped = moving.contains { abs($0.v) < 30 && atEdge($0.sample, within: 3) }
    var reversals = 0
    var sign = 0
    for (_, v) in moving where abs(v) > 30 {
      let s = v > 0 ? 1 : -1
      if sign != 0, s != sign { reversals += 1 }
      sign = s
    }
    var contact = 0.0
    var firstContact: Double?
    var longest = 0.0
    var runStart: CFTimeInterval?
    for (i, s) in after.enumerated() {
      let next = i + 1 < after.count ? after[i + 1].t : s.t
      if atEdge(s, within: 0.5) {
        contact += next - s.t
        if firstContact == nil { firstContact = (s.t - lift) * 1000 }
      }
      if s.topGap > 0.5 {
        if runStart == nil { runStart = s.t }
      } else if let r = runStart {
        longest = max(longest, s.t - r)
        runStart = nil
      }
    }
    if let r = runStart, let last = after.last { longest = max(longest, last.t - r) }
    return (stopped, reversals, contact * 1000, firstContact, longest * 1000, Double(after.map(\.topGap).max() ?? 0))
  }

  /// What a stall did: the lead realised when it began, the travel the render server played during it (from samples
  /// inside it), and the worst inside it, from those samples.
  func stallNumbers(towardsOlder: Bool, top: CGFloat) -> String? {
    guard let stall else { return nil }
    let inside = samples.filter(\.inStall)
    guard let begin = commits.last(where: { $0.t <= stall.began + 0.0005 }), let first = inside.first, let last = inside.last,
          let edgeRow = towardsOlder ? begin.rows.first : begin.rows.last
    else { return nil }
    let lead = Double(towardsOlder ? top - (edgeRow.top - begin.origin) : 0)
    let travel = Double(last.motion - first.motion)
    let expected = speed(from: stall.began - lift - 0.03, to: stall.began - lift) * (last.t - first.t)
    return String(
      format: "stall %.0f ms from %+.0f ms: lead when it began %.0f pt, travel inside it %.0f pt (speed before it × its length: %.0f), worst top gap inside %.0f pt, undrawn inside %d",
      (stall.ended - stall.began) * 1000, (stall.began - lift) * 1000, lead, travel, expected,
      Double(inside.map(\.topGap).max() ?? 0), inside.map(\.undrawn).max() ?? 0
    )
  }
}
