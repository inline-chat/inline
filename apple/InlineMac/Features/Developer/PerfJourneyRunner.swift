#if DEBUG
import AppKit
import InlineKit
import Logger

/// Debug builds only: runs the macOS perf journeys inside the app, for runs where HID events can't
/// reach it (a locked screen, an unattended machine). Use with `--perf-harness`:
///
///     --perf-journey all|switch|scroll|resize --perf-journey-label <label>
///
/// It waits for the main window plus `--perf-journey-delay` seconds (default 6, room for a profiler
/// to attach), then runs each journey through the app's real paths:
/// - switch: a sidebar click's path (history prepared off the main thread, then the route commits),
///   5 chats × 3 rounds, each until the main thread is free again (three quick main-queue hops in a
///   row, like the HID driver's AX probe);
/// - scroll: 12 flings up and 12 down with the HID driver's finger-then-momentum profile at 120 Hz,
///   moving the clip view and posting the live-scroll notifications as AppKit's threaded scrolling
///   does (synthetic scroll events can't be routed to a window on a locked screen);
/// - resize: a live resize, by posting mouse events to the window's own resize loop, −320 pt and
///   back three times.
///
/// It writes the HID driver's marks to `<tmp>/perf-journey/<label>-<scenario>.json` (the app is
/// sandboxed, so `<tmp>` is the container's temporary folder), which `report.py` reads unchanged,
/// then `<label>-done`. Progress goes to `<label>-runner.log` beside them.
@MainActor
enum PerfJourneyRunner {
  static var isRequested: Bool { CommandLine.arguments.contains("--perf-journey") }

  private static var activity: NSObjectProtocol?

  static let switchChats: [(peer: Peer, title: String)] = [
    (.user(id: 3), "Ben Ortiz"),
    (.user(id: 2), "Ava Stone"),
    (.thread(id: 801), "Design Review"),
    (.user(id: 4), "Cleo Park"),
    (.thread(id: 802), "Release Notes"),
  ]
  static let scrollChat: (peer: Peer, title: String) = (.user(id: 2), "Ava Stone")

