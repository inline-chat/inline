#if DEBUG
import AppKit
import InlineKit
import Logger

/// Debug builds only: runs the macOS perf journeys inside the app, for runs where HID events can't
/// reach it (a locked screen, an unattended machine). Use with `--perf-harness`:
///
///     --perf-journey all|switch|scroll|resize|read --perf-journey-label <label>
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
///   back three times;
/// - read (not in `all`, run it on its own): the whole-chat reads the list writes at the live end
///   while it rests there, and that the chat, its count and the Dock badge still clear for a message
///   arriving at the bottom, and for one that arrived while the app was away once it is back in front.
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
  static let readChat: (peer: Peer, title: String, sender: Int64) = (.user(id: 4), "Cleo Park", 4)

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
      // Every journey starts from the same chat, the last one the switch journey visits, so its
      // first switch is a real one.
      open(switchChats[switchChats.count - 1].peer)
      await waitForChat(switchChats[switchChats.count - 1].peer)
      _ = await settle(from: now())
      await sleep(ms: 1500)

      let cpu0 = cpuMs(), t0 = now()
      var result: [String: Any] = ["mode": name, "driver": "in-app"]
      switch name {
        case "switch": await runSwitch(window: window, open: open, into: &result)
        case "scroll": await runScroll(window: window, open: open, into: &result)
        case "resize": await runResize(window: window, into: &result)
        case "snapshot": await runSnapshot(window: window, open: open, outDir: outDir, label: label, into: &result)
        case "read": await runRead(window: window, open: open, into: &result)
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
        await waitForChat(chat.peer, from: start)
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
    await waitForChat(scrollChat.peer)
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

  /// Live-end reads. The chat's history is certified first, as a latest page from the server would,
  /// so the list's bottom is the chat's live end (the seed leaves every chat unknown); that is why
  /// this journey runs on its own. `AppActivityMonitor.simulate` stands in for the app leaving and
  /// coming back to the front, which an unattended run can't do without taking the screen.
  private static func runRead(
    window: NSWindow,
    open: @MainActor (Peer) -> Void,
    into result: inout [String: Any]
  ) async {
    let chat = readChat
    do {
      try PerfHarnessFixture.certifyHistory(peer: chat.peer)
    } catch {
      result["error"] = "certify: \(error)"
      return
    }
    AppActivityMonitor.shared.simulate(.active)
    open(chat.peer)
    await waitForChat(chat.peer)
    await sleep(ms: 1500)
    _ = await settle(from: now())
    guard let scrollView = largestVisible(MessageListScrollView.self, in: window.contentView) else {
      result["error"] = "no message list"
      return
    }
    func reads() -> Int { MessageListPerfCounters.liveEndReads }
    func passes() -> String {
      "live=\(MessageListPerfCounters.liveEndPasses) history=\(MessageListPerfCounters.historyPasses)"
    }
    func state() -> String {
      guard let state = try? PerfHarnessFixture.readState(peer: chat.peer) else { return "none" }
      return "unread=\(state.unreadCount) readMax=\(state.readInboxMaxId) mark=\(state.unreadMark)"
    }
    func badge() -> String { NSApp.dockTile.badgeLabel ?? "" }
    /// Within 3 s.
    func until(_ condition: () -> Bool) async -> Bool {
      for _ in 0 ..< 150 {
        if condition() { return true }
        await sleep(ms: 20)
      }
      return false
    }
    func readThrough(_ id: Int64) async -> Bool {
      await until {
        guard let state = try? PerfHarnessFixture.readState(peer: chat.peer) else { return false }
        return state.unreadCount == 0 && state.readInboxMaxId >= id
      }
    }
    /// A gesture that lifts the list 12 pt off where it rests and puts it back, inside the follow
    /// zone. Relative to the resting origin: `step` clamps to the document's end, which sits a
    /// bottom inset short of the list's own bottom.
    func nudge() async {
      let clipView = scrollView.contentView
      let resting = clipView.bounds.origin.y
      NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
      for lift in [2.0, 4, 6, 8, 10, 12, 10, 8, 6, 4, 2, 0] {
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: resting - lift))
        scrollView.reflectScrolledClipView(clipView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        await sleep(ms: 8.33)
      }
      NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }
    /// Nudges, then row reloads, as a list resting at the bottom gets them.
    func rest(nudges: Int, reloads: Int) async {
      for _ in 0 ..< nudges {
        await nudge()
        await sleep(ms: 350)
      }
      for _ in 0 ..< reloads {
        MessagesPublisher.shared.messagesReload(peer: chat.peer, animated: false)
        await sleep(ms: 300)
      }
    }

    result["openReads"] = reads()
    result["openPasses"] = passes()
    result["openState"] = state()
    var before = reads()
    await rest(nudges: 8, reloads: 6)
    result["restingReads"] = reads() - before
    result["restingPasses"] = passes()

    // A message arrives at the bottom. It is read before the Dock, which holds increases for
    // 500 ms, would show it.
    before = reads()
    guard let arrived = try? PerfHarnessFixture.receiveMessage(peer: chat.peer, from: chat.sender) else {
      result["error"] = "no chat to receive in"
      return
    }
    result["arrivalRead"] = await readThrough(arrived)
    await sleep(ms: 700)
    result["arrivalReads"] = reads() - before
    result["arrivalPasses"] = passes()
    result["arrivalState"] = state()
    result["arrivalBadge"] = badge()

    // One arrives while the app is away: nothing reads it until the app is back in front.
    AppActivityMonitor.shared.simulate(.inactive)
    before = reads()
    guard let away = try? PerfHarnessFixture.receiveMessage(peer: chat.peer, from: chat.sender) else {
      result["error"] = "no chat to receive in"
      return
    }
    result["awayBadgeShown"] = await until { badge() == "1" }
    result["awayState"] = state()
    result["awayBadge"] = badge()
    result["awayPasses"] = passes()
    AppActivityMonitor.shared.simulate(.active)
    result["frontRead"] = await readThrough(away)
    result["frontBadgeCleared"] = await until { badge().isEmpty }
    result["frontReads"] = reads() - before
    result["frontPasses"] = passes()
    result["frontState"] = state()
    result["frontBadge"] = badge()

    before = reads()
    await rest(nudges: 4, reloads: 3)
    result["restingAfterReads"] = reads() - before
    result["restingAfterPasses"] = passes()
    note("read \(result.filter { $0.key.hasSuffix("Reads") || $0.key.hasSuffix("Read") })")
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
    await waitForChat(scrollChat.peer)
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

  /// Until the window's route shows `peer`. Its title isn't the chat name for every chat (threads).
  private static func waitForChat(_ peer: Peer, from start: Double? = nil) async {
    let start = start ?? now()
    while MainWindowController.all.first?.scriptingPrimaryChat != peer, now() - start < 4000 {
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
