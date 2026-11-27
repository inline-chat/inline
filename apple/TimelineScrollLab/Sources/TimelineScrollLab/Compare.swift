import AppKit
import QuartzCore
import ScrollTimeline
import TimelineAppKit
import TimelineCore

/// One lab window under measurement: presentation frames, screen frames, the main run loop.
@MainActor
final class Run {
  let lab: LabWindow
  let recorder: Recorder
  private(set) var watch: ScreenWatch?
  private(set) var screen: [ScreenFrame] = []
  let kind: String
  var eventTravel: Double = 0
  /// Row discipline: none (every make pays the whole cost), cache (a row's plan is kept once made), ahead (kept, and
  /// made ahead in idle slices).
  enum Rows: String { case none, cache, ahead }
  var preparer: RowPreparer?

  init(kind: String, count: Int, rowCost: Double = 0, coverage: TimelineCoverage = TimelineCoverage(),
       size: NSSize = NSSize(width: 520, height: 760), groupRun: Int = 4, sticky: Bool = false)
  {
    self.kind = kind
    let listKind = kind.hasPrefix("engine-brake") || kind == "engine-bake" ? "brake" : kind.hasPrefix("engine") ? "engine"
      : kind.hasPrefix("nsscroll") ? "nsscroll" : kind.hasPrefix("tg") ? "tg" : kind
    lab = LabWindow(kind: listKind, count: count, rowCost: kind == "plain" ? 0 : rowCost, size: size, coverage: coverage,
                    groupRun: groupRun, sticky: sticky, headerHost: kind == "nsscroll-overlay" ? .overlay : .floatingSubview)
    if let engine = lab.subject as? EngineSubject { engine.list.coastsOnMainThread = kind == "engine-coast" }
    if let brake = lab.subject as? BrakeSubject {
      brake.list.brakesToRows = kind == "engine-brake"
      brake.list.nsScrollViewFling = kind == "engine-bake"
    }
    if let scroll = lab.subject as? ScrollSubject { scroll.list.leadsMotion = kind != "nsscroll-v1" }
    lab.chat.rowCost = kind == "plain" ? 0 : rowCost
    recorder = Recorder(lab: lab)
  }

  func setRows(_ rows: Rows) {
    lab.chat.preparesAhead = rows != .none
    if rows == .ahead {
      let preparer = RowPreparer(lab: lab)
      preparer.start()
      self.preparer = preparer
    }
  }

  func close() {
    preparer?.stop()
    lab.close()
  }

  func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

  func begin(screen: Bool = true, dumpName: String? = nil) async {
    if screen, ScreenWatch.isAvailable {
      let watch = ScreenWatch(geometry: lab.screenGeometry)
      if let dumpName { watch.dumpPrefix = "results/frames/\(dumpName)" }
      await watch.start(windowNumber: lab.window.windowNumber, size: lab.window.frame.size,
                        scale: lab.window.backingScaleFactor, rate: lab.window.screen?.maximumFramesPerSecond ?? 60)
      self.watch = watch
      await wait(0.15)
    }
    recorder.start()
  }

  func end() async {
    recorder.stop()
    if let watch { screen = await watch.stop() }
    watch = nil
  }

  /// Plays events through the window server; returns the time the first step was due.
  func play(_ steps: [Synth.Step]) async -> CFTimeInterval {
    eventTravel = steps.compactMap { step -> Double? in
      guard let event = step.event else { return nil }
      return event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    }.reduce(0, +)
    return await lab.player(steps).play()
  }

  /// Until the content has not moved for `quiet` seconds and the list says it is at rest.
  func untilRest(timeout: Double = 8, quiet: Double = 0.25) async -> CFTimeInterval {
    let end = CACurrentMediaTime() + timeout
    var lastScroll = recorder.scrollPosition()
    var stillSince = CACurrentMediaTime()
    while CACurrentMediaTime() < end {
      await wait(0.02)
      let now = CACurrentMediaTime()
      let scroll = recorder.scrollPosition()
      if abs(scroll - lastScroll) > 0.01 || lab.subject.isMoving {
        stillSince = now
        lastScroll = scroll
      } else if now - stillSince >= quiet {
        return stillSince
      }
    }
    return CACurrentMediaTime()
  }