  static func start(open: @escaping @MainActor (Peer) -> Void) {
    // Unattended runs must not be napped or throttled while the window is hidden.
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
      reason: "perf journey"
    )
    Task { @MainActor in
      await run(open: open)
    }
  }

  private static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  private static func run(open: @escaping @MainActor (Peer) -> Void) async {
    let scenario = argument("--perf-journey") ?? "all"
    let label = argument("--perf-journey-label") ?? "journey"
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-journey", isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    logURL = outDir.appendingPathComponent("\(label)-runner.log")
    try? Data().write(to: logURL!)
    note("start scenario=\(scenario)")
    let delay = Double(argument("--perf-journey-delay") ?? "6") ?? 6

    var window: NSWindow?
    for _ in 0 ..< 400 {
      window = NSApp.windows.first { $0.isVisible && $0.windowController is MainWindowController }
      if window != nil { break }
      await sleep(ms: 50)
    }
    guard let window else {
      note("no main window: \(NSApp.windows.map { "\(type(of: $0))/\(String(describing: $0.windowController))/\($0.isVisible)" })")
      try? Data().write(to: outDir.appendingPathComponent("\(label)-done"))
      return
    }
    note("window \(window.title) \(Int(window.frame.width))x\(Int(window.frame.height))")
    window.makeKeyAndOrderFront(nil)
    // Same window size every run, whatever frame the last one saved.
    window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 900, height: 640)), display: true)
    await sleep(ms: delay * 1000)

    let scenarios = scenario == "all" ? ["switch", "scroll", "resize"] : scenario.components(separatedBy: ",")
    for name in scenarios {
      // Every journey starts from the same chat.
      open(switchChats[0].peer)
      await waitForTitle(switchChats[0].title, in: window)
      _ = await settle(from: now())
      await sleep(ms: 1500)

      let cpu0 = cpuMs(), t0 = now()
      var result: [String: Any] = ["mode": name, "driver": "in-app"]
      switch name {
        case "switch": await runSwitch(window: window, open: open, into: &result)
        case "scroll": await runScroll(window: window, open: open, into: &result)
        case "resize": await runResize(window: window, into: &result)
        case "snapshot": await runSnapshot(window: window, open: open, outDir: outDir, label: label, into: &result)
        default: break
      }
      result["tailSettleMs"] = await settle(from: now())
      result["wallMs"] = now() - t0
      result["cpuMs"] = cpuMs() - cpu0
      MessageListPerfCounters.flush("journey_end")
      write(result, to: outDir.appendingPathComponent("\(label)-\(name).json"))
      note("\(name) done wall=\(Int(now() - t0)) ms")
      await sleep(ms: 3000)
    }
    note("done")
    try? Data().write(to: outDir.appendingPathComponent("\(label)-done"))
  }

  private static var logURL: URL?

  private static func note(_ line: String) {
    guard let logURL, let handle = try? FileHandle(forWritingTo: logURL) else { return }
    handle.seekToEndOfFile()
    handle.write(Data("\(Date().timeIntervalSince1970) \(line)\n".utf8))
    try? handle.close()
  }

  // MARK: - Journeys

  private static func runSwitch(
    window: NSWindow,
    open: @MainActor (Peer) -> Void,
    into result: inout [String: Any]
  ) async {
    var times: [Double] = []
    var clicksAt: [Double] = []
    var settledAt: [Double] = []
    for _ in 0 ..< 3 {
      for chat in switchChats {
        let start = now()
        clicksAt.append(epochMs())
        open(chat.peer)
        await waitForTitle(chat.title, in: window, from: start)
        times.append(await settle(from: start))
        settledAt.append(epochMs())
        await sleep(ms: 500)
      }
    }
    result["switchMs"] = times
    result["clicksAt"] = clicksAt
    result["settledAt"] = settledAt
  }

  private static func runScroll(
    window: NSWindow,
    open: @MainActor (Peer) -> Void,
    into result: inout [String: Any]
  ) async {
    open(scrollChat.peer)
    await waitForTitle(scrollChat.title, in: window)
    await sleep(ms: 1500)
    guard let scrollView = largestVisible(MessageListScrollView.self, in: window.contentView) else {
      result["error"] = "no message list"
      return
    }
    var activeMs = 0.0
    var scrolled: [Int] = []
    result["scrollStartAt"] = epochMs()
    // Up into history first. The harness only pages local history in from the server path, so the
    // list stops at the top of the loaded window; a fling that can't move turns around, so all 24
    // flings scroll (ping-pong over the loaded rows).
    var direction = 1.0
    for _ in 0 ..< 24 {
      let y0 = scrollView.contentView.bounds.origin.y
      let room = direction > 0 ? y0 : (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height - y0
      if room < 200 { direction = -direction }
      let flingStart = now()
      await fling(scrollView, delta: 30 * direction, count: 10, momentum: 40 * direction)
      activeMs += now() - flingStart
      await sleep(ms: 250)
      scrolled.append(Int(scrollView.contentView.bounds.origin.y - y0))
    }
    result["scrollEndAt"] = epochMs()
    result["activeScrollMs"] = activeMs
    // Points the list moved per fling (negative is up into history), to check the events landed.
    result["scrolledPoints"] = scrolled
    note("scrolled \(scrolled)")
  }

  /// Visual parity for row reuse: recycles cells with flings, then draws the list at fixed offsets
  /// from the bottom into `<label>-snap-<n>.png`. Two builds' snapshots should match pixel for pixel.
  private static func runSnapshot(
    window: NSWindow,
    open: @MainActor (Peer) -> Void,
    outDir: URL,
    label: String,
    into result: inout [String: Any]
  ) async {
    open(scrollChat.peer)
    await waitForTitle(scrollChat.title, in: window)
    await sleep(ms: 1500)
    guard let scrollView = largestVisible(MessageListScrollView.self, in: window.contentView) else {
      result["error"] = "no message list"
      return
    }
    for index in 0 ..< 8 {
      let direction: Double = index < 4 ? 1 : -1
      await fling(scrollView, delta: 30 * direction, count: 10, momentum: 40 * direction)
      await sleep(ms: 250)
    }
    var files: [String] = []
    for (n, offset) in [0.0, 900, 1800, 2700].enumerated() {
      let clipView = scrollView.contentView
      let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clipView.bounds.height)
      clipView.scroll(to: NSPoint(x: 0, y: max(0, maxY - offset)))
      scrollView.reflectScrolledClipView(clipView)
      await sleep(ms: 400)
      _ = await settle(from: now())
      let bounds = scrollView.bounds
      guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
      scrollView.cacheDisplay(in: bounds, to: rep)
      let name = "\(label)-snap-\(n).png"
      try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
      files.append(name)
    }
    result["snapshots"] = files
  }

  private static func runResize(window: NSWindow, into result: inout [String: Any]) async {
    let before = window.frame
    // Bottom-right corner, just inside the frame, in window coordinates.
    let corner = NSPoint(x: before.width - 3, y: 3)
    result["resizeStartAt"] = epochMs()
    post(.leftMouseDown, at: corner, in: window)
    await sleep(ms: 50)
    var steps = 0
    for _ in 0 ..< 3 {
      for dx in stride(from: 0.0, through: -320, by: -4) {
        post(.leftMouseDragged, at: NSPoint(x: corner.x + dx, y: corner.y), in: window)
        steps += 1
        await sleep(ms: 8.33)
      }
      for dx in stride(from: -320.0, through: 0, by: 4) {
        post(.leftMouseDragged, at: NSPoint(x: corner.x + dx, y: corner.y), in: window)
        steps += 1
        await sleep(ms: 8.33)
      }
    }
    post(.leftMouseUp, at: corner, in: window)
    result["resizeEndAt"] = epochMs()
    await sleep(ms: 300)
    result["steps"] = steps
    result["sizeBefore"] = "\(Int(before.width))x\(Int(before.height))"
    result["sizeAfter"] = "\(Int(window.frame.width))x\(Int(window.frame.height))"
    // The drag ends a few points off; put the frame back so the next run starts at the same size.
    window.setFrame(before, display: true)
  }

  // MARK: - Events

  private static var eventNumber = 0

  private static func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
    eventNumber += 1
    guard let event = NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: eventNumber,
      clickCount: 1,
      pressure: type == .leftMouseUp ? 0 : 1
    ) else { return }
    NSApp.postEvent(event, atStart: false)
  }

  /// A two-finger fling with the HID driver's profile: `count` finger frames of `delta`, then
  /// momentum decaying from `momentum`, at 120 Hz. Positive deltas scroll up into history.
  ///
  /// Synthetic scroll events can't be routed to a window on a locked screen, so this does what
  /// AppKit's threaded scrolling does on the main thread instead: it posts the live-scroll
  /// notifications the list tracks (`willStartLiveScroll`, `didLiveScroll`, `didEndLiveScroll`)
  /// and moves the clip view once per frame.
  private static func fling(
    _ scrollView: NSScrollView,
    delta: Double,
    count: Int,
    momentum: Double,
    decay: Double = 0.95
  ) async {
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    for _ in 0 ..< count {
      step(scrollView, delta)
      await sleep(ms: 8.33)
    }
    var d = momentum
    while abs(d) >= 1 {
      step(scrollView, d)
      await sleep(ms: 8.33)
      d *= decay
    }
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
  }

  private static func step(_ scrollView: NSScrollView, _ delta: Double) {
    let clipView = scrollView.contentView
    let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clipView.bounds.height)
    // The list's document is flipped: scrolling up into history lowers the origin.
    let y = min(max(clipView.bounds.origin.y - delta, 0), maxY)
    guard y != clipView.bounds.origin.y else { return }
    clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: y))
    scrollView.reflectScrolledClipView(clipView)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
  }

  // MARK: - Helpers

  private static func largestVisible<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
    guard let root else { return nil }
    var best: T?
    var stack = [root]
    while let view = stack.popLast() {
      if let match = view as? T, !match.isHiddenOrHasHiddenAncestor,
         match.bounds.width * match.bounds.height > (best.map { $0.bounds.width * $0.bounds.height } ?? 0)
      {
        best = match
      }
      stack.append(contentsOf: view.subviews)
    }
    return best
  }

  private static func waitForTitle(_ title: String, in window: NSWindow, from start: Double? = nil) async {
    let start = start ?? now()
    while window.title != title, now() - start < 4000 {
      await sleep(ms: 2)
    }
  }

  /// Milliseconds until the main thread is free: three main-queue hops in a row under 3 ms.
  private static func settle(from start: Double, limitMs: Double = 4000) async -> Double {
    var fast = 0
    while now() - start < limitMs {
      let t = now()
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      fast = now() - t < 3 ? fast + 1 : 0
      if fast >= 3 { return t - start }
      await sleep(ms: 4)
    }
    return limitMs
  }

  private static func sleep(ms: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000))
  }

  private static func now() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6
  }

  private static func epochMs() -> Double {
    Date().timeIntervalSince1970 * 1000
  }

  private static func cpuMs() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
    return ms(usage.ru_utime) + ms(usage.ru_stime)
  }

  private static func write(_ result: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
    try? data.write(to: url)
  }
}
#endif
