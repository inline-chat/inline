import AppKit
import QuartzCore
import TimelineAppKit
import TimelineCore

// The behaviour suite: every expected behaviour of the list is a case that drives a lab chat window the way a reader
// would (trackpad gestures, wheel notches, keys, clicks, data changes, composer and window changes), records what is on
// screen every display frame from the presentation layers, and checks it against numbers. No post-processing: each
// case says PASS or FAIL with what it measured.
//
//   swift run TimelineMacLab --suite [prefix…]   runs the cases whose id starts with a prefix (all by default)

// MARK: - Bench

/// A lab chat window for one case.
@MainActor
final class Bench {
  let window: NSWindow
  let view: LabChatView
  var list: TimelineListView<Int> { view.list }
  var chat: LabChat { view.chat }
  let clock: FrameClock
  private(set) var recorder: Recorder?

  struct Options {
    var count = 600
    var size = NSSize(width: 520, height: 760)
    var rowCost: Double = 0
    var header = true
    var coverage = TimelineCoverage(reachesOldest: true, reachesNewest: true)
    var groupRun = 4
    /// Minimal style: avatars at their group's top, kept to the top edge.
    var topPins = false
  }

  init(_ options: Options = Options()) {
    // A/B: updates while scrolling animated as at rest (the engine's default lands them at once, as Telegram does).
    TimelineListOptions.animatesUpdatesWhileScrolling = ProcessInfo.processInfo.environment["TL_ANIMATE_UPDATES_WHILE_SCROLLING"] != nil
    // A/B: a reorder slides to its new place instead of landing there fading in (the engine's default, Telegram's).
    TimelineListOptions.fadesMoves = ProcessInfo.processInfo.environment["TL_SLIDE_MOVES"] == nil
    window = NSWindow(
      contentRect: NSRect(origin: LabPlacement.origin, size: options.size), styleMask: [.titled, .resizable],
      backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.level = .floating
    let chat = LabChat(count: options.count, groupRun: options.groupRun)
    chat.topPins = options.topPins
    chat.rowCost = options.rowCost
    view = LabChatView(chat: chat, floatingHeader: options.header)
    view.frame = window.contentView!.bounds
    view.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(view)
    window.orderFrontRegardless()
    view.layoutSubtreeIfNeeded()
    clock = FrameClock(view: view)
    view.start(coverage: options.coverage)
  }

  func close() {
    recorder = nil
    clock.stop()
    window.orderOut(nil)
    window.close()
  }

  // MARK: Waiting

  func frames(_ count: Int) async {
    for _ in 0 ..< max(1, count) { await clock.next() }
  }

  func wait(_ seconds: Double) async {
    let end = CACurrentMediaTime() + seconds
    while CACurrentMediaTime() < end { await clock.next() }
  }

  /// Until nothing moves: no fling, no trackpad, no animation on the content or a row, for two frames in a row.
  func untilRest(timeout: Double = 6) async {
    let end = CACurrentMediaTime() + timeout
    var still = 0
    while CACurrentMediaTime() < end {
      await clock.next()
      if isStill() { still += 1 } else { still = 0 }
      if still >= 2 { return }
    }
  }

  static func animates(_ layer: CALayer) -> Bool {
    if layer.isHidden { return false }
    if !(layer.animationKeys() ?? []).isEmpty { return true }
    return (layer.sublayers ?? []).contains { animates($0) }
  }

  func isStill() -> Bool {
    if list.isMoving { return false }
    // Anything animating anywhere in the list (content, rows, their insides, pins, the floating date, the knob)
    // or the composer. Fill-forwards removal animations count until the row is retired.
    if let layer = list.layer, Self.animates(layer) { return false }
    if let layer = view.composer.layer, Self.animates(layer) { return false }
    return list.diagnostics.lingeringCount == 0
  }

  // MARK: Recording

  func startRecording() {
    let recorder = Recorder(bench: self)
    self.recorder = recorder
    clock.onFrame = { [weak recorder] timestamp in recorder?.sample(timestamp) }
    recorder.sample(CACurrentMediaTime())
  }

  @discardableResult
  func stopRecording() -> Recording {
    clock.onFrame = nil
    let recording = recorder?.recording ?? Recording(frames: [])
    recorder = nil
    return recording
  }

  /// Records while `body` runs and, with `settle`, until the list rests (not while fingers hold it).
  func record(settle: Bool = true, _ body: () async -> Void) async -> Recording {
    startRecording()
    await body()
    if settle { await untilRest() }
    await frames(2)
    return stopRecording()
  }

  // MARK: Input

  /// Hands an event to the list as AppKit would, stamped now (velocity is measured from event times).
  func send(_ cgEvent: CGEvent) {
    cgEvent.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    let center = list.convert(NSPoint(x: list.bounds.midX, y: list.bounds.midY), to: nil)
    let screen = window.convertPoint(toScreen: center)
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    cgEvent.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
    cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
    guard let event = NSEvent(cgEvent: cgEvent) else { return }
    list.scrollWheel(with: event)
  }

  func sleep(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9))
  }

  /// Plays events at their times on a 1 ms timer (as the native reference runs did), stamping each as it goes.
  func play(_ steps: [(at: Double, event: CGEvent)]) async {
    guard !steps.isEmpty else { return }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      var pending = steps.sorted { $0.at < $1.at }
      let start = CACurrentMediaTime()
      let timer = Timer(timeInterval: 0.001, repeats: true) { timer in
        MainActor.assumeIsolated {
          let elapsed = CACurrentMediaTime() - start
          while let first = pending.first, first.at <= elapsed {
            pending.removeFirst()
            self.send(first.event)
          }
          if pending.isEmpty {
            timer.invalidate()
            done.resume()
          }
        }
      }
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  /// A trackpad gesture: a touch, `count` moves of `dy` (positive: content moves down, towards older rows) every
  /// `interval`, then the lift. `momentum` also plays the momentum events the system sends after a lift (the list
  /// must ignore them). `dx` adds sideways travel to every move.
  func gesture(
    dy: Double, count: Int, interval: Double = 1.0 / 120, dx: Double = 0, lift: Bool = true, momentum: Bool = false,
    touch: Bool = true
  ) async {
    var steps: [(at: Double, event: CGEvent)] = []
    var t = 0.0
    if touch {
      steps.append((t, Synth.trackpad(0, phase: .mayBegin)))
      t += interval
    }
    for i in 0 ..< count {
      steps.append((t, Synth.trackpadXY(dx: dx, dy: dy, phase: i == 0 && touch ? .began : .changed)))
      t += interval
    }
    if lift {
      steps.append((t, Synth.trackpad(0, phase: .ended)))
      if momentum {
        var d = dy * 1.5
        t += interval
        steps.append((t, Synth.trackpad(d, phase: .none, momentum: .begin)))
        for _ in 0 ..< 30 {
          t += 1.0 / 60
          d *= 0.95
          steps.append((t, Synth.trackpad(d, phase: .none, momentum: .continue)))
        }
        t += 1.0 / 60
        steps.append((t, Synth.trackpad(0, phase: .none, momentum: .end)))
      }
    }
    await play(steps)
  }

  /// A touch on the trackpad with no movement: stops a fling; `lift` lets go again.
  func touch(lift: Bool = true) async {
    send(Synth.trackpad(0, phase: .mayBegin))
    guard lift else { return }
    await sleep(0.05)
    send(Synth.trackpad(0, phase: .cancelled))
  }

  func wheel(lines: Int32) {
    send(Synth.wheel(lines: lines))
  }

  // MARK: Chat changes

  func arrive(_ text: String? = nil, sender: Int = 1, timing: TimelineTiming = .standard) -> Int {
    let id = chat.append(text ?? "new message \(chat.ids.count) " + String(repeating: "arriving ", count: 3), sender: sender)
    list.apply(TimelineTransaction(rows: chat.ids, timing: timing))
    return id
  }

  func prependPage(_ count: Int = 50, coverage: TimelineCoverage? = nil) {
    _ = chat.prepend(count)
    list.apply(TimelineTransaction(rows: chat.ids, coverage: coverage, arrives: false))
  }

  func setText(_ id: Int, _ text: String, timing: TimelineTiming = .standard) {
    chat.setText(id, text)
    list.apply(TimelineTransaction(changed: [id], timing: timing))
  }

  func delete(_ id: Int, timing: TimelineTiming = .standard) {
    chat.delete(id)
    list.apply(TimelineTransaction(rows: chat.ids, timing: timing))
  }

  func resize(width: CGFloat? = nil, height: CGFloat? = nil) {
    var frame = window.frame
    if let width { frame.size.width = width }
    if let height {
      let delta = height - (window.contentView?.bounds.height ?? height)
      frame.size.height += delta
      frame.origin.y -= delta
    }
    window.setFrame(frame, display: true)
    view.layoutSubtreeIfNeeded()
  }

  func stall(_ seconds: Double) {
    let end = CACurrentMediaTime() + seconds
    while CACurrentMediaTime() < end {}
  }

  // MARK: Reading the screen

  var usableTop: CGFloat { list.topInset }
  var usableBottom: CGFloat { list.bounds.height - list.bottomInset }

  /// The lowest row whose top is in the usable area: what a reader is looking at.
  func readingRow() -> Int? {
    let layout = list.timelineLayout
    return layout.placements.last(where: { $0.y < usableBottom - 20 && $0.y >= usableTop && !(chat.row($0.id)?.isDay ?? true) })?.id
  }

  /// A message row in the middle of the screen.
  func middleRow() -> Int? {
    let mid = (usableTop + usableBottom) / 2
    return list.timelineLayout.placements.first(where: { $0.maxY > mid && !(chat.row($0.id)?.isDay ?? true) })?.id
  }

  func shown(_ id: Int) -> CGRect? { list.presentedFrame(for: id) }

  /// The settled frame (what the next frame shows when nothing animates).
  func settled(_ id: Int) -> CGRect? { list.frame(for: id) }

  /// Lets the change just made reach the screen, so presented values read it.
  func settle() async { await frames(2) }

  /// How far the content has scrolled on screen (positive: moved down, towards older rows), from the presented
  /// content origin.
  var scrolled: CGFloat { -list.diagnostics.presentedScrollPosition }

  var newest: Int { chat.ids.last! }
}