  func centre(_ index: Int? = nil) async {
    let ids = lab.chat.ids
    let id = ids[index ?? ids.count / 2]
    lab.subject.apply(scroll: .to(id, .center))
    await wait(0.35)
  }

  /// Presentation-layer motion between two times (positive: content down), interpolated from the frame samples.
  func presentedMotion(_ t0: Double, _ t1: Double) -> Double? {
    let samples = recorder.samples
    func scroll(at t: Double) -> Double? {
      guard let after = samples.firstIndex(where: { $0.t >= t }) else { return samples.last.map { Double($0.scroll) } }
      if after == 0 { return Double(samples[0].scroll) }
      let a = samples[after - 1]
      let b = samples[after]
      let f = b.t > a.t ? (t - a.t) / (b.t - a.t) : 0
      return Double(a.scroll) + (Double(b.scroll) - Double(a.scroll)) * f
    }
    guard let s0 = scroll(at: t0), let s1 = scroll(at: t1) else { return nil }
    return -(s1 - s0)
  }

  /// The numbers between `from` (the gesture's start) and `to` (rest), the lift at `lift`.
  func numbers(scenario: String, from: CFTimeInterval, lift: CFTimeInterval, to: CFTimeInterval) -> RunNumbers {
    var n = RunNumbers(subject: kind, scenario: scenario)
    let samples = recorder.samples.filter { $0.t >= from - 0.02 && $0.t <= to + 0.05 }
    guard let first = samples.first, let last = samples.last else { return n }
    let atLift = recorder.samples.last(where: { $0.t <= lift }) ?? first
    n.travel = Double(atLift.scroll - last.scroll)
    n.eventTravel = eventTravel
    n.frames = samples.count
    for s in samples {
      n.blank = max(n.blank, Double(s.blank))
      if s.blank > 0.5 { n.blankFrames += 1 }
      n.undrawn = max(n.undrawn, s.undrawn)
      if s.undrawn > 0 { n.undrawnFrames += 1 }
    }
    n.listPerFrame = (last.listSeconds - first.listSeconds) * 1000 / Double(max(1, samples.count))
    n.hostPerFrame = (last.hostSeconds - first.hostSeconds) * 1000 / Double(max(1, samples.count))
    let busy = recorder.busyPerFrame(from: from, to: to)
    n.busyP50 = Stats.median(busy)
    n.busyP95 = Stats.percentile(busy, 0.95)
    n.busyMax = busy.max() ?? 0
    let frames = screen.filter { $0.t >= from && $0.t <= to + 0.05 }
    n.screenFrames = frames.count
    for f in frames {
      n.screenBlank = max(n.screenBlank, f.blank)
      if f.blank > 0.5 { n.screenBlankFrames += 1 }
      n.screenTextless = max(n.screenTextless, f.textless)
      if f.textless > 0 { n.screenTextlessFrames += 1 }
    }
    // Motion on screen, frame to frame, from the lift on.
    let motions = ScreenMotion.motions(frames.filter { $0.t >= lift - 0.03 }) { presentedMotion($0, $1) }
    let interval = 1.0 / Double(lab.window.screen?.maximumFramesPerSecond ?? 60)
    if arguments.contains("--motions") {
      let pres = zip(samples, samples.dropFirst()).filter { $0.1.t >= lift - 0.02 }.prefix(60).map { String(format: "%.0f", -($0.1.scroll - $0.0.scroll)) }
      print("  \(kind) \(scenario) presented steps: " + pres.joined(separator: " "))
      print("  \(kind) \(scenario) screen steps (pt per frame, ms since previous): " + motions.prefix(80).map {
        String(format: "%.1f/%.0f", $0.d, $0.dt * 1000)
      }.joined(separator: " "))
    }
    // Per refresh. The capture runs a little slower than the compositor, so now and then one captured frame holds two
    // refreshes of motion: a step twice (or three times) its neighbours' is that, not a leap. A step of zero between
    // moving neighbours is a refresh where the content did not move: a frozen frame.
    let ds = motions.map(\.d)
    n.screenSteps = ds.map { ($0 * 10).rounded() / 10 }
    n.screenTimes = motions.map { (($0.t - lift) * 1000).rounded() }
    var perRefresh: [Double] = []
    var freeze = 0.0
    for i in ds.indices {
      let around = (max(0, i - 2) ... min(ds.count - 1, i + 2)).filter { $0 != i }.map { abs(ds[$0]) }.filter { $0 > 0.25 }
      let expected = Stats.median(around)
      let d = abs(ds[i])
      var k = 1.0
      if expected > 3 {
        for multiple in [2.0, 3.0] where abs(d - multiple * expected) < 0.3 * expected { k = multiple }
      }
      // Frozen: no motion on screen while the content moves before and after (within 12 frames each way, at more
      // than 3 pt a frame): a stall or a missed commit, however long.
      if d < 0.25 {
        let before = ds[max(0, i - 12) ..< i].map(abs).filter { $0 > 0.25 }
        let after = ds[min(ds.count, i + 1) ..< min(ds.count, i + 13)].map(abs).filter { $0 > 0.25 }
        if !before.isEmpty, !after.isEmpty, Stats.median(before + after) > 3 {
          n.frozenFrames += 1
          freeze += motions[i].dt
          n.longestFreeze = max(n.longestFreeze, freeze * 1000)
        } else {
          freeze = 0
        }
      } else {
        freeze = 0
      }
      let step = d / k
      perRefresh.append(step)
      if expected > 3, abs(step - expected) > max(24, 0.5 * expected), d >= 0.25 {
        // The lift's own hand-over (finger to momentum) is counted apart from leaps later in the motion.
        if motions[i].t < lift + 0.06 {
          n.extra["liftJump"] = max(n.extra["liftJump"] ?? 0, abs(step - expected))
        } else {
          n.jumps += 1
          n.worstJump = max(n.worstJump, abs(step - expected))
        }
      }
    }
    var relative: [Double] = []
    var absolute: [Double] = []
    for (a, b) in zip(perRefresh, perRefresh.dropFirst()) where max(a, b) / interval > 1000 {
      relative.append(abs(b - a) / max(a, b))
      absolute.append(abs(b - a) / interval)
    }
    n.jerkP95 = Stats.percentile(relative, 0.95)
    n.jerkMax = relative.max() ?? 0
    n.speedChangeP95 = Stats.percentile(absolute, 0.95)
    n.notes = lab.subject.notes
    return n
  }
}

@MainActor
enum Compare {
  static var results: [RunNumbers] = []
  static var listKinds: [String] {
    argument("--subjects")?.split(separator: ",").map(String.init)
      ?? ["engine-flight", "engine-coast", "nsscroll-v1", "nsscroll", "tg"]
  }

  static func run(prefixes: [String]) async {
    let all: [(String, () async -> Void)] = [
      ("fling", flings),
      ("stall", stalls),
      ("gesture", gestures),
      ("gstall", gestureStalls),
      ("sticky", sticky),
      ("hidscale", hidScale),
      ("rowcost", rowCostFlings),
      ("bake", bakeCompare),
      ("rowgest", rowCostGestures),
      ("behaviour", behaviours),
      ("catch", catches),
    ]
    print("machine: \(machine())")
    for (name, body) in all where prefixes.isEmpty || prefixes.contains(where: { name.hasPrefix($0) || $0.hasPrefix(name) }) {
      await body()
    }
    write()
  }

  static func machine() -> String {
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    let screen = NSScreen.main.map { "\($0.localizedName) \($0.maximumFramesPerSecond) Hz ×\($0.backingScaleFactor)" } ?? "?"
    return String(format: "load %.1f %.1f %.1f, main screen %@", load[0], load[1], load[2], screen)
  }

  static func record(_ n: RunNumbers) {
    results.append(n)
    print(line(n))
    if !n.extra.isEmpty || n.scenario.hasPrefix("pages") {
      print("    " + n.notes.components(separatedBy: "; ").prefix(2).joined(separator: "; ") + " " +
        n.extra.filter { !["liftJump", "stallFrom", "stallTo"].contains($0.key) }.sorted { $0.key < $1.key }
        .map { "\($0.key)=\(String(format: "%.2f", $0.value))" }.joined(separator: " "))
    }
    fflush(stdout)
  }