// MARK: - Frame clock

@MainActor
final class FrameClock: NSObject {
  private var link: CADisplayLink?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  var onFrame: ((CFTimeInterval) -> Void)?
  private(set) var gaps: [Double] = []
  private var last: CFTimeInterval = 0

  init(view: NSView) {
    super.init()
    let link = view.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }

  @objc private func tick(_ link: CADisplayLink) {
    if last > 0 { gaps.append((link.timestamp - last) * 1000) }
    last = link.timestamp
    onFrame?(link.timestamp)
    let waiting = waiters
    waiters = []
    for waiter in waiting { waiter.resume() }
  }

  func next() async {
    guard link != nil else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

// MARK: - Recording

/// What was on screen at one display frame, in the list's coordinates, from the presentation layers.
struct Frame {
  var t: Double
  var origin: CGFloat
  var rows: [Int: CGRect]
  /// What each row shows: a message's bubble, a day row's whole row.
  var bubbles: [Int: CGRect]
  var avatars: [Int: CGRect]
  /// The floating header's frame and how visible it is (its own opacity times its container's).
  var header: CGRect?
  var headerAlpha: CGFloat
  var headerTitle: String?
  var composerTop: CGFloat
  var usableTop: CGFloat
  var usableBottom: CGFloat
  var flinging: Bool
  var tracking: Bool
  var placed: Int
  /// A far jump's slide was running (the floating date is hidden by design).
  var sliding = false
  /// Pictures of moved rows at their old places, fading out, by the row's id.
  var ghosts: [(id: Int, frame: CGRect)] = []
}

struct Recording {
  var frames: [Frame]

  var duration: Double { (frames.last?.t ?? 0) - (frames.first?.t ?? 0) }

  /// A row's screen top over the frames it showed in.
  func tops(_ id: Int) -> [Double] { frames.compactMap { $0.rows[id].map { Double($0.minY) } } }

  /// How far a row's screen top moved between frames, largest.
  func largestStep(_ id: Int) -> Double {
    let values = tops(id)
    guard values.count > 1 else { return 0 }
    return zip(values, values.dropFirst()).map { abs($1 - $0) }.max() ?? 0
  }

  /// The largest one-frame spike in a row's motion: a step larger than both its neighbours by this much (a snap). A
  /// change of speed that lasts (a spring pulled harder) is not a spike.
  func largestSpike(_ id: Int) -> Double {
    let values = tops(id)
    guard values.count > 3 else { return 0 }
    let steps = zip(values, values.dropFirst()).map { abs($1 - $0) }
    var worst = 0.0
    for i in 1 ..< steps.count - 1 {
      worst = max(worst, min(steps[i] - steps[i - 1], steps[i] - steps[i + 1]))
    }
    return worst
  }

  /// The largest change in a row's frame-to-frame step: a jump in an otherwise smooth motion shows here.
  func largestJerk(_ id: Int) -> Double {
    let values = tops(id)
    guard values.count > 2 else { return 0 }
    let steps = zip(values, values.dropFirst()).map { $1 - $0 }
    return zip(steps, steps.dropFirst()).map { abs($1 - $0) }.max() ?? 0
  }

  /// The largest distance on screen between consecutive shown rows (a blank strip, positive) or overlap (negative),
  /// over all frames, among rows in the usable area.
  func seams(within ids: (Int) -> Bool = { _ in true }) -> (gap: Double, overlap: Double) {
    var gap = 0.0
    var overlap = 0.0
    for frame in frames {
      let sorted = frame.rows.filter { ids($0.key) }.sorted { $0.value.minY < $1.value.minY }
      for (a, b) in zip(sorted, sorted.dropFirst()) {
        guard b.value.minY < frame.usableBottom, a.value.maxY > frame.usableTop else { continue }
        let d = Double(b.value.minY - a.value.maxY)
        gap = max(gap, d)
        overlap = max(overlap, -d)
      }
    }
    return (gap, overlap)
  }

  /// What a reader sees between messages: bubbles never overlap (beyond `slack`), and the space between two neighbours
  /// never leaves the range between its value before and after the change (no gap opening up and closing again).
  /// `acrossExcluded`: an excluded row's neighbours pair up across it (a deleted row's place closing). Off, a seam is
  /// between neighbours as shown and the excluded rows' seams are left out: across a row that stays on screen, the
  /// "gap" is that row's own height (a row that grows and rewraps narrower for 0.1 s read as a 10.6 pt opening in
  /// `update.widthDuringGrow`, with every seam joined).
  func bubbleSeams(excluding: Set<Int> = [], acrossExcluded: Bool = true) -> (overlap: Double, gapExcess: Double) {
    guard let first = frames.first, let last = frames.last else { return (0, 0) }
    func pairs(_ frame: Frame) -> [(Int, Int, Double)] {
      let sorted = frame.bubbles.filter { acrossExcluded ? !excluding.contains($0.key) : true }.sorted { $0.value.minY < $1.value.minY }
      return zip(sorted, sorted.dropFirst()).compactMap { a, b in
        guard acrossExcluded || !excluding.contains(a.key) && !excluding.contains(b.key) else { return nil }
        guard b.value.minY < frame.usableBottom, a.value.maxY > frame.usableTop else { return nil }
        return (a.key, b.key, Double(b.value.minY - a.value.maxY))
      }
    }
    var before: [String: Double] = [:]
    var after: [String: Double] = [:]
    for (a, b, d) in pairs(first) { before["\(a)-\(b)"] = d }
    for (a, b, d) in pairs(last) { after["\(a)-\(b)"] = d }
    var overlap = 0.0
    var excess = 0.0
    for frame in frames {
      for (a, b, d) in pairs(frame) {
        overlap = max(overlap, -d)
        let key = "\(a)-\(b)"
        guard let x = before[key], let y = after[key] else { continue }
        excess = max(excess, d - max(x, y), min(x, y) - d)
      }
    }
    return (overlap, excess)
  }

  /// The largest blank strip inside the usable area in any frame (no row covering it), excluding the ends of the
  /// content.
  func blank(oldest: Int, newest: Int) -> Double {
    blankWorst(oldest: oldest, newest: newest).value
  }

  /// The largest blank strip and where it was: frame time, which edge or which pair of rows.
  func blankWorst(oldest: Int, newest: Int) -> (value: Double, at: String) {
    var worst = 0.0
    var at = ""
    func consider(_ value: CGFloat, _ frame: Frame, _ place: @autoclosure () -> String) {
      guard Double(value) > worst else { return }
      worst = Double(value)
      at = "t \(String(format: "%.3f", frame.t)) \(place())"
    }
    for frame in frames {
      let sorted = frame.rows.sorted { $0.value.minY < $1.value.minY }
      guard let first = sorted.first, let last = sorted.last else { continue }
      if first.key != oldest { consider(first.value.minY - frame.usableTop, frame, "top, first \(first.key) at \(first.value.minY)") }
      if last.key != newest { consider(frame.usableBottom - last.value.maxY, frame, "bottom, last \(last.key) ends \(last.value.maxY)") }
      for (a, b) in zip(sorted, sorted.dropFirst()) {
        let top = max(a.value.maxY, frame.usableTop)
        let bottom = min(b.value.minY, frame.usableBottom)
        if bottom > top { consider(bottom - top, frame, "between \(a.key) \(a.value) and \(b.key) \(b.value)") }
      }
    }
    return (worst, at)
  }
}

@MainActor
final class Recorder {
  private unowned let bench: Bench
  private(set) var recording = Recording(frames: [])
  private let t0 = CACurrentMediaTime()

  init(bench: Bench) { self.bench = bench }

  func sample(_ timestamp: CFTimeInterval) {
    let list = bench.list
    var rows: [Int: CGRect] = [:]
    var bubbles: [Int: CGRect] = [:]
    var avatars: [Int: CGRect] = [:]
    for (id, view) in list.shownViews {
      if let frame = list.presentedFrame(for: id) { rows[id] = frame }
      if let row = view as? LabRowView {
        if !row.bubble.isHidden, let frame = list.presentedFrame(of: row.bubble) {
          bubbles[id] = frame
        } else if let frame = rows[id] {
          bubbles[id] = frame.insetBy(dx: 0, dy: 6)
        }
      }
      if let row = view as? LabRowView, !row.avatar.isHidden, let frame = list.presentedFrame(of: row.avatar) {
        avatars[id] = frame
      }
    }
    var header: CGRect?
    var headerAlpha: CGFloat = 0
    var title: String?
    if let floating = list.floatingHeader, let layer = floating.view.layer {
      let presented = layer.presentation() ?? layer
      let container = floating.view.superview?.layer.map { $0.presentation() ?? $0 }
      headerAlpha = CGFloat(presented.opacity) * CGFloat(container?.opacity ?? 1)
      if presented.opacity > 0.01 { header = list.presentedFrame(of: floating.view) }
      title = (floating.view as? LabDayPill)?.title
    }
    let composer = bench.view.composer.layer.map { ($0.presentation() ?? $0).frame.minY } ?? 0
    let composerTop = bench.view.convert(NSPoint(x: 0, y: composer), to: list).y
    let diagnostics = list.diagnostics
    recording.frames.append(Frame(
      t: CACurrentMediaTime() - t0, origin: diagnostics.presentedScrollPosition, rows: rows, bubbles: bubbles,
      avatars: avatars,
      header: header, headerAlpha: headerAlpha, headerTitle: title, composerTop: composerTop,
      usableTop: bench.usableTop, usableBottom: bench.usableBottom, flinging: diagnostics.isFlinging,
      tracking: diagnostics.isTracking, placed: diagnostics.placedCount, sliding: diagnostics.isSliding,
      ghosts: list.ghostFrames
    ))
  }
}

// MARK: - Cases and results

struct Metric: Encodable {
  var name: String
  var value: Double
  /// What passes, in words ("<= 0.5").
  var expect: String
  var pass: Bool
  var unit: String
}

struct CaseResult: Encodable {
  var id: String
  var area: String
  var behaviour: String
  var metrics: [Metric]
  var notes: [String]
  var pass: Bool { metrics.allSatisfy(\.pass) && !metrics.isEmpty }
  var seconds: Double
}

/// What a case checks, collected as it runs.
@MainActor
final class Checks {
  private(set) var metrics: [Metric] = []
  private(set) var notes: [String] = []

  func atMost(_ name: String, _ value: Double, _ limit: Double, unit: String = "pt") {
    metrics.append(Metric(name: name, value: value, expect: "<= \(fmt(limit))", pass: value <= limit + 1e-9, unit: unit))
  }

  func atLeast(_ name: String, _ value: Double, _ limit: Double, unit: String = "pt") {
    metrics.append(Metric(name: name, value: value, expect: ">= \(fmt(limit))", pass: value >= limit - 1e-9, unit: unit))
  }

  func near(_ name: String, _ value: Double, _ target: Double, within: Double, unit: String = "pt") {
    metrics.append(Metric(
      name: name, value: value, expect: "\(fmt(target)) ± \(fmt(within))", pass: abs(value - target) <= within + 1e-9, unit: unit
    ))
  }

  func that(_ name: String, _ condition: Bool) {
    metrics.append(Metric(name: name, value: condition ? 1 : 0, expect: "true", pass: condition, unit: ""))
  }

  func note(_ text: String) { notes.append(text) }
}

func fmt(_ value: Double) -> String {
  if value == value.rounded(), abs(value) < 1e6 { return String(Int(value)) }
  return String(format: "%.2f", value)
}

struct BehaviourCase {
  var id: String
  var area: String
  var behaviour: String
  var options: Bench.Options = Bench.Options()
  var run: @MainActor (Bench, Checks) async -> Void
}

// MARK: - Runner

@MainActor
enum SuiteRunner {
  static func run(prefixes: [String]) async {
    let cases = SuiteCases.all.filter { c in prefixes.isEmpty || prefixes.contains { c.id.hasPrefix($0) } }
    var results: [CaseResult] = []
    print("suite: \(cases.count) cases")
    for c in cases {
      let began = CACurrentMediaTime()
      let bench = Bench(c.options)
      await bench.frames(3)
      let checks = Checks()
      await c.run(bench, checks)
      bench.close()
      let result = CaseResult(
        id: c.id, area: c.area, behaviour: c.behaviour, metrics: checks.metrics, notes: checks.notes,
        seconds: CACurrentMediaTime() - began
      )
      results.append(result)
      let failing = result.metrics.filter { !$0.pass }.map { "\($0.name)=\(fmt($0.value))\($0.unit) (want \($0.expect))" }
      print("\(result.pass ? "PASS" : "FAIL") \(c.id)\(failing.isEmpty ? "" : "  " + failing.joined(separator: "; "))")
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    write(results)
    let passed = results.filter(\.pass).count
    print("suite: \(passed)/\(results.count) pass")
  }

  static func write(_ results: [CaseResult]) {
    // TL_SUITE_OUT: a run of its own (labs running side by side would overwrite each other's latest results).
    let dir = ProcessInfo.processInfo.environment["TL_SUITE_OUT"] ?? "results/suite"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(results) { try? data.write(to: URL(fileURLWithPath: "\(dir)/latest.json")) }
    var md = "# Timeline behaviour suite\n\n\(results.filter(\.pass).count)/\(results.count) pass\n\n"
    var area = ""
    for result in results {
      if result.area != area {
        area = result.area
        md += "\n## \(area)\n\n| | Case | Behaviour | Measured |\n| --- | --- | --- | --- |\n"
      }
      let measured = result.metrics.map { "\($0.pass ? "" : "**")\($0.name) \(fmt($0.value))\($0.unit) (\($0.expect))\($0.pass ? "" : "**")" }
        .joined(separator: "<br>")
      let notes = result.notes.isEmpty ? "" : "<br>_" + result.notes.joined(separator: "; ") + "_"
      md += "| \(result.pass ? "✅" : "❌") | `\(result.id)` | \(result.behaviour) | \(measured)\(notes) |\n"
    }
    try? md.write(toFile: "\(dir)/latest.md", atomically: true, encoding: .utf8)
  }
}