  static func line(_ n: RunNumbers) -> String {
    String(
      format: "%-34@ %-13@ travel %6.0f (events %6.0f)  blank %4.0f/%4.0f pt (%d/%d fr)  undrawn %d (%d fr) textless %d (%d fr)  frozen %d (%.0f ms)  jerk p95 %.2f max %.2f  jumps %d (%.0f pt)  main p50/p95/max %.1f/%.1f/%.1f ms  list %.2f ms/fr  frames %d/%d",
      n.scenario as NSString, n.subject as NSString, n.travel, n.eventTravel, n.blank, n.screenBlank, n.blankFrames,
      n.screenBlankFrames, n.undrawn, n.undrawnFrames, n.screenTextless, n.screenTextlessFrames, n.frozenFrames,
      n.longestFreeze, n.jerkP95, n.jerkMax, n.jumps, n.worstJump, n.busyP50, n.busyP95, n.busyMax, n.listPerFrame,
      n.frames, n.screenFrames
    )
  }

  static func write() {
    let url = URL(fileURLWithPath: "results/compare-\(Int(Date().timeIntervalSince1970)).json")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    if let data = try? encoder.encode(results) {
      try? data.write(to: url)
      print("wrote \(url.path) (\(results.count) runs)")
    }
  }

  // MARK: - 1. Flings: speed × row cost

  static func flings() async {
    let speeds: [Double] = [2000, 5000, 10000]
    let costs: [Double] = (argument("--costs")?.split(separator: ",").compactMap { Double($0) }) ?? [0, 1, 3, 6]
    for cost in costs {
      for kind in (cost == 0 && arguments.contains("--plain") ? ["plain"] : []) + listKinds {
        let run = Run(kind: kind, count: 3000, rowCost: cost)
        await run.wait(0.3)
        for speed in speeds + [-5000] {
          await run.centre()
          let name = "fling \(speed > 0 ? "older" : "newer") \(Int(abs(speed))) \(fmt(cost))ms"
          await run.begin(dumpName: "\(name.replacingOccurrences(of: " ", with: "_"))-\(kind)")
          let fling = Synth.fling(speed: speed)
          let start = await run.play(fling.steps)
          let rest = await run.untilRest()
          await run.end()
          record(run.numbers(scenario: name, from: start, lift: start + fling.lift, to: rest))
        }
        run.close()
        await run.wait(0.2)
      }
    }
  }

  // MARK: - 2. Main-thread stalls mid-fling

  static func stalls() async {
    let plans: [(stall: Double, delay: Double)] = [(0.05, 0.03), (0.05, 0.2), (0.15, 0.03), (0.15, 0.2)]
    for kind in (arguments.contains("--plain") ? ["plain"] : []) + listKinds {
      let run = Run(kind: kind, count: 3000, rowCost: 1)
      await run.wait(0.3)
      for speed in [5000.0, 10000] {
        for plan in plans {
          await run.centre()
          await run.begin(dumpName: "stall_\(Int(plan.stall * 1000))_\(Int(plan.delay * 1000))_\(Int(speed))-\(kind)")
          var fling = Synth.fling(speed: speed)
          let stall = plan.stall
          var window: (Double, Double)?
          fling.steps.append(Synth.Step(at: fling.lift + plan.delay, label: "stall") {
            let a = CACurrentMediaTime()
            while CACurrentMediaTime() - a < stall {}
            window = (a, CACurrentMediaTime())
          })
          let start = await run.play(fling.steps)
          let rest = await run.untilRest()
          await run.end()
          let name = "stall \(Int(plan.stall * 1000))ms@+\(Int(plan.delay * 1000)) \(Int(speed))"
          var n = run.numbers(scenario: name, from: start, lift: start + fling.lift, to: rest)
          if let (a, b) = window { noteStall(&n, from: a - start - fling.lift, to: b - start - fling.lift) }
          record(n)
        }
      }
      run.close()
      await run.wait(0.2)
    }
  }

  // MARK: - 3. Real gestures

  static func gestures() async {
    let path = argument("--gestures")
      ?? NSHomeDirectory() + "/Library/Application Support/chat.inline.InlineMac.devbuild/timeline-gestures.jsonl"
    let all = GestureRecord.load(path)
    let clean = all.filter(\.isCleanReal)
    print("gestures: \(all.count) recorded, \(clean.count) real with a full momentum stream")
    guard !clean.isEmpty else { return }
    for kind in (arguments.contains("--plain") ? ["plain"] : []) + listKinds {
      let run = Run(kind: kind, count: 6000, rowCost: 1)
      await run.wait(0.3)
      let only = argument("--only").flatMap(Int.init)
      for (i, gesture) in clean.enumerated() where only == nil || only == i {
        await run.centre()
        await run.begin(dumpName: "gesture_\(i)-\(kind)")
        let replay = Synth.replay(gesture)
        let start = await run.play(replay.steps)
        let rest = await run.untilRest()
        await run.end()
        var n = run.numbers(scenario: "gesture \(i)", from: start, lift: start + replay.lift, to: rest)
        n.eventTravel = gesture.momentumSamples.map { $0[1] }.reduce(0, +)
        n.extra["releaseVelocity"] = gesture.releaseVelocity
        record(n)
      }
      run.close()
      await run.wait(0.2)
    }
  }

  /// Does each list follow the system's momentum stream? The same real gestures with their momentum events scaled
  /// ×0.5, ×1, ×2 (run with `--delivery hid` to post them at the HID tap, as a trackpad's).
  static func hidScale() async {
    let path = argument("--gestures")
      ?? NSHomeDirectory() + "/Library/Application Support/chat.inline.InlineMac.devbuild/timeline-gestures.jsonl"
    let clean = GestureRecord.load(path).filter(\.isCleanReal)
    let picks = argument("--only")?.split(separator: ",").compactMap { Int($0) } ?? [0, 4, 8, 10, 14, 18]
    print("delivery \(EventPlayer.preferred.rawValue)")
    for kind in listKinds {
      let run = Run(kind: kind, count: 6000, rowCost: 0)
      await run.wait(0.3)
      for i in picks where i < clean.count {
        for scale in [0.5, 1, 2] {
          await run.centre()
          await run.begin(screen: false)
          let replay = Synth.replay(clean[i], momentumScale: scale)
          let start = await run.play(replay.steps)
          let rest = await run.untilRest()
          await run.end()
          var n = run.numbers(scenario: "momentum ×\(fmt(scale)) gesture \(i)", from: start, lift: start + replay.lift, to: rest)
          n.eventTravel = clean[i].momentumSamples.map { $0[1] }.reduce(0, +) * scale
          n.extra["scale"] = scale
          record(n)
        }
      }
      run.close()
      await run.wait(0.2)
    }
  }

  /// The 3–6 ms grids with the row discipline of the row-cost plan: none, plans cached once made, plans made ahead in
  /// idle slices (≤ 3 ms per run-loop turn, the direction of motion first).
  static func rowCostFlings() async {
    let modes = argument("--rows")?.split(separator: ",").compactMap { Run.Rows(rawValue: String($0)) } ?? [.none, .cache, .ahead]
    // Modes interleaved per list and cost, so a change of load on the machine falls on all three alike.
    for cost in [3.0, 6] {
      for kind in listKinds {
        for mode in modes {
          let run = Run(kind: kind, count: 3000, rowCost: cost)
          run.setRows(mode)
          await run.wait(0.3)
          for speed in [2000.0, 5000, 10000, -5000] {
            await run.centre()
            await run.wait(0.4)
            let name = "fling \(speed > 0 ? "older" : "newer") \(Int(abs(speed))) \(fmt(cost))ms rows:\(mode.rawValue)"
            await run.begin()
            let fling = Synth.fling(speed: speed)
            let start = await run.play(fling.steps)
            let rest = await run.untilRest()
            await run.end()
            var n = run.numbers(scenario: name, from: start, lift: start + fling.lift, to: rest)
            n.extra["plansOnDemand"] = Double(run.lab.chat.plansMadeOnDemand)
            n.extra["plansAhead"] = Double(run.lab.chat.plansMadeAhead)
            record(n)
          }
          run.close()
          await run.wait(0.2)
        }
      }
    }
  }

  /// Mo's real gestures with rows costing 3 ms, without and with plans prepared ahead.
  static func rowCostGestures() async {
    let path = argument("--gestures")
      ?? NSHomeDirectory() + "/Library/Application Support/chat.inline.InlineMac.devbuild/timeline-gestures.jsonl"
    let clean = GestureRecord.load(path).filter(\.isCleanReal)
    let modes = argument("--rows")?.split(separator: ",").compactMap { Run.Rows(rawValue: String($0)) } ?? [.none, .ahead]
    let costs = argument("--costs")?.split(separator: ",").compactMap { Double($0) } ?? [3]
    for cost in costs {
    for kind in listKinds {
      for mode in modes {
        let run = Run(kind: kind, count: 6000, rowCost: cost)
        run.setRows(mode)
        await run.wait(0.3)
        let only = argument("--only")?.split(separator: ",").compactMap { Int($0) }
        for (i, gesture) in clean.enumerated() where only?.contains(i) ?? true {
          await run.centre()
          await run.wait(0.4)
          await run.begin()
          let replay = Synth.replay(gesture)
          let start = await run.play(replay.steps)
          let rest = await run.untilRest()
          await run.end()
          var n = run.numbers(scenario: "gesture\(fmt(cost))ms \(i) rows:\(mode.rawValue)", from: start, lift: start + replay.lift, to: rest)
          if let brake = run.lab.subject as? BrakeSubject {
            let lift = start + replay.lift
            n.brakeTimes = brake.list.brakeTimes.filter { $0 >= start && $0 <= rest }.map { (($0 - lift) * 1000).rounded() }
          }
          n.eventTravel = gesture.momentumSamples.map { $0[1] }.reduce(0, +)
          // The lift: main-thread time in the frame that holds it and the four after (the bake, the first ticks).
          let lift = start + replay.lift
          let liftBusy = run.recorder.busyPerFrame(from: lift - 0.02, to: lift + 0.1)
          let liftFrame = run.recorder.samples.lastIndex(where: { $0.t <= lift }).map { i -> Double in
            let s = run.recorder.samples
            return i + 1 < s.count ? run.recorder.busyPerFrame(from: s[i].t, to: s[i + 1].t).first ?? 0 : 0
          } ?? 0
          n.extra["liftFrameBusy"] = liftFrame
          n.extra["liftBusyMax"] = liftBusy.prefix(6).max() ?? 0
          n.extra["liftBusySum"] = liftBusy.prefix(6).reduce(0, +)
          n.extra["restAt"] = (rest - lift) * 1000
          if let first = run.recorder.samples.last(where: { $0.t <= start }) ?? run.recorder.samples.first,
             let last = run.recorder.samples.last
          {
            n.extra["travelAll"] = Double(first.scroll - last.scroll)
          }
          record(n)
        }
        run.close()
        await run.wait(0.2)
      }
    }
    }
  }

  /// The engine's fling baked as NSScrollView's (one bake at the lift: AppKit's calculator from 0.90 × the finger's speed
  /// over its last 120 ms) against NSScrollView and today's engine, on Mo's 13 gestures and natural-decay streams.
  static func bakeCompare() async {
    let path = argument("--gestures") ?? "results/gestures-snapshot.jsonl"
    let clean = Array(GestureRecord.load(path).filter(\.isCleanReal).prefix(13))
    for kind in listKinds {
      let run = Run(kind: kind, count: 6000, rowCost: 1)
      await run.wait(0.3)
      func note(_ n: inout RunNumbers, lift: CFTimeInterval) {
        let busy = run.recorder.busyPerFrame(from: lift - 0.002, to: lift + 0.08)
        n.extra["liftBusyMax"] = busy.prefix(5).max() ?? 0
        n.extra["liftBusySum"] = busy.prefix(5).reduce(0, +)
        if let brake = run.lab.subject as? BrakeSubject {
          n.extra["bakeMs"] = (brake.list.bakeDurations.last ?? 0) * 1000
          n.extra["steerMs"] = (brake.list.steerDurations.last ?? 0) * 1000
          n.extra["steers"] = Double(brake.list.steerDurations.count)
        }
      }
      let only = argument("--only")?.split(separator: ",").compactMap { Int($0) }
      for (i, gesture) in clean.enumerated() where only?.contains(i) ?? true {
        await run.centre()
        await run.begin()
        let replay = Synth.replay(gesture)
        let start = await run.play(replay.steps)
        let rest = await run.untilRest()
        await run.end()
        var n = run.numbers(scenario: "bake gesture \(i)", from: start, lift: start + replay.lift, to: rest)
        n.eventTravel = gesture.momentumSamples.map { $0[1] }.reduce(0, +)
        note(&n, lift: start + replay.lift)
        n.extra["restAt"] = (rest - start - replay.lift) * 1000
        // Travel with the fingers': from the touch to rest.
        if let first = run.recorder.samples.last(where: { $0.t <= start }) ?? run.recorder.samples.first,
           let last = run.recorder.samples.last
        {
          n.extra["travelAll"] = Double(first.scroll - last.scroll)
        }
        record(n)
      }
      for speed in [2000.0, 5000, 10000, 20000] where !arguments.contains("--no-synthetic") {
        await run.centre()
        await run.begin()
        let fling = Synth.fling(speed: speed)
        let start = await run.play(fling.steps)
        let rest = await run.untilRest()
        await run.end()
        var n = run.numbers(scenario: "bake synthetic \(Int(speed))", from: start, lift: start + fling.lift, to: rest)
        note(&n, lift: start + fling.lift)
        n.extra["restAt"] = (rest - start - fling.lift) * 1000
        record(n)
      }
      run.close()
      await run.wait(0.2)
    }
  }

  /// Mo's real gestures with the main thread blocked 120 ms, 50 ms after the lift (in the momentum).
  static func gestureStalls() async {
    let path = argument("--gestures")
      ?? NSHomeDirectory() + "/Library/Application Support/chat.inline.InlineMac.devbuild/timeline-gestures.jsonl"
    let clean = GestureRecord.load(path).filter(\.isCleanReal)
    guard !clean.isEmpty else { return }
    for kind in (arguments.contains("--plain") ? ["plain"] : []) + listKinds {
      let run = Run(kind: kind, count: 6000, rowCost: 1)
      if let mode = argument("--rows").flatMap({ Run.Rows(rawValue: $0) }) { run.setRows(mode) }
      await run.wait(0.3)
      for (i, gesture) in clean.enumerated() {
        await run.centre()
        await run.wait(0.4)
        await run.begin(dumpName: "gstall_\(i)-\(kind)")
        var replay = Synth.replay(gesture)
        var window: (Double, Double)?
        replay.steps.append(Synth.Step(at: replay.lift + 0.05, label: "stall") {
          let a = CACurrentMediaTime()
          while CACurrentMediaTime() - a < 0.12 {}
          window = (a, CACurrentMediaTime())
        })
        let start = await run.play(replay.steps)
        let rest = await run.untilRest()
        await run.end()
        var n = run.numbers(scenario: "gesture+stall \(i)", from: start, lift: start + replay.lift, to: rest)
        if let (a, b) = window { noteStall(&n, from: a - start - replay.lift, to: b - start - replay.lift) }
        n.eventTravel = gesture.momentumSamples.map { $0[1] }.reduce(0, +)
        record(n)
      }
      run.close()
      await run.wait(0.2)
    }
  }

  /// Screen motion inside a stall (seconds after the lift) and the biggest step in the 60 ms after it.
  static func noteStall(_ n: inout RunNumbers, from: Double, to: Double) {
    let a = (from * 1000).rounded()
    let b = (to * 1000).rounded()
    n.extra["stallFrom"] = a
    n.extra["stallTo"] = b
    let inside = zip(n.screenTimes, n.screenSteps).filter { $0.0 > a + 8 && $0.0 < b }
    n.extra["movedInStall"] = inside.map { abs($0.1) }.reduce(0, +)
    n.extra["framesInStall"] = Double(inside.count)
    n.extra["leapAfterStall"] = zip(n.screenTimes, n.screenSteps).filter { $0.0 >= b && $0.0 < b + 60 }
      .map { abs($0.1) }.max() ?? 0
    // What the motion did just before the stall, per frame: the speed it should have kept.
    let before = zip(n.screenTimes, n.screenSteps).filter { $0.0 > a - 50 && $0.0 <= a }.map { abs($0.1) }
    n.extra["stepBeforeStall"] = before.isEmpty ? 0 : before.reduce(0, +) / Double(before.count)
  }

  static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}
