#if DEBUG
import AppKit
import GRDB
import InlineMessageLayout
import InlineKit
import QuartzCore
import TimelineAppKit

/// Debug builds only: scripted journeys through the NEW message list (`TimelineMessageListAppKit`) on the perf
/// harness's seeded chats, signed out and without a server, so list and message-view changes can be measured and
/// looked at one at a time. Run it with `scripts/macos/timeline-journey/run.sh` (see its README), or launch
/// Inline Debug with:
///
///     --perf-harness -experimental.macTimelineList YES --timeline-journey all|<name>,<name> \
///       --timeline-journey-label <label> [--timeline-journey-frame x,y,w,h] [--timeline-journey-captures external|inapp|none]
///
/// `-experimental.macTimelineList YES` goes to the argument domain, so the stored setting is untouched.
///
/// Each scenario writes one JSON line to `<tmp>/timeline-journey/<label>.jsonl` (the app is sandboxed: `<tmp>` is
/// the container's temporary folder) and window captures beside it, `<label>-<scenario>-<tag>.png`. Captures are
/// real screen pixels when an external capturer serves the `.request` files (`run.sh` does, with
/// `screencapture -l`), else the window's own drawing. `<label>-done` marks the end; progress is in
/// `<label>-runner.log`.
///
/// Every scenario's frames are measured the same way (`Journey.measure`): a display link on the window counts
/// frames and hitches (an interval over 1.5× the refresh: the main thread missed a frame), the engine's own
/// diagnostics give its work (performs, rows made, attach time), and per-frame probes give what the scenario
/// checks (blank strips between rows, how far the reading row or the newest row's bottom moved).
///
/// To add a scenario: write `static func myScenario(_ j: Journey) async` that drives the app through its real
/// paths (fixture writes in `PerfHarnessFixture`, input as events into the list), records numbers into
/// `j.result`, and captures what is worth looking at; then add it to `scenarios`.
@MainActor
enum TimelineJourneyRunner {
  typealias Row = ChatRowListViewModel.Row
  typealias List = TimelineListView<Row>

  static var isRequested: Bool { CommandLine.arguments.contains("--timeline-journey") }

  struct Scenario {
    let name: String
    let run: @MainActor (Journey) async -> Void
  }

  static let scenarios: [Scenario] = [
    Scenario(name: "open", run: runOpen),
    Scenario(name: "fling", run: runFling),
    Scenario(name: "drag", run: runDrag),
    Scenario(name: "stream", run: runStream),
    Scenario(name: "stream-reading", run: runStreamReading),
    Scenario(name: "stream-rich", run: runStreamRich),
    Scenario(name: "stream-switch", run: runStreamSwitch),
    Scenario(name: "react", run: runReact),
    Scenario(name: "arrive-avatar", run: runArriveAvatar),
    Scenario(name: "menu-hold", run: runMenuHold),
    Scenario(name: "ax", run: runAccessibility),
    Scenario(name: "top-avatar", run: runTopAvatar),
    Scenario(name: "day-pill", run: runDayPill),
    Scenario(name: "resize-rich", run: runResizeRich),
    Scenario(name: "resize-text", run: runResizeText),
    Scenario(name: "reply", run: runReply),
    Scenario(name: "resize-passage", run: runResizePassage),
    Scenario(name: "stream-long", run: runStreamLong),
    Scenario(name: "composer-history", run: runComposerHistory),
    Scenario(name: "resize-passage-rich", run: runResizePassageRich),
    Scenario(name: "edit", run: runEdit),
    Scenario(name: "delete", run: runDelete),
    Scenario(name: "send", run: runSend),
    Scenario(name: "arrive", run: runArrive),
    Scenario(name: "resize", run: runResize),
    Scenario(name: "composer", run: runComposer),
    Scenario(name: "appearance", run: runAppearance),
    Scenario(name: "rich", run: runRich),
    Scenario(name: "jump-button", run: runJumpButton),
    Scenario(name: "select-text", run: runSelectText),
    Scenario(name: "select-messages", run: runSelectMessages),
    Scenario(name: "rich-select", run: runRichSelect),
    Scenario(name: "media", run: runMedia), // media
  ]

  /// The long chat (2,500 messages), a short one at its end, and the switch order.
  static let longChat: Peer = .user(id: 2) // Ava Stone
  static let shortChat: Peer = .user(id: 4) // Cleo Park
  static let sendChat: Peer = .user(id: 3) // Ben Ortiz
  static let switchChats: [Peer] = [.user(id: 3), .user(id: 2), .thread(id: 801), .user(id: 4), .thread(id: 802)]
  /// Rich agent replies (headings, lists, code, quotes, tables) with a pinned message.
  static let richChat: Peer = .thread(id: PerfHarnessFixture.richChatId)
  static let mediaChat: Peer = .thread(id: PerfHarnessFixture.mediaChatId) // media

  private static var activity: NSObjectProtocol?

  static func start(open: @escaping @MainActor (Peer) -> Void) {
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "timeline journey"
    )
    Task { @MainActor in await run(open: open) }
  }

  static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
  }

  private static func run(open: @escaping @MainActor (Peer) -> Void) async {
    let requested = argument("--timeline-journey") ?? "all"
    let label = argument("--timeline-journey-label") ?? "timeline"
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-journey", isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let log = outDir.appendingPathComponent("\(label)-runner.log")
    try? Data().write(to: log)
    try? FileManager.default.removeItem(at: outDir.appendingPathComponent("\(label).jsonl"))
    try? FileManager.default.removeItem(at: outDir.appendingPathComponent("\(label)-done"))

    var window: NSWindow?
    for _ in 0 ..< 400 {
      window = NSApp.windows.first { $0.isVisible && $0.windowController is MainWindowController }
      if window != nil { break }
      await Journey.sleep(ms: 50)
    }
    let names = requested == "all" ? scenarios.map(\.name) : requested.components(separatedBy: ",")
    guard let window else {
      try? Data("no main window\n".utf8).write(to: log)
      try? Data().write(to: outDir.appendingPathComponent("\(label)-done"))
      return
    }
    // Slot APP of ~/dev/inline-chat/.lab-screen (the built-in display) unless told otherwise.
    var target = NSRect(x: 229, y: -860, width: 1200, height: 800)
    if let parts = argument("--timeline-journey-frame")?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4 {
      target = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
    // The seed leaves every chat's history unknown, so the list's bottom would not be the live end (no pin, the
    // jump button showing). Certify each, as a latest page from the server would; `--timeline-journey-uncertified`
    // keeps them unknown (an offline client's cached history).
    let certified = !CommandLine.arguments.contains("--timeline-journey-uncertified")
    if certified {
      for peer in switchChats + [richChat] { try? PerfHarnessFixture.certifyHistory(peer: peer) }
    }
    let journey = Journey(window: window, open: open, outDir: outDir, label: label, log: log)
    journey.note("history \(certified ? "certified" : "uncertified")")
    journey.note("start \(names) window \(Int(target.width))x\(Int(target.height)) at \(Int(target.minX)),\(Int(target.minY))")
    window.makeKeyAndOrderFront(nil)
    window.setFrame(target, display: true)
    journey.homeFrame = window.frame
    await Journey.sleep(ms: (Double(argument("--timeline-journey-delay") ?? "4") ?? 4) * 1000)

    for name in names {
      guard let scenario = scenarios.first(where: { $0.name == name }) else {
        journey.note("unknown scenario \(name)")
        continue
      }
      journey.begin(name)
      window.setFrame(journey.homeFrame, display: true)
      let t0 = Journey.now()
      await scenario.run(journey)
      journey.result["wallMs"] = Journey.round(Journey.now() - t0)
      journey.finish()
      await Journey.sleep(ms: 800)
    }
    await journey.drainCaptures()
    journey.note("done")
    try? Data().write(to: outDir.appendingPathComponent("\(label)-done"))
  }

  // MARK: - Scenarios

  /// Chat switches: when rows are placed, whether the route's first frame already had them, and when the main
  /// thread is free again. Two rounds over five chats; the first visit of each is cold.
  static func runOpen(_ j: Journey) async {
    var rounds: [[String: Any]] = []
    await j.show(switchChats[switchChats.count - 1])
    for round in 0 ..< 2 {
      for peer in switchChats {
        let previous = j.list().map(ObjectIdentifier.init)
        let probe = FrameProbe()
        var emptyFrames = 0
        var staleFrames = 0
        probe.perFrame = {
          guard let list = j.list() else { return }
          if ObjectIdentifier(list) == previous { staleFrames += 1 } else if list.diagnostics.placedCount == 0 { emptyFrames += 1 }
        }
        probe.start(on: j.window)
        let start = Journey.now()
        let plan0 = TimelineMessageListAppKit.planSeconds
        j.open(peer)
        let syncPlaced = j.list().map { ObjectIdentifier($0) != previous && $0.diagnostics.placedCount > 0 } ?? false
        var rowsMs: Double = -1
        while Journey.now() - start < 4000 {
          if let list = j.list(), ObjectIdentifier(list) != previous, list.diagnostics.placedCount > 0 {
            rowsMs = Journey.now() - start
            break
          }
          await Journey.sleep(ms: 1)
        }
        let settleMs = await Journey.settle(from: start)
        var frames = probe.stop()
        frames["emptyFrames"] = emptyFrames
        frames["staleFrames"] = staleFrames
        rounds.append([
          "peer": "\(peer)", "round": round, "rowsInOpenCall": syncPlaced, "rowsMs": Journey.round(rowsMs),
          "settleMs": Journey.round(settleMs), "frames": frames,
          "planMs": Journey.round((TimelineMessageListAppKit.planSeconds - plan0) * 1000),
        ])
        if round == 0 { await j.capture("\(peer)".filter { $0.isLetter || $0.isNumber }) }
        await Journey.sleep(ms: 400)
      }
    }
    j.result["switches"] = rounds
  }

  /// Fast flicks with momentum up into history and back, through the list's own input path.
  static func runFling(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    var flings: [[String: Any]] = []
    for index in 0 ..< 12 {
      let up = index < 6
      let before = list.diagnostics.presentedScrollPosition
      let start = Journey.now()
      let frames = await j.measure(blank: true) {
        if index == 1 || index == 4 { j.captureSoon("mid-\(index)", after: 0.12) }
        await j.flick(list, dy: up ? 60 : -60, count: 10)
        await j.untilRest(list)
      }
      flings.append([
        "up": up, "travel": Journey.round(Double(list.diagnostics.presentedScrollPosition - before)),
        "ms": Journey.round(Journey.now() - start), "frames": frames,
      ])
      await Journey.sleep(ms: 250)
    }
    j.result["flings"] = flings
    await j.capture("end")
  }

  /// Slow drags with the fingers down, no fling: each event's cost is the list's whole frame.
  static func runDrag(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    var drags: [[String: Any]] = []
    for index in 0 ..< 4 {
      var eventMs: [Double] = []
      let frames = await j.measure(blank: true) {
        eventMs = await j.drag(list, dy: index % 2 == 0 ? 5 : -5, count: 60)
        await j.untilRest(list)
      }
      drags.append(["perEventMs": Journey.stats(eventMs), "frames": frames])
    }
    j.result["drags"] = drags
  }

  /// An agent's reply streaming in at the bottom: a new message, then 50 edits that grow it (a sentence every
  /// 60 ms, a paragraph break every 8), as the bridge streams drafts. The list rests at the bottom: the newest
  /// row's bottom should stay where it is on every frame while the row grows upward.
  static func runStream(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    guard let messageId = try? PerfHarnessFixture.receiveMessage(peer: shortChat, from: 4),
          let ref = try? PerfHarnessFixture.messages(peer: shortChat, ids: [messageId]).first
    else { return j.fail("no message to stream") }
    let row = Row.message(id: ref.globalId)
    _ = await j.until(2000) { list.frame(for: row) != nil }
    // The arrival rises and fades in (about 0.2 s): measure from where it rests.
    await Journey.sleep(ms: 800)
    await j.untilRest(list)
    var latencies: [Double] = []
    let frames = await j.measure(bottomOf: row, bubbleGapOf: row) {
      var text = "Working on it."
      for step in 0 ..< 50 {
        text += step % 8 == 7 ? "\n\n" : " "
        text += Journey.sentence(step)
        let height = list.frame(for: row)?.height
        let t0 = Journey.now()
        try? PerfHarnessFixture.editMessage(peer: shortChat, messageId: messageId, text: text)
        if await j.until(300, { list.frame(for: row)?.height != height }) { latencies.append(Journey.now() - t0) }
        if step == 20 { j.captureSoon("mid", after: 0) }
        await Journey.sleep(ms: max(0, 60 - (Journey.now() - t0)))
      }
      await j.untilRest(list)
    }
    j.result["edits"] = 50
    j.result["heightChanges"] = latencies.count
    j.result["updateLatencyMs"] = Journey.stats(latencies)
    j.result["frames"] = frames
    await j.capture("end")
  }

  /// An agent's rich reply streaming at the bottom (`PerfHarnessFixture.richStreamSnapshot`): a heading, a paragraph
  /// growing word by word, a list growing item by item, a closing paragraph, a code block growing a line at a time and
  /// a table a row at a time; an edit every 60 ms. The row should grow a line or a block at a time
  /// (`RichBlockLayoutPlan.revealing`), never shrink, and hold its bottom; captures mid-code and mid-table.
  static func runStreamRich(_ j: Journey) async {
    await j.show(richChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    guard let messageId = try? PerfHarnessFixture.receiveMessage(peer: richChat, from: 4),
          let ref = try? PerfHarnessFixture.messages(peer: richChat, ids: [messageId]).first
    else { return j.fail("no message to stream") }
    let row = Row.message(id: ref.globalId)
    _ = await j.until(2000) { list.frame(for: row) != nil }
    await Journey.sleep(ms: 800)
    await j.untilRest(list)
    let steps = PerfHarnessFixture.richStreamSnapshot(step: 0).steps
    let parts = PerfHarnessFixture.richStreamCodeAndTableSteps
    var heights: [CGFloat] = []
    func sample() {
      guard let height = list.frame(for: row)?.height else { return }
      if heights.last.map({ abs($0 - height) > 0.25 }) ?? true { heights.append(height) }
    }
    let frames = await j.measure(bottomOf: row, bubbleGapOf: row) {
      for step in 0 ..< steps {
        let snapshot = PerfHarnessFixture.richStreamSnapshot(step: step)
        let t0 = Journey.now()
        _ = try? PerfHarnessFixture.editRichMessage(
          peer: richChat, messageId: messageId, text: snapshot.text, blocks: snapshot.blocks
        )
        if step == steps / 2 { j.captureSoon("mid", after: 0) }
        if step == steps * 3 / 4 { j.captureSoon("late", after: 0) }
        if step == parts.code.lowerBound + parts.code.count / 2 { j.captureSoon("code-mid", after: 0) }
        if step == parts.table.lowerBound + parts.table.count / 2 { j.captureSoon("table-mid", after: 0) }
        while Journey.now() - t0 < 60 {
          sample()
          await Journey.sleep(ms: 15)
        }
      }
      // The pacer catches up and finishes 1.6 s after the last edit.
      for _ in 0 ..< 160 {
        sample()
        await Journey.sleep(ms: 15)
      }
      await j.untilRest(list)
      sample()
    }
    let steps_ = zip(heights, heights.dropFirst()).map { $1 - $0 }
    j.result["edits"] = steps
    j.result["heights"] = heights.map { Journey.round(Double($0)) }
    j.result["heightChanges"] = steps_.count
    j.result["heightDecreases"] = steps_.filter { $0 < -0.25 }.count
    j.result["smallestGrowthPt"] = steps_.filter { $0 > 0.25 }.min().map { Journey.round(Double($0)) } ?? 0
    j.result["frames"] = frames
    await j.capture("end")
  }

  /// The same stream while the reader is two screens up: the row they read should not move at all.
  static func runStreamReading(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    guard let messageId = try? PerfHarnessFixture.receiveMessage(peer: shortChat, from: 4) else {
      return j.fail("no message to stream")
    }
    await Journey.sleep(ms: 300)
    for _ in 0 ..< 2 {
      await j.flick(list, dy: 30, count: 8)
      await j.untilRest(list)
    }
    guard let reading = j.readingRow(list) else { return j.fail("no reading row") }
    let frames = await j.measure(topOf: reading) {
      var text = "Working on it."
      for step in 0 ..< 30 {
        text += " " + Journey.sentence(step)
        try? PerfHarnessFixture.editMessage(peer: shortChat, messageId: messageId, text: text)
        await Journey.sleep(ms: 60)
      }
      await j.untilRest(list)
    }
    j.result["frames"] = frames
    await j.capture("end")
  }

  /// Streams across chat switches. The pacer is shared and ticks on a display link from a list's view; kept on the
  /// first list, a switch mid-stream left it on a view out of the window and every later stream froze at its first
  /// chunk. Streams in the short chat, switches away mid-reveal and back, streams there again, then in the rich chat.
  /// Each stream should reveal and finish: the returning row shows its whole text, both later streams grow.
  static func runStreamSwitch(_ j: Journey) async {
    await j.show(shortChat)
    if let list = j.list() { await j.toNewest(list) }
    guard let list = j.list(),
          let messageId = try? PerfHarnessFixture.receiveMessage(peer: shortChat, from: 4),
          let ref = try? PerfHarnessFixture.messages(peer: shortChat, ids: [messageId]).first
    else { return j.fail("no message to stream") }
    let row = Row.message(id: ref.globalId)
    _ = await j.until(2000) { list.frame(for: row) != nil }
    await Journey.sleep(ms: 800)
    func prefixShown(_ list: List, _ row: Row) -> Bool {
      guard let view = list.view(for: row) else { return false }
      return Journey.textViews(in: view).contains { ($0 as? CoreTextGlyphView)?.revealedLength != nil }
    }
    func streamed(_ list: List, _ row: Row, steps: Range<Int>, edit: (Int) -> Void) async -> Int {
      var changes = 0
      var last = list.frame(for: row)?.height
      for step in steps {
        edit(step)
        let t0 = Journey.now()
        while Journey.now() - t0 < 60 {
          let height = list.frame(for: row)?.height
          if let height, let last, abs(height - last) > 0.25 { changes += 1 }
          last = height
          await Journey.sleep(ms: 15)
        }
      }
      return changes
    }
    var text = "Working on it."
    let plainEdit: (Int) -> Void = { step in
      text += " " + Journey.sentence(step)
      try? PerfHarnessFixture.editMessage(peer: shortChat, messageId: messageId, text: text)
    }
    j.result["heightChangesBefore"] = await streamed(list, row, steps: 0 ..< 8, edit: plainEdit)
    // Away mid-reveal, and back.
    await j.show(richChat)
    await Journey.sleep(ms: 400)
    await j.show(shortChat)
    guard let back = j.list() else { return j.fail("no list after switching back") }
    _ = await j.until(2000) { back.frame(for: row) != nil }
    await Journey.sleep(ms: 300)
    j.result["prefixAfterReturn"] = prefixShown(back, row)
    j.result["heightChangesAfterReturn"] = await streamed(back, row, steps: 8 ..< 24, edit: plainEdit)
    await Journey.sleep(ms: 2200)
    j.result["prefixAfterIdle"] = prefixShown(back, row)
    // A rich stream in another chat after all that.
    await j.show(richChat)
    guard let rich = j.list(),
          let richId = try? PerfHarnessFixture.receiveMessage(peer: richChat, from: 4),
          let richRef = try? PerfHarnessFixture.messages(peer: richChat, ids: [richId]).first
    else { return j.fail("no rich message to stream") }
    let richRow = Row.message(id: richRef.globalId)
    _ = await j.until(2000) { rich.frame(for: richRow) != nil }
    await Journey.sleep(ms: 800)
    let steps = PerfHarnessFixture.richStreamSnapshot(step: 0).steps
    j.result["richHeightChanges"] = await streamed(rich, richRow, steps: 0 ..< steps) { step in
      let snapshot = PerfHarnessFixture.richStreamSnapshot(step: step)
      _ = try? PerfHarnessFixture.editRichMessage(
        peer: richChat, messageId: richId, text: snapshot.text, blocks: snapshot.blocks
      )
    }
    await Journey.sleep(ms: 2000)
    await j.capture("rich-end")
  }

  /// `resize-passage` for a rich reply (blocks: headings and paragraphs, each in its own text view): the passage at
  /// the usable top, as the block showing there and the character its top line starts with, should hold through the
  /// live resize. Reports the block changes and the worst drift in characters within the block (`charsOffMax`; a line
  /// is ~90 characters here).
  static func runResizePassageRich(_ j: Journey) async {
    await j.show(richChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    guard let messageId = try? PerfHarnessFixture.receiveMessage(peer: richChat, from: 4),
          let ref = try? PerfHarnessFixture.messages(peer: richChat, ids: [messageId]).first
    else { return j.fail("no message") }
    let row = Row.message(id: ref.globalId)
    let long = PerfHarnessFixture.richLongSnapshot()
    _ = try? PerfHarnessFixture.editRichMessage(peer: richChat, messageId: messageId, text: long.text, blocks: long.blocks)
    _ = await j.until(3000) { (list.frame(for: row)?.height ?? 0) > list.bounds.height * 1.5 }
    await Journey.sleep(ms: 600)
    list.apply(TimelineTransaction(scroll: .to(row, .top(-600)), timing: .none))
    await j.untilRest(list)
    await Journey.sleep(ms: 300)
    /// The block at the usable top (its text) and the character its top line starts with.
    func passage() -> (block: String, character: Int)? {
      guard let host = list.view(for: row) else { return nil }
      var stack: [NSView] = [host]
      while let view = stack.popLast() {
        if let glyphs = view as? CoreTextGlyphView, !glyphs.textLayout.lines.isEmpty {
          let point = glyphs.convert(NSPoint(x: 0, y: list.topInset), from: list)
          let y = glyphs.isFlipped ? point.y : glyphs.bounds.height - point.y
          if y >= 0, y < glyphs.bounds.height {
            let lines = glyphs.textLayout.lines
            let line = lines.first { $0.frame.maxY > y } ?? lines[lines.count - 1]
            return (glyphs.textLayout.text.attributedString.string, line.range.location)
          }
        }
        stack.append(contentsOf: view.subviews)
      }
      return nil
    }
    guard let start = passage() else { return j.fail("no block at the top") }
    var worst = 0
    var blockChanges = 0
    var samples = 0
    var lost = 0
    await j.liveResize(dx: -360, dy: 0, rounds: 2) {
      guard let now = passage() else { lost += 1; return }
      samples += 1
      if now.block != start.block { blockChanges += 1 } else { worst = max(worst, abs(now.character - start.character)) }
    }
    await j.untilRest(list)
    j.result["rowHeight"] = Journey.round(Double(list.frame(for: row)?.height ?? 0))
    j.result["samples"] = samples
    j.result["lostSamples"] = lost
    j.result["blockChanges"] = blockChanges
    j.result["charsOffMax"] = worst
    j.result["endSameBlock"] = passage().map { $0.block == start.block } ?? false
  }

  /// The composer growing and clearing while the reader is up in history (Mo 11-16: rows keep their distance from the
  /// composer's top when scrolled up): a row just above the composer should keep its gap to the composer's top on every
  /// sample (`gapDriftMaxPt`), moving up and down with it.
  static func runComposerHistory(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    await j.toHistory(list)
    guard let textView = Journey.largestVisible(ComposeNSTextView.self, in: j.window.contentView) else {
      return j.fail("no composer")
    }
    // The lowest row fully above the composer.
    func composerTop() -> CGFloat {
      textView.convert(NSPoint(x: 0, y: textView.isFlipped ? 0 : textView.bounds.height), to: nil).y
    }
    let usableBottom = list.bounds.height - list.bottomInset
    guard let row = list.placedViews.compactMap({ id, _ in list.presentedFrame(for: id).map { (id, $0) } })
      .filter({ $0.1.maxY < usableBottom - 4 }).max(by: { $0.1.maxY < $1.1.maxY })?.0
    else { return j.fail("no row above the composer") }
    func gap() -> CGFloat? {
      guard let frame = list.presentedFrame(for: row) else { return nil }
      return list.convert(NSPoint(x: 0, y: frame.maxY), to: nil).y - composerTop()
    }
    guard let reference = gap() else { return j.fail("row not shown") }
    j.window.makeFirstResponder(textView)
    var worst: CGFloat = 0
    var samples = 0
    func sample() {
      CATransaction.flush()
      if let value = gap() { worst = max(worst, abs(value - reference)); samples += 1 }
    }
    for line in 0 ..< 5 {
      textView.insertText(line == 0 ? "A draft while reading" : "\nline \(line + 1)", replacementRange: NSRange(location: NSNotFound, length: 0))
      let t0 = Journey.now()
      while Journey.now() - t0 < 250 { sample(); await Journey.sleep(ms: 8) }
    }
    await j.capture("tall")
    textView.selectAll(nil)
    textView.deleteBackward(nil)
    let t1 = Journey.now()
    while Journey.now() - t1 < 500 { sample(); await Journey.sleep(ms: 8) }
    await j.untilRest(list)
    j.result["gapDriftMaxPt"] = Journey.round(Double(worst))
    j.result["gapEndPt"] = gap().map { Journey.round(Double($0 - reference)) } ?? -9999
    j.result["samples"] = samples
  }

  /// Streaming onto a message that is already long (~14,000 characters, an agent's long reply): 30 appends at 60 ms at
  /// the pinned bottom. Every edit re-plans the whole text today; this measures what that costs per update as messages
  /// grow (`performMaxMs`, hitches) against `stream`'s short message, to decide whether appends need a retained-
  /// paragraph layout (parity row 61).
  static func runStreamLong(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    guard let messageId = try? PerfHarnessFixture.receiveMessage(peer: shortChat, from: 4),
          let ref = try? PerfHarnessFixture.messages(peer: shortChat, ids: [messageId]).first
    else { return j.fail("no message") }
    let row = Row.message(id: ref.globalId)
    var text = "A long reply."
    for step in 0 ..< 200 { text += (step % 6 == 5 ? "\n\n" : " ") + Journey.sentence(step) }
    _ = try? PerfHarnessFixture.editMessage(peer: shortChat, messageId: messageId, text: text)
    _ = await j.until(2000) { (list.frame(for: row)?.height ?? 0) > list.bounds.height }
    await Journey.sleep(ms: 600)
    await j.toNewest(list)
    j.result["characters"] = (text as NSString).length
    let plan0 = TimelineMessageListAppKit.planSeconds
    let update0 = TimelineMessageListAppKit.updateRowSeconds
    defer {
      j.result["planMs"] = Journey.round((TimelineMessageListAppKit.planSeconds - plan0) * 1000)
      j.result["updateRowMs"] = Journey.round((TimelineMessageListAppKit.updateRowSeconds - update0) * 1000)
    }
    j.result["frames"] = await j.measure(bottomOf: row) {
      for step in 200 ..< 230 {
        text += (step % 6 == 5 ? "\n\n" : " ") + Journey.sentence(step)
        try? PerfHarnessFixture.editMessage(peer: shortChat, messageId: messageId, text: text)
        await Journey.sleep(ms: 60)
      }
      await Journey.sleep(ms: 1800)
      await j.untilRest(list)
    }
  }

  /// The passage being read inside a huge message through a live resize (Mo 09-26: "preserving a row's pixel offset
  /// does not necessarily preserve the passage being read inside a huge message"). A long plain message is read with
  /// its top 400 pt above the usable top; the window is resized narrower and back, twice. On every sample the text
  /// line at the usable top should be the one holding the passage's first character (`linesOffMax` 0; up to 5 lines
  /// before the list kept the passage, 2026-11-27).
  static func runResizePassage(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    guard let messageId = try? PerfHarnessFixture.receiveMessage(peer: shortChat, from: 4),
          let ref = try? PerfHarnessFixture.messages(peer: shortChat, ids: [messageId]).first
    else { return j.fail("no message") }
    let row = Row.message(id: ref.globalId)
    var text = "A long read."
    for step in 0 ..< 200 { text += (step % 6 == 5 ? "\n\n" : " ") + Journey.sentence(step) }
    _ = try? PerfHarnessFixture.editMessage(peer: shortChat, messageId: messageId, text: text)
    _ = await j.until(2000) { (list.frame(for: row)?.height ?? 0) > list.bounds.height }
    await Journey.sleep(ms: 400)
    list.apply(TimelineTransaction(scroll: .to(row, .top(-400)), timing: .none))
    await j.untilRest(list)
    await Journey.sleep(ms: 300)
    /// The text line at the usable top, and the line holding `character`, in the row's current layout.
    func lines(holding character: Int?) -> (top: Int, holding: Int?, firstCharacter: Int)? {
      guard let host = list.view(for: row) else { return nil }
      var stack: [NSView] = [host]
      var glyphs: CoreTextGlyphView?
      while let view = stack.popLast() {
        if let match = view as? CoreTextGlyphView { glyphs = match; break }
        stack.append(contentsOf: view.subviews)
      }
      guard let glyphs, !glyphs.textLayout.lines.isEmpty else { return nil }
      let point = glyphs.convert(NSPoint(x: 0, y: list.topInset), from: list)
      let y = glyphs.isFlipped ? point.y : glyphs.bounds.height - point.y
      let layout = glyphs.textLayout.lines
      let top = layout.firstIndex { $0.frame.maxY > y } ?? layout.count - 1
      let holding = character.flatMap { c in layout.lastIndex { $0.range.location <= c } }
      return (top, holding, layout[top].range.location)
    }
    guard let start = lines(holding: nil) else { return j.fail("no text at the top") }
    let character = start.firstCharacter
    var worst = 0
    var samples = 0
    var lost = 0
    await j.liveResize(dx: -360, dy: 0, rounds: 2) {
      if let now = lines(holding: character), let holding = now.holding {
        worst = max(worst, abs(now.top - holding))
        samples += 1
      } else {
        lost += 1
      }
    }
    await j.untilRest(list)
    let end = lines(holding: character)
    j.result["rowHeight"] = Journey.round(Double(list.frame(for: row)?.height ?? 0))
    j.result["viewportHeight"] = Journey.round(Double(list.bounds.height))
    j.result["linesOffMax"] = worst
    j.result["linesOffEnd"] = end.flatMap { e in e.holding.map { abs(e.top - $0) } } ?? -1
    j.result["samples"] = samples
    j.result["lostSamples"] = lost
    await j.capture("after")
  }

  /// Minimal style's sticky avatars (top pins): a group thread dragged up in steps. At each rest, the avatars on
  /// screen: stuck ones sit `edgeGap` (8) under the usable top while their row (the group's first) is above it; none
  /// shows above that line unless pushed off by its group's end. Also a slow drag measured for frames and blanks.
  static func runTopAvatar(_ j: Journey) async {
    let chat: Peer = .thread(id: 801)
    await j.show(chat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    func avatars() -> [(avatar: CGRect, row: CGRect)] {
      list.placedViews.compactMap { id, view in
        guard let host = view as? TimelineRowHost, let avatar = host.avatar, !avatar.isHiddenOrHasHiddenAncestor,
              let frame = list.presentedFrame(of: avatar), let row = list.presentedFrame(for: id)
        else { return nil }
        return (frame, row)
      }
    }
    guard !avatars().isEmpty else { return j.note("top-avatar skipped: no list-held avatars (bubble style?)") }
    let line = list.topInset + 8
    var steps: [[String: Any]] = []
    for step in 0 ..< 8 {
      _ = await j.drag(list, dy: 25, count: 6)
      await j.untilRest(list)
      await Journey.sleep(ms: 150)
      let shown = avatars().filter { $0.avatar.maxY > list.topInset && $0.avatar.minY < list.bounds.height }
      let stuck = shown.filter { abs($0.avatar.minY - line) < 1 && $0.row.minY < line }
      let aboveLine = shown.filter { $0.avatar.minY < line - 1 }
      steps.append([
        "avatars": shown.count, "stuck": stuck.count, "aboveLine": aboveLine.count,
        "aboveLineTops": aboveLine.map { Journey.round(Double($0.avatar.minY - line)) },
      ])
      if step == 0 || step == 1 || step == 4 { await j.capture("step\(step)") }
    }
    j.result["steps"] = steps
    // A click on each avatar showing (resting or held under the top edge) reaches the avatar.
    var hits = 0
    var misses = 0
    var missed: [String] = []
    if let root = j.window.contentView, let frameView = root.superview {
      // Avatars whose centre shows between the toolbar and the composer (those take clicks over them, rightly).
      for (avatar, _) in avatars() where avatar.midY > list.topInset && avatar.midY < list.bounds.height - list.bottomInset {
        let center = list.convert(NSPoint(x: avatar.midX, y: avatar.midY), to: frameView)
        let hit = frameView.hitTest(center)
        if hit is UserAvatarView { hits += 1 } else {
          misses += 1
          missed.append("y \(Int(avatar.midY)) top \(Int(list.topInset)) hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }
      }
    }
    j.result["avatarHits"] = hits
    j.result["avatarMisses"] = misses
    j.result["avatarMissed"] = missed
    j.result["slowDrag"] = await j.measure(blank: true) {
      _ = await j.drag(list, dy: 4, count: 120)
      await j.untilRest(list)
    }
  }

  /// The day pills through a day boundary (Telegram macOS's sticky date): a slow drag carries a day row up to the top,
  /// where the floating header takes its pill over, then the next day's row pushes it off and takes over in turn. Each
  /// frame: how many pills show for each day (exactly one: the row's or the header's, never both, never none while
  /// the day is at the top), how far each day's pill moved (one drag step, or still while it sticks: no jump at the
  /// handoffs), and the gap between the pushed pill and the next day's.
  static func runDayPill(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    let pillHeight = TimelineDatePill.height
    func days() -> [(day: Date, y: CGFloat, shown: Bool)] {
      list.placedViews.compactMap { id, view in
        guard case let .daySeparator(day) = id, let frame = list.presentedFrame(for: id) else { return nil }
        let hidden = view.layer?.presentation()?.isHidden ?? view.isHidden
        return (day, frame.minY + TimelineDayRowView.pillTop, !hidden && !view.isHiddenOrHasHiddenAncestor)
      }.sorted { $0.y < $1.y }
    }
    func header() -> (title: String, y: CGFloat)? {
      guard let view = list.floatingHeader?.view as? TimelineFloatingDateView, let frame = list.presentedFrame(of: view)
      else { return nil }
      let opacity = (view.layer?.presentation()?.opacity ?? view.layer?.opacity ?? 0) * Float(view.superview?.alphaValue ?? 1)
      guard opacity > 0.5, frame.maxY > list.topInset else { return nil }
      return (view.title, frame.minY)
    }
    // A day row in the lower half of the screen, from the newest end going back.
    var day: Date?
    for _ in 0 ..< 40 {
      if let found = days().first(where: { $0.y > list.topInset + 120 && $0.y < list.bounds.height - 160 }) {
        day = found.day
        break
      }
      _ = await j.drag(list, dy: 40, count: 5)
      await j.untilRest(list)
    }
    guard let first = day else { return j.fail("no day row found") }
    let line = list.topInset + TimelineDayRowView.pillTop
    let step = 3.0
    var doubles = 0
    var missing = 0
    var largestJump: CGFloat = 0
    var gaps: [CGFloat] = []
    var last: [Date: CGFloat] = [:]
    var handoffs = 0
    var lastHeader: String?
    var lastHeaderPlace: (title: String, y: CGFloat)?
    var vanished = 0
    var captured: Set<String> = []
    var trail: [[String: Any]] = []
    var steps = 0
    var pushedTitle: String?
    var afterNext = 0
    /// One sample after a drag event: counts, jumps, gaps, the trail and the captures. False once the next day's pill
    /// has stuck and gone on 40 pt.
    func sample() async -> Bool {
      steps += 1
      let rows = days()
      let shownHeader = header()
      let titles = Dictionary(rows.map { (TimelineDatePill.title(for: $0.day), $0) }, uniquingKeysWith: { a, _ in a })
      // Where each day's pill shows now, by its row or by the header.
      var shown: [Date: [CGFloat]] = [:]
      for row in rows where row.shown && row.y + pillHeight > list.topInset { shown[row.day, default: []].append(row.y) }
      if let shownHeader, let row = titles[shownHeader.title] { shown[row.day, default: []].append(shownHeader.y) }
      doubles += shown.values.filter { $0.count > 1 }.count
      // The day at the top: its row above the line and nothing pushing the header wholly out.
      if let top = rows.last(where: { $0.y < line - 0.5 }), shown[top.day] == nil,
         !rows.contains(where: { $0.y >= line - 0.5 && $0.y < list.topInset + pillHeight + 6 })
      {
        missing += 1
      }
      for (date, ys) in shown {
        guard let y = ys.first else { continue }
        if let previous = last[date], abs(y - previous) > CGFloat(step) + 0.5 {
          largestJump = max(largestJump, abs(y - previous) - CGFloat(step))
        }
        last[date] = y
      }
      if let shownHeader, let below = rows.first(where: { $0.y > shownHeader.y + 1 }), shownHeader.y < line - 0.5 {
        gaps.append(below.y - (shownHeader.y + pillHeight))
      }
      if shownHeader?.title != lastHeader, shownHeader != nil { handoffs += 1 }
      lastHeader = shownHeader?.title
      // A pushed pill gone (or replaced) while more than a step of it still showed, its row not showing either.
      if let previous = lastHeaderPlace, shownHeader?.title != previous.title,
         previous.y + pillHeight > list.topInset + CGFloat(step) + 0.5,
         !rows.contains(where: { $0.shown && TimelineDatePill.title(for: $0.day) == previous.title })
      {
        vanished += 1
      }
      lastHeaderPlace = shownHeader
      let near = rows.filter { $0.y > list.topInset - 40 && $0.y < list.topInset + 140 }
      if !near.isEmpty || shownHeader.map({ $0.y < line - 0.5 }) == true, trail.count < 300 {
        trail.append([
          "rows": near.map { "\(TimelineDatePill.title(for: $0.day))@\(Int($0.y.rounded()))\($0.shown ? "" : "h")" },
          "header": shownHeader.map { "\($0.title)@\(Int($0.y.rounded()))" } ?? "-",
        ])
      }
      // Captures: the first day about to stick, stuck, pushed by the next, and the next stuck.
      if let row = rows.first(where: { $0.day == first }) {
        if !captured.contains("before"), row.y < line + 30 { captured.insert("before"); await j.capture("before") }
        if !captured.contains("stuck"), row.y < line - 60 { captured.insert("stuck"); await j.capture("stuck") }
      }
      // The push and the next day's takeover, from the header itself.
      if let shownHeader {
        if !captured.contains("pushed"), shownHeader.y < line - 8 {
          captured.insert("pushed")
          pushedTitle = shownHeader.title
          await j.capture("pushed")
        }
        if let pushedTitle, !captured.contains("next"), shownHeader.title != pushedTitle, shownHeader.y >= line - 0.5 {
          captured.insert("next")
          await j.capture("next")
        }
      }
      if captured.contains("next") {
        afterNext += 1
        if afterNext > 14 { return false }
      }
      return true
    }
    // Slowly through the first day's handoff, until it has stuck 60 pt.
    await j.heldDrag(list, dy: -step, count: 400) { await sample() && !captured.contains("stuck") }
    await j.untilRest(list)
    // Quickly on through its day, until the next day's row is 250 pt below the top.
    for _ in 0 ..< 60 {
      let rows = days()
      if rows.contains(where: { $0.y > line + 40 && $0.y < line + 250 }) { break }
      _ = await j.drag(list, dy: -40, count: 5)
      await j.untilRest(list)
      last.removeAll()
      lastHeaderPlace = nil
    }
    // Slowly through the push and the next day's handoff.
    await j.heldDrag(list, dy: -step, count: 400) { await sample() }
    await j.untilRest(list)
    // Flings both ways through day boundaries: the row's hiding is baked along the render-server path, as the
    // header's is. Sampled every 8 ms from the presentation layers.
    var flingSamples = 0
    var flingDoubles = 0
    var flingMissing = 0
    var flingTrail: [[String: Any]] = []
    for dy in [30.0, -30.0, 45.0, -45.0] {
      let flick = Task { await j.flick(list, dy: dy, count: 8) }
      let end = Journey.now() + 1600
      while Journey.now() < end {
        await Journey.sleep(ms: 8)
        flingSamples += 1
        let rows = days()
        let shownHeader = header()
        var shown: [Date: Int] = [:]
        for row in rows where row.shown && row.y + pillHeight > list.topInset { shown[row.day, default: 0] += 1 }
        if let shownHeader, let row = rows.first(where: { TimelineDatePill.title(for: $0.day) == shownHeader.title }) {
          shown[row.day, default: 0] += 1
        }
        flingDoubles += shown.values.filter { $0 > 1 }.count
        if let top = rows.last(where: { $0.y < line - 0.5 }), shown[top.day] == nil,
           !rows.contains(where: { $0.y >= line - 0.5 && $0.y < list.topInset + pillHeight + 6 })
        {
          flingMissing += 1
          if flingTrail.count < 30, let view = list.floatingHeader?.view as? TimelineFloatingDateView {
            let frame = list.presentedFrame(of: view)
            flingTrail.append([
              "dy": dy, "t": Journey.round(Journey.now() - (end - 1600)),
              "top": "\(TimelineDatePill.title(for: top.day))@\(Int(top.y.rounded()))",
              "header": "\(view.title)@\(Int((frame?.minY ?? -1).rounded())) op \(view.layer?.presentation()?.opacity ?? -1) box \(view.superview?.alphaValue ?? -1)",
              "rows": rows.filter { $0.y > list.topInset - 200 && $0.y < list.topInset + 200 }
                .map { "\(TimelineDatePill.title(for: $0.day))@\(Int($0.y.rounded()))\($0.shown ? "" : "h")" },
              "flinging": list.diagnostics.isFlinging,
            ])
          }
        }
      }
      await flick.value
      await j.untilRest(list)
    }
    j.result["flingSamples"] = flingSamples
    j.result["flingDoubles"] = flingDoubles
    j.result["flingMissing"] = flingMissing
    j.result["flingMissingTrail"] = flingTrail
    await j.untilRest(list)
    j.result["steps"] = steps
    j.result["doubles"] = doubles
    j.result["missing"] = missing
    j.result["vanishedEarly"] = vanished
    j.result["largestJumpBeyondStep"] = Journey.round(Double(largestJump))
    j.result["handoffs"] = handoffs
    j.result["pushGap"] = gaps.isEmpty ? "none" : "\(Journey.round(Double(gaps.min() ?? 0)))…\(Journey.round(Double(gaps.max() ?? 0)))"
    j.result["trail"] = Array(trail.suffix(120))
    // At rest, after the idle delay: the stuck pill fades unless it is near its own row's place.
    await Journey.sleep(ms: 2600)
    j.result["headerAfterIdle"] = header()?.title ?? "-"
    await j.capture("idle")
  }

  /// What VoiceOver gets from the list: its role and children (in reading order), and for the newest three rows each
  /// element under them (role, label, value). Runs on the table list too (`LIST=table`) for parity.
  static func runAccessibility(_ j: Journey) async {
    await j.show(shortChat)
    if let list = j.list() { await j.toNewest(list) }
    await Journey.sleep(ms: 400)
    let root: NSView? = j.list() ?? Journey.largestVisible(NSTableView.self, in: j.window.contentView)
    guard let root else { return j.fail("no list") }
    func info(_ element: Any) -> (role: String, label: String, value: String, isElement: Bool, children: [Any])? {
      if let view = element as? NSView {
        return (view.accessibilityRole()?.rawValue ?? "?", view.accessibilityLabel() ?? "",
                view.accessibilityValue().map { "\($0)" } ?? "", view.isAccessibilityElement(),
                view.accessibilityChildren() ?? [])
      }
      if let item = element as? NSAccessibilityElement {
        return (item.accessibilityRole()?.rawValue ?? "?", item.accessibilityLabel() ?? "",
                item.accessibilityValue().map { "\($0)" } ?? "", item.isAccessibilityElement(),
                item.accessibilityChildren() ?? [])
      }
      return nil
    }
    func describe(_ element: Any, depth: Int, into lines: inout [String]) {
      guard depth <= 8, lines.count < 60, let node = info(element) else { return }
      if node.isElement || !node.label.isEmpty || !node.value.isEmpty {
        let indent = String(repeating: "  ", count: depth)
        lines.append("\(indent)\(node.role)\(node.isElement ? "" : " (ignored)") label=\(node.label.prefix(50)) value=\(node.value.prefix(50))")
      }
      for child in node.children { describe(child, depth: depth + 1, into: &lines) }
    }
    guard let top = info(root) else { return j.fail("list has no accessibility") }
    j.result["listRole"] = top.role
    j.result["rowCount"] = top.children.count
    // Reading order: each row below the one before it on screen.
    let tops = top.children.compactMap { ($0 as? NSView).map { $0.convert($0.bounds, to: nil).maxY } }
    j.result["topToBottom"] = zip(tops, tops.dropFirst()).allSatisfy { $0 >= $1 }
    var rows: [[String]] = []
    for row in top.children.suffix(3) {
      var lines: [String] = []
      describe(row, depth: 0, into: &lines)
      rows.append(lines)
    }
    j.result["newestRows"] = rows
  }

  /// A context menu opening mid-fling (its tracking notification, as AppKit posts it): the list should stop at once,
  /// so no row recycles under the open menu (its actions read the row's message when chosen).
  static func runMenuHold(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    // The menu opens 250 ms into the fling (the flick's events go on: the momentum stream after the lift).
    let flick = Task { await j.flick(list, dy: 60, count: 8) }
    await Journey.sleep(ms: 250)
    let movingAtMenu = list.isMoving
    let makes0 = list.diagnostics.makes
    // `-menuHoldControl YES`: an unrelated notification, so the check shows the list moving on without the hold.
    let control = UserDefaults.standard.bool(forKey: "menuHoldControl")
    NotificationCenter.default.post(
      name: control ? NSMenu.didEndTrackingNotification : NSMenu.didBeginTrackingNotification, object: NSMenu()
    )
    await Journey.sleep(ms: 50)
    let makes1 = list.diagnostics.makes
    // A row on screen: where it shows 50 ms after the menu, and 600 ms after (still there when the list held).
    let probeRow = list.placedViews.first { list.presentedFrame(for: $0.0).map { $0.minY > 100 } ?? false }?.0
    let y1 = probeRow.flatMap { list.presentedFrame(for: $0)?.minY }
    await Journey.sleep(ms: 600)
    let y2 = probeRow.flatMap { list.presentedFrame(for: $0)?.minY }
    j.result["movingAtMenu"] = movingAtMenu
    j.result["movedAfterMenuPt"] = y1.flatMap { a in y2.map { Journey.round(Double(abs($0 - a))) } } ?? -1
    j.result["rowsMadeAfterStop"] = list.diagnostics.makes - makes1
    j.result["rowsMadeBeforeStop"] = makes1 - makes0
    await flick.value
    await j.untilRest(list)
  }

  /// Messages from one sender arrive at the bottom of a group thread, 700 ms apart. Bubble style shows one avatar a
  /// sender group, on its last message, so each arrival that joins the group moves the avatar to the new last row: it
  /// should slide there with the rows, never vanish or jump (iOS 11-18: "the avatar instead of staying, hides and
  /// appears in new position"). The first arrival may start a group (a new avatar); the second always joins it.
  static func runArriveAvatar(_ j: Journey) async {
    let chat: Peer = .thread(id: 801)
    await j.show(chat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    func avatars() -> [CGRect] {
      list.placedViews.compactMap { _, view in
        guard let host = view as? TimelineRowHost, let avatar = host.avatar, !avatar.isHiddenOrHasHiddenAncestor
        else { return nil }
        return list.presentedFrame(of: avatar)
      }
    }
    guard !avatars().isEmpty else { return j.note("arrive-avatar skipped: no list-held avatars (minimal style)") }
    for arrival in 0 ..< 3 {
      var missing = 0
      var samples = 0
      var maxStep: CGFloat = 0
      var last: CGFloat?
      var trail: [Double] = []
      _ = try? PerfHarnessFixture.receiveMessage(peer: chat, from: 3)
      let t0 = Journey.now()
      while Journey.now() - t0 < 700 {
        // The lowest avatar on screen: the arriving group's.
        if let lowest = avatars().max(by: { $0.maxY < $1.maxY }) {
          if let last { maxStep = max(maxStep, abs(lowest.maxY - last)) }
          last = lowest.maxY
          if trail.last != Journey.round(Double(lowest.maxY)) { trail.append(Journey.round(Double(lowest.maxY))) }
        } else {
          missing += 1
        }
        samples += 1
        await Journey.sleep(ms: 8)
      }
      j.result["arrival\(arrival)"] = [
        "samples": samples, "missingSamples": missing, "maxStepPt": Journey.round(Double(maxStep)),
        "trail": Array(trail.prefix(40)),
      ] as [String: Any]
      if arrival == 1 { await j.capture("joined") }
    }
  }

  /// A reaction lands on the newest message at the bottom, then on one a few rows up, and goes again. The row should
  /// keep its cell (the message view adds and removes its reactions in place) and its insides should move with it:
  /// the bubble stays on its row on every frame (`bubbleToRowBottomDriftMaxPt`).
  static func runReact(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    guard let refs = try? PerfHarnessFixture.messages(peer: shortChat), refs.count > 4 else {
      return j.fail("no messages")
    }
    var cases: [[String: Any]] = []
    for (name, ref) in [("newest", refs[refs.count - 1]), ("fewUp", refs[refs.count - 4])] {
      let row = Row.message(id: ref.globalId)
      func cell() -> NSView? { list.view(for: row)?.subviews.first { $0 is MessageTableCell } }
      guard let before = cell() else {
        cases.append(["case": name, "error": "not placed"])
        continue
      }
      var result: [String: Any] = ["case": name]
      for label in ["add", "remove"] {
        let height = list.frame(for: row)?.height ?? 0
        var lowestOpacity: Float = 1
        result[label] = await j.measure(bottomOf: row, bubbleGapOf: row) {
          try? PerfHarnessFixture.toggleReaction(peer: shortChat, messageId: ref.messageId, emoji: "👍", userId: 3)
          _ = await j.until(1000) { abs((list.frame(for: row)?.height ?? 0) - height) > 0.5 }
          // The reactions bar fades in with the row's growth: its presented opacity starts below 1.
          let t0 = Journey.now()
          // No transaction flush here: forced mid-pass commits moved the row 2.3 pt in this probe's own measure.
          while label == "add", Journey.now() - t0 < 120 {
            var stack: [NSView] = list.view(for: row).map { [$0] } ?? []
            while let view = stack.popLast() {
              if String(describing: type(of: view)).contains("Reaction"), !view.isHidden,
                 let opacity = (view.layer?.presentation() ?? view.layer)?.opacity
              {
                lowestOpacity = min(lowestOpacity, opacity)
              }
              stack.append(contentsOf: view.subviews)
            }
            await Journey.sleep(ms: 8)
          }
          await Journey.sleep(ms: 300)
          await j.untilRest(list)
        }
        if label == "add" { result["addLowestReactionOpacity"] = Double(lowestOpacity) }
        result["\(label)KeptCell"] = cell() === before
        result["\(label)HeightDelta"] = Double((list.frame(for: row)?.height ?? 0) - height)
        if name == "newest", label == "add" { await j.capture("reacted") }
      }
      cases.append(result)
    }
    j.result["cases"] = cases
  }

  /// Edits mid-history: a row above the screen, a visible row above the reading row, one below it; each grows by
  /// a paragraph, then goes back. The reading row should hold (bottom-first anchoring keeps the row being read).
  static func runEdit(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toHistory(list)
    guard let reading = j.readingRow(list) else { return j.fail("no reading row") }
    let refs = j.messageRefs(longChat)
    var cases: [[String: Any]] = []
    for (name, row) in [
      ("aboveScreen", j.older(longChat, than: reading, by: 20).map { Row.message(id: $0.globalId) }),
      ("aboveVisible", j.row(list, relativeTo: reading, offset: -2)),
      ("belowVisible", j.row(list, relativeTo: reading, offset: 2)),
    ] {
      guard let row, case let .message(id) = row, let ref = refs[id] else {
        cases.append(["case": name, "error": "no row"])
        continue
      }
      var grow: [String: Any] = [:]
      var back: [String: Any] = [:]
      grow = await j.measure(topOf: reading) {
        try? PerfHarnessFixture.editMessage(
          peer: longChat, messageId: ref.messageId,
          text: ref.text + "\n\n" + (0 ..< 5).map(Journey.sentence).joined(separator: " ")
        )
        await Journey.sleep(ms: 400)
        await j.untilRest(list)
      }
      if name == "aboveVisible" { await j.capture("grown-above") }
      back = await j.measure(topOf: reading) {
        try? PerfHarnessFixture.editMessage(peer: longChat, messageId: ref.messageId, text: ref.text)
        await Journey.sleep(ms: 400)
        await j.untilRest(list)
      }
      cases.append(["case": name, "grow": grow, "back": back])
    }
    j.result["cases"] = cases
  }

  /// Deletes mid-history (below the reading row, above it on screen, above the screen), then the newest message
  /// while resting at the bottom. The reading row should hold; at the bottom the list should stay pinned.
  static func runDelete(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toHistory(list)
    guard let reading = j.readingRow(list) else { return j.fail("no reading row") }
    let refs = j.messageRefs(longChat)
    var cases: [[String: Any]] = []
    for (name, offset) in [("belowVisible", 2), ("aboveVisible", -2), ("aboveScreen", -20)] {
      let picked = offset == -20
        ? j.older(longChat, than: reading, by: 20).map { Row.message(id: $0.globalId) }
        : j.row(list, relativeTo: reading, offset: offset)
      guard let row = picked, case let .message(id) = row, let ref = refs[id] else {
        cases.append(["case": name, "error": "no row"])
        continue
      }
      let makes = list.diagnostics.makes
      let frames = await j.measure(topOf: reading) {
        try? PerfHarnessFixture.deleteMessages(peer: longChat, messageIds: [ref.messageId])
        if offset != -20 { _ = await j.until(1000) { list.frame(for: row) == nil } }
        await Journey.sleep(ms: 400)
        await j.untilRest(list)
      }
      cases.append(["case": name, "frames": frames, "rowsMade": list.diagnostics.makes - makes])
      if name == "belowVisible" { await j.capture("deleted-below") }
    }
    await j.show(shortChat)
    if let list = j.list(), let newest = try? PerfHarnessFixture.newestMessage(peer: shortChat) {
      await j.untilRest(list)
      let frames = await j.measure(bottomOfNewest: true) {
        try? PerfHarnessFixture.deleteMessages(peer: shortChat, messageIds: [newest.messageId])
        await Journey.sleep(ms: 500)
        await j.untilRest(list)
      }
      cases.append(["case": "newestAtBottom", "frames": frames])
    }
    j.result["cases"] = cases
  }

  /// A send at the bottom: the pending row, then the server's confirmation 700 ms later (a new id, sent). The row
  /// should keep its view (no flash) and the list its pin. Then a send while two screens up: it should come back
  /// to the bottom.
  static func runSend(_ j: Journey) async {
    await j.show(sendChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.untilRest(list)
    var pending: (randomId: Int64, globalId: Int64)?
    var appearMs: Double = -1
    var rowsMadeAtConfirm = 0
    var sameView = false
    let frames = await j.measure(bottomOfNewest: true) {
      let t0 = Journey.now()
      pending = try? await PerfHarnessFixture.insertPendingSend(peer: sendChat, text: "Sending a quick update from the harness")
      guard let pending else { return }
      let row = Row.message(id: pending.globalId)
      if await j.until(1000, { list.frame(for: row) != nil }) { appearMs = Journey.now() - t0 }
      await Journey.sleep(ms: 700)
      await j.capture("pending")
      let view = list.view(for: row)
      let makes = list.diagnostics.makes
      _ = try? PerfHarnessFixture.confirmSend(peer: sendChat, randomId: pending.randomId)
      await Journey.sleep(ms: 500)
      await j.untilRest(list)
      rowsMadeAtConfirm = list.diagnostics.makes - makes
      sameView = view != nil && list.view(for: row) === view
    }
    j.result["appearMs"] = Journey.round(appearMs)
    j.result["rowsMadeAtConfirm"] = rowsMadeAtConfirm
    j.result["confirmKeptView"] = sameView
    j.result["frames"] = frames
    await j.capture("confirmed")

    for _ in 0 ..< 2 {
      await j.flick(list, dy: 30, count: 8)
      await j.untilRest(list)
    }
    // Through the composer, as the reader sends: typed, then Return (the send path asks the list to scroll to
    // the bottom). Without a server the send fails later; the scroll is what this checks.
    guard let composer = Journey.largestVisible(ComposeNSTextView.self, in: j.window.contentView) else {
      return j.fail("no composer")
    }
    j.window.makeFirstResponder(composer)
    composer.insertText("Sent while reading history", replacementRange: NSRange(location: NSNotFound, length: 0))
    await Journey.sleep(ms: 100)
    let fromHistory = await j.measure {
      // The composer's own send (what Return and the send button call).
      if let glass = Journey.largestVisible(GlassComposeAppKit.self, in: j.window.contentView) {
        glass.send()
      } else if let legacy = Journey.largestVisible(LegacyComposeAppKit.self, in: j.window.contentView) {
        legacy.send()
      } else {
        j.note("send: no composer view to send from")
      }
      await Journey.sleep(ms: 900)
      await j.untilRest(list)
    }
    let newest = try? PerfHarnessFixture.newestMessage(peer: sendChat)
    let shown = newest.flatMap { list.presentedFrame(for: .message(id: $0.globalId)) }
    j.result["sendFromHistory"] = fromHistory
    j.result["sendFromHistoryNewestVisible"] = shown.map { $0.maxY <= list.bounds.height + 1 && $0.minY >= 0 } ?? false
    await j.capture("sent-from-history")
  }

  /// Arrivals while the list rests on the newest row it has: an incoming message, a pending send (a direct write,
  /// not the composer's send, which scrolls by itself), its confirmation; then an incoming message while reading
  /// two screens up. Run it with `--timeline-journey-uncertified` too: between the open and the server's latest
  /// page (or offline) the newest local row is not the certified live end, and the list must still follow. Holds:
  /// each arrival ends with the newest row's bottom on the composer's edge (`*GapPt` 0; negative is under the
  /// composer); reading, the read row never moves (`reading.driftMaxPt` 0).
  ///
  /// The list first goes up a little and back down to the newest row: a list that has only ever been at the bottom
  /// is still pinned from its first placement, while one the reader brought back rests on its newest row, which
  /// the engine pins again only at the certified live end.
  static func runArrive(_ j: Journey) async {
    await j.show(sendChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.untilRest(list)
    await j.flick(list, dy: 20, count: 4)
    await j.untilRest(list)
    await j.flick(list, dy: -60, count: 8)
    await j.untilRest(list)
    j.result["restedAtNewest"] = list.timelineLayout.isAtBottom
    // The newest message row's bottom against the usable bottom, once the arrival has settled.
    func settledGap() async -> Double {
      await Journey.sleep(ms: 900)
      await j.untilRest(list)
      guard let newest = try? PerfHarnessFixture.newestMessage(peer: sendChat),
            let frame = list.presentedFrame(for: .message(id: newest.globalId))
      else { return -9999 }
      return Journey.round(Double(list.bounds.height - list.bottomInset - frame.maxY))
    }
    _ = try? PerfHarnessFixture.receiveMessage(peer: sendChat, from: 3)
    let incoming = await settledGap()
    await j.capture("incoming")
    let pending = try? await PerfHarnessFixture.insertPendingSend(peer: sendChat, text: "Written straight to the chat")
    let pendingGap = await settledGap()
    await j.capture("pending")
    if let pending { _ = try? PerfHarnessFixture.confirmSend(peer: sendChat, randomId: pending.randomId) }
    let confirmed = await settledGap()
    j.result["incomingGapPt"] = incoming
    j.result["pendingGapPt"] = pendingGap
    j.result["confirmedGapPt"] = confirmed
    j.result["followed"] = [incoming, pendingGap, confirmed].allSatisfy { abs($0) <= 1 }

    for _ in 0 ..< 2 {
      await j.flick(list, dy: 30, count: 8)
      await j.untilRest(list)
    }
    guard let reading = j.readingRow(list) else { return j.fail("no reading row") }
    j.result["reading"] = await j.measure(topOf: reading) {
      _ = try? PerfHarnessFixture.receiveMessage(peer: sendChat, from: 3)
      await Journey.sleep(ms: 900)
      await j.untilRest(list)
    }
    await j.capture("reading")
  }

  /// Live window resize, through the window's own resize loop: narrower by 400 pt and back twice, then shorter by
  /// 240 pt and back, at the bottom and two screens up. Pinned, the newest row's bottom holds; reading, the read
  /// row holds.
  static func runResize(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.untilRest(list)
    j.result["atBottom"] = await j.measure(bottomOfNewest: true) {
      await j.liveResize(dx: -400, dy: 0, rounds: 2)
      await j.liveResize(dx: 0, dy: 240, rounds: 1)
      await j.untilRest(list)
    }
    await j.capture("bottom-after")
    await j.toHistory(list)
    guard let reading = j.readingRow(list) else { return j.fail("no reading row") }
    j.result["reading"] = await j.measure(topOf: reading) {
      await j.liveResize(dx: -400, dy: 0, rounds: 2)
      await j.untilRest(list)
    }
    await j.liveResize(dx: -400, dy: 0, rounds: 0, hold: true)
    await j.capture("narrow")
    j.window.setFrame(j.homeFrame, display: true)
  }

  /// Live resize over text-heavy rows (the rich agent chat): frames, hitches and the shell's planning time, at the
  /// newest end and in history (Mo: "resizing the window with text heavy messages is extremely slow and laggy").
  static func runResizeRich(_ j: Journey) async {
    await j.show(richChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    await j.untilRest(list)
    for (name, history) in [("bottom", false), ("history", true)] {
      if history { await j.toHistory(list) }
      let plan0 = TimelineMessageListAppKit.planSeconds
      let start = Journey.now()
      j.result[name] = await j.measure {
        await j.liveResize(dx: -360, dy: 0, rounds: 2)
        await j.untilRest(list)
      }
      j.result["\(name)PlanMs"] = Journey.round((TimelineMessageListAppKit.planSeconds - plan0) * 1000)
      j.result["\(name)WallMs"] = Journey.round(Journey.now() - start)
    }
    j.window.setFrame(j.homeFrame, display: true)
  }

  /// Live resize over very long plain messages (chat 13274 has 6k–79k character messages): one of ~80k characters
  /// and three of ~6k, at the newest end and reading inside the long one.
  static func runResizeText(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    func text(_ sentences: Int) -> String {
      var text = "A long message."
      for step in 0 ..< sentences { text += (step % 6 == 5 ? "\n\n" : " ") + Journey.sentence(step) }
      return text
    }
    var longRow: Row?
    for (index, sentences) in [1300, 100, 100, 100].enumerated() {
      guard let messageId = try? PerfHarnessFixture.receiveMessage(peer: shortChat, from: 4),
            let ref = try? PerfHarnessFixture.messages(peer: shortChat, ids: [messageId]).first else { continue }
      _ = try? PerfHarnessFixture.editMessage(peer: shortChat, messageId: messageId, text: text(sentences))
      if index == 0 { longRow = Row.message(id: ref.globalId) }
    }
    await Journey.sleep(ms: 800)
    await j.toNewest(list)
    await j.untilRest(list)
    j.result["longHeight"] = Journey.round(Double(longRow.flatMap { list.frame(for: $0)?.height } ?? 0))
    for name in ["bottom", "inside"] {
      if name == "inside", let longRow {
        list.apply(TimelineTransaction(scroll: .to(longRow, .top(-2000)), timing: .none))
        await j.untilRest(list)
      }
      let plan0 = TimelineMessageListAppKit.planSeconds
      let update0 = TimelineMessageListAppKit.updateRowSeconds
      let typesetters0 = TextLayouter.typesetterStats
      let start = Journey.now()
      j.result[name] = await j.measure {
        await j.liveResize(dx: -360, dy: 0, rounds: 2)
        await j.untilRest(list)
      }
      let typesetters = TextLayouter.typesetterStats
      j.result["\(name)Typesetters"] = "made \(typesetters.made - typesetters0.made), reused \(typesetters.reused - typesetters0.reused)"
      j.result["\(name)PlanMs"] = Journey.round((TimelineMessageListAppKit.planSeconds - plan0) * 1000)
      j.result["\(name)UpdateRowMs"] = Journey.round((TimelineMessageListAppKit.updateRowSeconds - update0) * 1000)
      j.result["\(name)WallMs"] = Journey.round(Journey.now() - start)
      await j.capture(name)
    }
    j.window.setFrame(j.homeFrame, display: true)
  }

  /// Reply to the newest message and cancel, three times: how long picking Reply blocks the main thread (the
  /// composer's sink: the replied message's read and the preview's build), and how the newest row follows the
  /// composer's growth frame by frame (Mo, 2026-11-27: "reply preview in compose coming up is lagging").
  static func runReply(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    await j.untilRest(list)
    guard case let .user(userId) = shortChat,
          let chatId = try? await AppDatabase.shared.reader.read({ db in
            try Chat.filter(Column("peerUserId") == userId).fetchOne(db)?.id
          }),
          let newest = try? PerfHarnessFixture.messages(peer: shortChat).last,
          let composer = Journey.largestVisible(ComposeAppKit.self, in: j.window.contentView)
    else { return j.fail("no message or composer") }
    let state = ChatsManager.get(for: shortChat, chatId: chatId)
    var blockMs: [Double] = []
    // The composer's top (the reply preview opens above the text field, so the field's top stays where it is).
    j.result["frames"] = await j.measure(composerGap: composer) {
      for _ in 0 ..< 3 {
        let start = Journey.now()
        state.setReplyingToMsgId(newest.messageId)
        blockMs.append(Journey.round(Journey.now() - start))
        await Journey.sleep(ms: 450)
        state.clearReplyingToMsgId()
        await Journey.sleep(ms: 450)
      }
      await j.untilRest(list)
    }
    j.result["blockMs"] = blockMs
    // One opening and closing, sampled every few ms: the composer's top and the newest row's shown bottom, in window
    // points, from the moment Reply is picked.
    let row = Row.message(id: newest.globalId)
    func sample() -> String {
      let top = composer.convert(NSPoint(x: 0, y: composer.isFlipped ? 0 : composer.bounds.height), to: nil).y
      let shown = list.presentedFrame(for: row).map { list.convert(NSPoint(x: 0, y: $0.maxY), to: nil).y } ?? .nan
      return "\(Journey.round(Double(top)))/\(Journey.round(Double(shown)))"
    }
    var series: [String] = []
    let start = Journey.now()
    state.setReplyingToMsgId(newest.messageId)
    while Journey.now() - start < 320 {
      series.append("\(Int(Journey.now() - start)):\(sample())")
      await Journey.sleep(ms: 8)
    }
    j.result["openSeries"] = series
    state.clearReplyingToMsgId()
    await Journey.sleep(ms: 400)
  }

  /// The composer growing line by line and clearing: the newest row's bottom should keep its distance from the
  /// composer's top on every frame.
  static func runComposer(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.toNewest(list)
    guard let textView = Journey.largestVisible(ComposeNSTextView.self, in: j.window.contentView) else {
      return j.fail("no composer")
    }
    j.window.makeFirstResponder(textView)
    // Against the composer's top edge, what the reader sees, and also against the text field (whose line appears at
    // once inside the composer's growth).
    let composer = Journey.largestVisible(ComposeAppKit.self, in: j.window.contentView) ?? textView
    j.result["textFieldGap"] = await j.measure(composerGap: textView) {
      textView.insertText("one line", replacementRange: NSRange(location: NSNotFound, length: 0))
      await Journey.sleep(ms: 250)
      textView.selectAll(nil)
      textView.deleteBackward(nil)
      await Journey.sleep(ms: 400)
    }
    j.result["frames"] = await j.measure(composerGap: composer) {
      for line in 0 ..< 6 {
        textView.insertText(line == 0 ? "A longer draft" : "\nline \(line + 1) of the draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        await Journey.sleep(ms: 250)
      }
      await j.capture("tall")
      textView.selectAll(nil)
      textView.deleteBackward(nil)
      await Journey.sleep(ms: 400)
      await j.untilRest(list)
    }
  }

  /// The rich chat (pinned header, rich blocks), light and dark, then fast flings through it with a probe that counts
  /// shown frames where a row's text has nothing drawn.
  static func runRich(_ j: Journey) async {
    await j.show(richChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.untilRest(list)
    await j.capture("light-bottom")
    let original = NSApp.appearance
    NSApp.appearance = NSAppearance(named: .darkAqua)
    _ = await Journey.settle(from: Journey.now())
    await Journey.sleep(ms: 300)
    await j.capture("dark-bottom")
    NSApp.appearance = original
    _ = await Journey.settle(from: Journey.now())
    await Journey.sleep(ms: 300)
    var flings: [[String: Any]] = []
    for index in 0 ..< 8 {
      let up = index % 4 < 2
      let frames = await j.measure(blank: true, undrawnText: true) {
        if index == 1 { j.captureSoon("fling-mid", after: 0.1) }
        await j.flick(list, dy: up ? 90 : -90, count: 10)
        await j.untilRest(list)
      }
      flings.append(["up": up, "frames": frames])
      if index == 1 { await j.capture("light-history") }
    }
    j.result["flings"] = flings
    NSApp.appearance = NSAppearance(named: .darkAqua)
    _ = await Journey.settle(from: Journey.now())
    await Journey.sleep(ms: 300)
    await j.capture("dark-history")
    let darkFling = await j.measure(blank: true, undrawnText: true) {
      await j.flick(list, dy: 90, count: 10)
      await j.untilRest(list)
    }
    j.result["darkFling"] = darkFling
    NSApp.appearance = original
  }

  // media: Media Lab (seeded with `--perf-harness-media`, so run with `EXTRA_ARGS="--perf-harness-media ..."`): from
  // the newest row up a page at a time (the list's own page scroll, a fixed distance, so both builds of an A/B stop
  // at the same offsets), each place captured light and dark; then the counters flush (their `cx_` tally).
  static func runMedia(_ j: Journey) async {
    // `all` runs it only when the chat was seeded.
    guard PerfHarnessFixture.mediaRequested else { return j.note("media skipped: needs --perf-harness-media") }
    await j.show(mediaChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.untilRest(list)
    let original = NSApp.appearance
    for place in 0 ..< 8 {
      if place > 0 {
        list.scrollPageUp(nil)
        await j.untilRest(list)
      }
      // Local images decode off the main thread.
      await Journey.sleep(ms: 500)
      await j.capture("light-\(place)")
      NSApp.appearance = NSAppearance(named: .darkAqua)
      _ = await Journey.settle(from: Journey.now())
      await Journey.sleep(ms: 300)
      await j.capture("dark-\(place)")
      NSApp.appearance = original
      _ = await Journey.settle(from: Journey.now())
      await Journey.sleep(ms: 300)
    }
    MessageListPerfCounters.flush("media")
  }

  /// The scroll-to-bottom button: hidden at the bottom, shown a screen or more up, with a count when a message
  /// arrives meanwhile, hidden again back at the bottom.
  static func runJumpButton(_ j: Journey) async {
    await j.show(shortChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    await j.untilRest(list)
    await j.capture("at-bottom")
    for _ in 0 ..< 2 {
      await j.flick(list, dy: 40, count: 10)
      await j.untilRest(list)
    }
    await Journey.sleep(ms: 400)
    await j.capture("up")
    _ = try? PerfHarnessFixture.receiveMessage(peer: shortChat, from: 4)
    await Journey.sleep(ms: 800)
    await j.capture("up-unread")
    // Back down by hand: flicks until the newest row shows.
    for _ in 0 ..< 8 {
      if let newest = try? PerfHarnessFixture.newestMessage(peer: shortChat),
         let frame = list.presentedFrame(for: .message(id: newest.globalId)), frame.maxY <= list.bounds.height
      {
        break
      }
      await j.flick(list, dy: -60, count: 10)
      await j.untilRest(list)
    }
    await Journey.sleep(ms: 600)
    await j.capture("back-at-bottom")
  }

  // MARK: Selection (ledger #32, #33)

  /// The selection of the list showing in the window, whichever list it is (the timeline, or the table list when the
  /// run doesn't turn the timeline on), and its rows.
  static func selection(_ j: Journey) -> (MessageListTextSelection, any MessageListTextSelectionHost, any MessageListRowGeometry)? {
    let anchor: NSView? = j.list() ?? Journey.largestVisible(MessageListTableView.self, in: j.window.contentView)
    guard let anchor, let selection = MessageListTextSelection.owner(of: anchor), let host = selection.host else { return nil }
    return (selection, host, host.textSelectionRows)
  }

  /// Placed message rows whose cell lies wholly in the usable area (between toolbar and composer), top to bottom,
  /// with their visible text views.
  static func textRows(_ rows: any MessageListRowGeometry) -> [(row: Int, cell: MessageTableCell, texts: [NSView])] {
    guard let region = rows.autoscrollRegion(insetsOnly: true) else { return [] }
    return rows.placedRows.compactMap { row -> (Int, MessageTableCell, [NSView])? in
      guard let cell = rows.cell(atRow: row), cell.window != nil else { return nil }
      let frame = cell.convert(cell.bounds, to: nil)
      guard frame.minY >= region.minY, frame.maxY <= region.maxY else { return nil }
      let texts = (cell.textSelectionSource?.textSelectionProjection()?.textViews ?? []).compactMap { view -> NSView? in
        view.window != nil && !view.isHiddenOrHasHiddenAncestor && view.bounds.height > 4 ? view : nil
      }
      return texts.isEmpty ? nil : (row, cell, texts)
    }.sorted { $0.1.convert($0.1.bounds, to: nil).maxY > $1.1.convert($1.1.bounds, to: nil).maxY }
  }

  /// A press, a drag in steps and a release, as window events through the app's queue (so the list's event monitors
  /// see them as they see real ones).
  static func pressAndDrag(_ j: Journey, from start: NSPoint, to end: NSPoint, steps: Int = 12) async {
    // How many of the posted events the app's local monitors saw (the list's selection listens there).
    var seen = 0
    let counter = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
      seen += 1
      return event
    }
    defer {
      if let counter { NSEvent.removeMonitor(counter) }
      j.result["monitorSawEvents"] = seen
    }
    j.result["pressHit"] = j.window.contentView.flatMap { content in
      content.hitTest(content.superview?.convert(start, from: nil) ?? start).map { String(describing: type(of: $0)) }
    } ?? "nil"
    func post(_ type: NSEvent.EventType, _ point: NSPoint) {
      guard let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: j.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
      ) else { return }
      NSApp.postEvent(event, atStart: false)
    }
    post(.leftMouseDown, start)
    await Journey.sleep(ms: 30)
    // What the press resolved to in the list's selection (diagnostics for a gesture that doesn't start).
    if let found = selection(j) {
      let rows = found.2
      let hit = rows.hit(atWindowPoint: start)
      let row = rows.row(at: rows.rowsView.convert(start, from: nil))
      j.result["pressRowsHit"] = hit.map { String(describing: type(of: $0)) } ?? "nil"
      j.result["pressRow"] = row ?? -1
      j.result["pressStableId"] = row.flatMap { found.1.textSelectionStableId(atRow: $0) } ?? 0
      j.result["pressCell"] = row.flatMap { rows.cell(atRow: $0) } != nil
      j.result["pressTaken"] = found.0.ownsPendingPress
    }
    for step in 1 ... steps {
      let f = CGFloat(step) / CGFloat(steps)
      post(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f))
      await Journey.sleep(ms: 16)
    }
    post(.leftMouseUp, end)
    await Journey.sleep(ms: 120)
  }

  static func key(_ j: Journey, code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async {
    guard let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: j.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code
    ) else { return }
    NSApp.postEvent(event, atStart: false)
    await Journey.sleep(ms: 150)
  }

  /// The key window takes the selection gestures: the run activates the app.
  /// An app can't make itself active from the background: `run.sh` serves the request (LaunchServices brings the
  /// running instance forward), then the window becomes key.
  static func takeKey(_ j: Journey) async {
    j.result["appActiveBefore"] = NSApp.isActive
    let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    j.result["screenLocked"] = locked
    if !NSApp.isActive, !locked {
      j.window.orderFrontRegardless()
      await Journey.sleep(ms: 200)
      // The empty title bar over the sidebar, right of the window buttons: a click there only activates.
      let frame = j.window.frame
      let spot = NSPoint(x: frame.minX + 200, y: frame.maxY - 20)
      try? Data("\(Int(spot.x)) \(Int(spot.y))\n".utf8)
        .write(to: j.outDir.appendingPathComponent("\(j.label)-\(j.scenario).activate"))
      let start = Journey.now()
      while !NSApp.isActive, Journey.now() - start < 3000 { await Journey.sleep(ms: 50) }
    }
    j.window.makeKeyAndOrderFront(nil)
    await Journey.sleep(ms: 300)
    j.result["appActive"] = NSApp.isActive
    j.result["keyWindow"] = j.window.isKeyWindow
    // A locked Mac (or another app holding focus): the gestures run as in a key window, and the result says so.
    MessageListTextSelection.treatsWindowAsKey = !j.window.isKeyWindow
    j.result["treatedAsKey"] = !j.window.isKeyWindow
  }

  /// Text selection across messages (#32): a drag from the start of one message's text to the end of the text two
  /// messages down, across rich blocks; the highlight in every message it covers; copy in plain and rich flavours
  /// (to a private pasteboard); Copy's responder; Escape clears it.
  static func runSelectText(_ j: Journey) async {
    await j.show(richChat)
    if let list = j.list() { await j.untilRest(list) } else { await Journey.sleep(ms: 1000) }
    await takeKey(j)
    guard let found = selection(j) else { return j.fail("no list selection") }
    let (selection, host, rows) = found
    let candidates = textRows(rows)
    j.result["textRowsOnScreen"] = candidates.count
    guard candidates.count >= 3 else { return j.fail("fewer than 3 text rows on screen") }
    let picked = Array(candidates.prefix(3))
    let first = picked[0].texts[0]
    let last = picked[2].texts[picked[2].texts.count - 1]
    let start = first.convert(NSPoint(x: min(4, first.bounds.width / 2), y: first.isFlipped ? 8 : first.bounds.height - 8), to: nil)
    let end = last.convert(
      NSPoint(x: max(last.bounds.width - 4, 1), y: last.isFlipped ? last.bounds.height - 6 : 6), to: nil
    )
    await pressAndDrag(j, from: start, to: end)
    j.result["hasSelection"] = selection.hasSelection
    // Every text view drawing part of the selection, over the placed rows.
    var highlighted = 0
    var highlightedRows = Set<Int>()
    for row in rows.placedRows {
      for view in rows.cell(atRow: row)?.textSelectionSource?.textSelectionProjection()?.textViews ?? []
        where view.listSelectionRange != nil
      {
        highlighted += 1
        highlightedRows.insert(row)
      }
    }
    j.result["highlightedTextViews"] = highlighted
    j.result["highlightedRows"] = highlightedRows.count
    j.result["pickedRows"] = picked.map(\.row)
    j.result["firstResponder"] = j.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
    // Copy's target through the responder chain (the Edit menu and Cmd-C), without touching the general pasteboard.
    let target = NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: nil)
    j.result["copyTarget"] = target.map { String(describing: type(of: $0)) } ?? "nil"
    let board = NSPasteboard(name: NSPasteboard.Name("chat.inline.timeline-journey"))
    board.clearContents()
    j.result["copied"] = selection.copySelection(to: board)
    let plain = board.string(forType: .string) ?? ""
    j.result["pasteboardTypes"] = (board.types ?? []).map(\.rawValue)
    j.result["plainLength"] = plain.count
    j.result["plainLines"] = plain.components(separatedBy: "\n").count
    j.result["plainHead"] = String(plain.prefix(80))
    j.result["plainTail"] = String(plain.suffix(80))
    j.result["rtfBytes"] = board.data(forType: .rtf)?.count ?? 0
    j.result["htmlBytes"] = board.data(forType: .html)?.count ?? 0
    // The middle message is covered whole: its words are all in the copy.
    let middle = picked[1].cell.textSelectionSource?.textSelectionProjection()?.textViews.map(\.surfaceText.string)
      .joined(separator: " ") ?? ""
    let words = middle.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init).filter { $0.count > 3 }
    j.result["middleWords"] = words.count
    j.result["middleWordsCopied"] = words.filter { plain.contains($0) }.count
    _ = host
    await j.capture("text-selected")
    await key(j, code: 53, characters: "\u{1b}")
    j.result["clearedByEscape"] = !selection.hasSelection
  }

  /// Message selection by dragging beside bubbles (#33): the drag selects every message it passes; checkmarks;
  /// select all (Cmd-A); the selection bar; Escape leaves selection.
  static func runSelectMessages(_ j: Journey) async {
    await j.show(longChat)
    if let list = j.list() { await j.untilRest(list) } else { await Journey.sleep(ms: 1000) }
    await takeKey(j)
    guard let found = selection(j), let controller = found.1 as? any ChatMessageListController else {
      return j.fail("no list selection")
    }
    let (_, host, rows) = found
    guard let region = rows.autoscrollRegion(insetsOnly: true) else { return j.fail("no rows region") }
    // Incoming messages on screen (left aligned): the row's far side is background, where a drag selects messages.
    let incoming = rows.placedRows.compactMap { row -> (Int, NSPoint)? in
      guard let cell = rows.cell(atRow: row), let message = host.textSelectionMessage(atRow: row),
            message.message.out != true, controller.canSelectMessage(atRow: row) else { return nil }
      let frame = cell.convert(cell.bounds, to: nil)
      guard frame.minY >= region.minY, frame.maxY <= region.maxY else { return nil }
      let point = NSPoint(x: region.maxX - 24, y: frame.midY)
      guard let hit = rows.hit(atWindowPoint: point), !(hit is NSTextView), !(hit is any MessageTextSurface) else { return nil }
      return (row, point)
    }.sorted { $0.1.y > $1.1.y }
    j.result["incomingRowsOnScreen"] = incoming.count
    guard incoming.count >= 4 else { return j.fail("fewer than 4 incoming rows on screen") }
    let from = incoming[0], to = incoming[3]
    await pressAndDrag(j, from: from.1, to: to.1)
    await Journey.sleep(ms: 300)
    j.result["activeAfterDrag"] = controller.isMessageSelectionActive
    j.result["selectedAfterDrag"] = controller.selectedMessageStableIds.count
    j.result["rowsDragged"] = (min(from.0, to.0) ... max(from.0, to.0)).filter { controller.canSelectMessage(atRow: $0) }.count
    j.result["checkmarksAfterDrag"] = checkmarks(rows)
    await j.capture("messages-selected")
    await key(j, code: 0, characters: "a", modifiers: .command)
    await Journey.sleep(ms: 300)
    j.result["selectedAfterSelectAll"] = controller.selectedMessageStableIds.count
    j.result["selectableLoaded"] = (0 ..< rows.numberOfRows).filter { controller.canSelectMessage(atRow: $0) }.count
    j.result["checkmarksAfterSelectAll"] = checkmarks(rows)
    let bar = Journey.largestVisible(ForwardMessageSelectionBar.self, in: j.window.contentView)
    j.result["selectionBarShown"] = bar.map { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.5 } ?? false
    await j.capture("select-all")
    await key(j, code: 53, characters: "\u{1b}")
    await Journey.sleep(ms: 400)
    j.result["activeAfterEscape"] = controller.isMessageSelectionActive
    j.result["checkmarksAfterEscape"] = checkmarks(rows)
  }

  /// Rich text's own gestures in the rich chat (Core Text in a layer, or TextKit with `-debug.richLayerText NO`): a
  /// drag within one block and across a message's blocks, copied; a double click on a word; what a press on a link
  /// hits (not clicked: that would open a browser); the right-click menu's Look Up and Translate.
  static func runRichSelect(_ j: Journey) async {
    await j.show(richChat)
    if let list = j.list() { await j.untilRest(list) } else { await Journey.sleep(ms: 1000) }
    await takeKey(j)
    guard let found = selection(j) else { return j.fail("no list selection") }
    let (selection, _, rows) = found
    let board = NSPasteboard(name: NSPasteboard.Name("chat.inline.timeline-journey"))
    func copied() -> [String: Any] {
      board.clearContents()
      let ok = selection.copySelection(to: board)
      let plain = board.string(forType: .string) ?? ""
      return [
        "copied": ok, "plain": String(plain.prefix(120)), "plainLength": plain.count,
        "markdownBytes": board.data(forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))?.count ?? 0,
        "htmlBytes": board.data(forType: .html)?.count ?? 0, "rtfBytes": board.data(forType: .rtf)?.count ?? 0,
      ]
    }
    func windowPoint(_ surface: NSView, x: CGFloat, fromTop y: CGFloat) -> NSPoint {
      surface.convert(NSPoint(x: x, y: surface.isFlipped ? y : surface.bounds.height - y), to: nil)
    }
    func center(of range: NSRange, in surface: any MessageTextSurface) -> NSPoint? {
      guard let window = surface.window else { return nil }
      let rect = window.convertFromScreen(surface.firstLineScreenRect(for: range))
      return rect.width > 0 ? NSPoint(x: rect.midX, y: rect.midY) : nil
    }
    // A rich message with several text blocks, wholly on screen.
    guard let message = textRows(rows).first(where: { $0.texts.count >= 3 }) else {
      return j.fail("no rich message with 3 text blocks on screen")
    }
    let surfaces = message.texts.compactMap { $0 as? any MessageTextSurface }
    j.result["surfaceClass"] = surfaces.first.map { String(describing: type(of: $0)) } ?? "none"
    j.result["blocks"] = surfaces.count

    // Within one block: from its start to the middle of its first line.
    let block = surfaces[0]
    await pressAndDrag(j, from: windowPoint(block, x: 3, fromTop: 8), to: windowPoint(block, x: block.bounds.width / 2, fromTop: 8))
    var within = copied()
    let blockText = block.surfaceText.string
    within["inBlock"] = !(within["plain"] as? String ?? "").isEmpty && blockText.contains((within["plain"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    j.result["withinBlock"] = within

    // Across the message's blocks: first block's start to the last block's end.
    let lastBlock = surfaces[surfaces.count - 1]
    await pressAndDrag(
      j, from: windowPoint(block, x: 3, fromTop: 8),
      to: windowPoint(lastBlock, x: lastBlock.bounds.width - 3, fromTop: lastBlock.bounds.height - 6)
    )
    var across = copied()
    let middleWords = surfaces[1].surfaceText.string.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
      .map(String.init).filter { $0.count > 3 }
    let plainAcross = board.string(forType: .string) ?? ""
    across["middleBlockWords"] = middleWords.count
    across["middleBlockWordsCopied"] = middleWords.filter { plainAcross.contains($0) }.count
    j.result["acrossBlocks"] = across
    await j.capture("across-blocks")
    await key(j, code: 53, characters: "\u{1b}")

    // A double click on a word, in the same block found again: after the selections and Escape its text view can be
    // another one (the original left the window in about half the runs, before tonight's changes too).
    let blockStillShown = block.window != nil
    j.result["blockReplacedAfterEscape"] = !blockStillShown
    if !blockStillShown { await Journey.sleep(ms: 300) }
    let refound = textRows(rows).first(where: { $0.texts.count >= 3 })?.texts
      .compactMap { $0 as? any MessageTextSurface }.first
    let wordBlock: any MessageTextSurface = blockStillShown ? block : (refound ?? block)
    let text = wordBlock.surfaceText.string as NSString
    var wordRange = NSRange(location: NSNotFound, length: 0)
    text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { word, range, _, stop in
      if let word, word.count >= 4 { wordRange = range; stop.pointee = true }
    }
    if wordRange.location != NSNotFound, let point = center(of: wordRange, in: wordBlock) {
      for clicks in [1, 2] {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
          if let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: j.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
          ) { NSApp.postEvent(event, atStart: false) }
          await Journey.sleep(ms: 40)
        }
      }
      await Journey.sleep(ms: 200)
      var double = copied()
      double["word"] = text.substring(with: wordRange)
      double["matches"] = (board.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == text.substring(with: wordRange)
      j.result["doubleClick"] = double
      await key(j, code: 53, characters: "\u{1b}")
    } else {
      j.result["doubleClick"] = "no word"
    }

    // The right-click menu on a word: Look Up and Translate.
    if wordRange.location != NSNotFound, let point = center(of: wordRange, in: wordBlock),
       let event = NSEvent.mouseEvent(
         with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
         windowNumber: j.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
       )
    {
      let titles = wordBlock.menu(for: event)?.items.map(\.title) ?? []
      j.result["menu"] = [
        "items": titles.count, "lookUp": titles.contains { $0.hasPrefix("Look Up") },
        "translate": titles.contains { $0.hasPrefix("Translate") }, "titles": Array(titles.prefix(12)),
      ]
      NativeTextMenuHelper.shared.dismiss(from: wordBlock)
    }

    // A link: what a press on it hits (links act on press and never start a selection; not clicked, which would open
    // a browser). The rich fixture's messages carry no link entities, so a plain message's link is checked when the
    // rich chat shows none: plain messages draw through the same Core Text surface.
    func findLink(_ rows: any MessageListRowGeometry) -> [String: Any]? {
      for row in rows.placedRows {
        for surface in rows.cell(atRow: row)?.textSelectionSource?.textSelectionProjection()?.textViews ?? [] {
          let range = (surface.surfaceText.string as NSString).range(of: "https://")
          guard range.location != NSNotFound, let point = center(of: range, in: surface) else { continue }
          let hit = surface.entityHit(at: surface.convert(point, from: nil), extraTextRanges: [])
          return ["hit": hit.map { "\($0)" } ?? "nil", "surfaceClass": String(describing: type(of: surface))]
        }
      }
      return nil
    }
    if var link = findLink(rows) {
      link["chat"] = "rich"
      j.result["link"] = link
    } else {
      await j.show(longChat)
      guard let list = j.list(), let plainRows = Self.selection(j)?.2 else { return }
      var link = findLink(plainRows)
      for _ in 0 ..< 4 where link == nil {
        await j.flick(list, dy: 30, count: 8)
        await j.untilRest(list)
        link = findLink(plainRows)
      }
      j.result["link"] = (link ?? ["found": false]).merging(["chat": "plain (rich fixture has no links)"]) { a, _ in a }
    }
  }

  /// Checkboxes showing in placed rows, and how many are checked.
  static func checkmarks(_ rows: any MessageListRowGeometry) -> [String: Int] {
    var shown = 0
    var checked = 0
    func walk(_ view: NSView) {
      if let mark = view as? ForwardMessageSelectionCheckmark {
        if !mark.isHiddenOrHasHiddenAncestor { shown += 1 }
        if !mark.isHiddenOrHasHiddenAncestor, mark.isSelected { checked += 1 }
        return
      }
      view.subviews.forEach(walk)
    }
    for row in rows.placedRows { if let cell = rows.cell(atRow: row) { walk(cell) } }
    return ["shown": shown, "checked": checked]
  }

  /// Light to dark and back: the cost of restyling every placed row.
  static func runAppearance(_ j: Journey) async {
    await j.show(longChat)
    guard let list = j.list() else { return j.fail("no timeline list") }
    let original = NSApp.appearance
    var steps: [[String: Any]] = []
    for (name, appearance) in [("dark", NSAppearance(named: .darkAqua)), ("light", NSAppearance(named: .aqua))] {
      let makes = list.diagnostics.makes
      let start = Journey.now()
      let frames = await j.measure {
        NSApp.appearance = appearance
        _ = await Journey.settle(from: Journey.now())
      }
      steps.append(["to": name, "settleMs": Journey.round(Journey.now() - start), "rowsMade": list.diagnostics.makes - makes, "frames": frames])
      await j.capture(name)
    }
    NSApp.appearance = original
    j.result["steps"] = steps
  }
}

// MARK: - Journey: the shared driving and measuring

@MainActor
final class Journey {
  typealias Row = TimelineJourneyRunner.Row
  typealias List = TimelineJourneyRunner.List

  let window: NSWindow
  let open: @MainActor (Peer) -> Void
  let outDir: URL
  let label: String
  let log: URL
  var homeFrame: NSRect = .zero
  var scenario = ""
  var result: [String: Any] = [:]
  private var pendingCaptures: [URL] = []
  private let captureMode = TimelineJourneyRunner.argument("--timeline-journey-captures") ?? "external"

  init(window: NSWindow, open: @escaping @MainActor (Peer) -> Void, outDir: URL, label: String, log: URL) {
    self.window = window
    self.open = open
    self.outDir = outDir
    self.label = label
    self.log = log
  }

  func begin(_ name: String) {
    scenario = name
    result = ["scenario": name, "load": Self.loadAverage(),
              "certified": !CommandLine.arguments.contains("--timeline-journey-uncertified")]
    note("\(name) start")
  }

  func finish() {
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
      let url = outDir.appendingPathComponent("\(label).jsonl")
      if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data + Data("\n".utf8))
        try? handle.close()
      } else {
        try? (data + Data("\n".utf8)).write(to: url)
      }
    }
    note("\(scenario) done")
  }

  func fail(_ message: String) {
    result["error"] = message
    note("\(scenario) error: \(message)")
  }

  func note(_ line: String) {
    guard let handle = try? FileHandle(forWritingTo: log) else { return }
    handle.seekToEndOfFile()
    handle.write(Data("\(Date().timeIntervalSince1970) \(line)\n".utf8))
    try? handle.close()
  }

  // MARK: Finding things

  /// The new list showing in the window (the largest visible one).
  func list() -> List? {
    Self.largestVisible(List.self, in: window.contentView)
  }

  /// Opens a chat and waits for its rows and a free main thread.
  func show(_ peer: Peer) async {
    let previous = list().map(ObjectIdentifier.init)
    let start = Self.now()
    open(peer)
    while Self.now() - start < 4000 {
      if MainWindowController.all.first?.scriptingPrimaryChat == peer, let list = list(),
         ObjectIdentifier(list) != previous || previous == nil, list.diagnostics.placedCount > 0
      {
        break
      }
      await Self.sleep(ms: 5)
    }
    if list() == nil { note("show \(peer): no timeline list (is -experimental.macTimelineList YES set?)") }
    _ = await Self.settle(from: Self.now())
    await Self.sleep(ms: 500)
  }

  /// The placed message row whose presented frame holds the list's vertical middle.
  func readingRow(_ list: List) -> Row? {
    let mid = list.bounds.midY
    return list.placedViews.lazy.compactMap { id, view -> Row? in
      guard case .message = id, let frame = list.presentedFrame(of: view), frame.minY <= mid, frame.maxY > mid else { return nil }
      return id
    }.first
  }

  /// The message row `offset` rows from `row` in the list's order (negative: older), among placed rows.
  func row(_ list: List, relativeTo row: Row, offset: Int) -> Row? {
    let ordered = list.placedViews.compactMap { id, _ -> (Row, CGFloat)? in
      guard case .message = id, let frame = list.frame(for: id) else { return nil }
      return (id, frame.minY)
    }.sorted { $0.1 < $1.1 }.map(\.0)
    guard let index = ordered.firstIndex(of: row) else { return nil }
    let target = index + offset
    return ordered.indices.contains(target) ? ordered[target] : nil
  }

  func messageRefs(_ peer: Peer) -> [Int64: PerfHarnessFixture.MessageRef] {
    let refs = (try? PerfHarnessFixture.messages(peer: peer)) ?? []
    return Dictionary(refs.map { ($0.globalId, $0) }, uniquingKeysWith: { a, _ in a })
  }

  /// The message `n` older than `row` in the chat's history (the database's order), placed or not.
  func older(_ peer: Peer, than row: Row, by n: Int) -> PerfHarnessFixture.MessageRef? {
    guard case let .message(id) = row, let refs = try? PerfHarnessFixture.messages(peer: peer),
          let index = refs.firstIndex(where: { $0.globalId == id }), index - n >= 0
    else { return nil }
    return refs[index - n]
  }

  /// Back to the newest end at once, for scenarios that start at the bottom after one that left the chat in history
  /// (`composer` after `resize`, `stream-switch` after `stream-reading`: measured scrolled up, their numbers meant
  /// nothing).
  func toNewest(_ list: List) async {
    list.apply(TimelineTransaction(scroll: .latest, timing: .none, towards: .newer))
    await untilRest(list)
    await Self.sleep(ms: 200)
  }

  /// Two flicks up into history, then rest.
  func toHistory(_ list: List) async {
    for _ in 0 ..< 2 {
      await flick(list, dy: 40, count: 10)
      await untilRest(list)
    }
    await Self.sleep(ms: 300)
  }

  // MARK: Input

  private func post(_ list: List, _ event: CGEvent) {
    event.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    let center = list.convert(NSPoint(x: list.bounds.midX, y: list.bounds.midY), to: nil)
    let screen = window.convertPoint(toScreen: center)
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    event.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
    guard let nsEvent = NSEvent(cgEvent: event) else { return }
    list.scrollWheel(with: nsEvent)
  }

  private static func trackpad(_ dy: Double, phase: Int64, momentum: Int64 = 0) -> CGEvent {
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0)!
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded()))
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    return event
  }

  /// A flick: `count` finger events of `dy` at 120 Hz, the lift, then the system's momentum at 60 Hz (first
  /// delta 1.5× the finger's, 5% decay per event), as a real trackpad sends them. Positive `dy` moves the content
  /// down (into history).
  func flick(_ list: List, dy: Double, count: Int) async {
    post(list, Self.trackpad(0, phase: 128))
    for index in 0 ..< count {
      post(list, Self.trackpad(dy, phase: index == 0 ? 1 : 2))
      await Self.sleep(ms: 8.33)
    }
    post(list, Self.trackpad(0, phase: 4))
    await Self.sleep(ms: 5)
    var delta = dy * 1.5
    post(list, Self.trackpad(delta, phase: 0, momentum: 1))
    while abs(delta) >= 1 {
      await Self.sleep(ms: 16.67)
      delta *= 0.95
      post(list, Self.trackpad(delta, phase: 0, momentum: 2))
    }
    post(list, Self.trackpad(0, phase: 0, momentum: 3))
  }

  /// A slow drag: `count` events of `dy` at 120 Hz, held still, then lifted (no fling). Returns each event's
  /// handling time (ms).
  func drag(_ list: List, dy: Double, count: Int) async -> [Double] {
    var times: [Double] = []
    post(list, Self.trackpad(0, phase: 128))
    for index in 0 ..< count {
      let t0 = Self.now()
      post(list, Self.trackpad(dy, phase: index == 0 ? 1 : 2))
      times.append(Self.now() - t0)
      await Self.sleep(ms: 8.33)
    }
    for _ in 0 ..< 6 {
      post(list, Self.trackpad(0, phase: 2))
      await Self.sleep(ms: 8.33)
    }
    post(list, Self.trackpad(0, phase: 4))
    return times
  }

  /// A held drag of up to `count` events of `dy` at 120 Hz; `each` runs after every event (the frame it moved has been
  /// committed) and returns false to stop early. Held still before the lift, so it does not fling.
  func heldDrag(_ list: List, dy: Double, count: Int, each: () async -> Bool) async {
    post(list, Self.trackpad(0, phase: 128))
    for index in 0 ..< count {
      post(list, Self.trackpad(dy, phase: index == 0 ? 1 : 2))
      await Self.sleep(ms: 8.33)
      if !(await each()) { break }
    }
    for _ in 0 ..< 6 {
      post(list, Self.trackpad(0, phase: 2))
      await Self.sleep(ms: 8.33)
    }
    post(list, Self.trackpad(0, phase: 4))
  }

  /// Until the list is neither tracking nor flinging and the main thread is free (at most 4 s).
  func untilRest(_ list: List) async {
    _ = await until(4000) { !list.diagnostics.isFlinging && !list.diagnostics.isTracking }
    _ = await Self.settle(from: Self.now())
  }

  /// Polls every millisecond until `condition` or `timeoutMs`. True when it held.
  func until(_ timeoutMs: Double, _ condition: () -> Bool) async -> Bool {
    let start = Self.now()
    while Self.now() - start < timeoutMs {
      if condition() { return true }
      await Self.sleep(ms: 1)
    }
    return condition()
  }

  /// A live resize by mouse events posted to the window's own resize loop at its bottom-right corner: `rounds`
  /// times out by (dx, dy) and back, 4 pt per 120 Hz step. With `hold`, goes out once and leaves it there.
  func liveResize(dx: CGFloat, dy: CGFloat, rounds: Int, hold: Bool = false, each: (() -> Void)? = nil) async {
    // The corner in screen coordinates: as the window resizes its origin moves, so each event's window location is
    // converted from the screen point it means through the window's current frame.
    let corner = NSPoint(x: window.frame.maxX - 3, y: window.frame.minY + 3)
    func at(_ screen: NSPoint) -> NSPoint { window.convertPoint(fromScreen: screen) }
    postMouse(.leftMouseDown, at: at(corner))
    await Self.sleep(ms: 40)
    let steps = Int(max(abs(dx), abs(dy)) / 4)
    func path(_ from: Int, _ to: Int) -> [Int] { from <= to ? Array(from ... to) : Array((to ... from).reversed()) }
    let legs = hold ? [path(0, steps)] : (0 ..< rounds).flatMap { _ in [path(0, steps), path(steps, 0)] }
    for leg in legs {
      for step in leg {
        let f = CGFloat(step) / CGFloat(max(steps, 1))
        postMouse(.leftMouseDragged, at: at(NSPoint(x: corner.x + dx * f, y: corner.y + dy * f)))
        await Self.sleep(ms: 8.33)
        each?()
      }
    }
    postMouse(.leftMouseUp, at: at(hold ? NSPoint(x: corner.x + dx, y: corner.y + dy) : corner))
    await Self.sleep(ms: 200)
  }

  private var eventNumber = 0

  private func postMouse(_ type: NSEvent.EventType, at point: NSPoint) {
    eventNumber += 1
    guard let event = NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
      pressure: type == .leftMouseUp ? 0 : 1
    ) else { return }
    NSApp.postEvent(event, atStart: false)
  }

  // MARK: Measuring

  /// Frames while `body` runs: hitches, the engine's work, and, per frame, what the options ask for:
  /// - `blank`: the largest uncovered strip between placed rows inside the list, and at its edges;
  /// - `topOf`: how far that row's presented top moved from where it was when `body` started (the reading row);
  /// - `bottomOf` / `bottomOfNewest`: how far that row's (or the newest placed row's) presented bottom moved;
  /// - `composerGap`: how far the distance between the newest row's bottom and the composer's top moved.
  func measure(
    blank: Bool = false, undrawnText: Bool = false, topOf: Row? = nil, bottomOf: Row? = nil, bottomOfNewest: Bool = false,
    composerGap composer: NSView? = nil, bubbleGapOf: Row? = nil, _ body: () async -> Void
  ) async -> [String: Any] {
    guard let list = list() else { return ["error": "no list"] }
    let probe = FrameProbe()
    let startDiag = list.diagnostics
    let cpu0 = Self.cpuMs()
    var blankMax: CGFloat = 0
    var edgeMax: CGFloat = 0
    var blankFrames = 0
    var performMax: CFTimeInterval = 0
    func newestBottom() -> CGFloat? {
      list.placedViews.compactMap { id, view -> CGFloat? in
        guard case .message = id else { return nil }
        return list.presentedFrame(of: view)?.maxY
      }.max()
    }
    func tracked() -> CGFloat? {
      if let topOf { return list.presentedFrame(for: topOf)?.minY }
      if let bottomOf { return list.presentedFrame(for: bottomOf)?.maxY }
      if let composer, let bottom = newestBottom() {
        let rowBottom = list.convert(NSPoint(x: 0, y: bottom), to: nil).y
        let composerTop = composer.convert(NSPoint(x: 0, y: composer.isFlipped ? 0 : composer.bounds.height), to: nil).y
        return rowBottom - composerTop
      }
      if bottomOfNewest { return newestBottom() }
      return nil
    }
    let reference = tracked()
    var drift: CGFloat = 0
    // The bubble's presented edges in the list (`bubbleGapOf`), through the presentation layer tree: at the pinned
    // bottom a growing bubble's bottom stays where it was (the rows above slide up), whatever the row frame reads.
    func bubbleGap() -> (top: CGFloat, bottom: CGFloat)? {
      guard let bubbleGapOf, let row = list.view(for: bubbleGapOf), let bubble = Self.bubble(in: row),
            let bubbleFrame = list.presentedFrame(of: bubble), let rowFrame = list.presentedFrame(for: bubbleGapOf)
      else { return nil }
      // `top`: the bubble's bottom on screen; `bottom`: the row's presented bottom minus it (constant while the bubble
      // follows the row).
      return (bubbleFrame.maxY, rowFrame.maxY - bubbleFrame.maxY)
    }
    var bubbleGapDrift: CGFloat = 0
    // Per frame while the bubble probe runs: ms since the start, the row's presented height, the bubble's top and
    // bottom gaps to the row's presented top and bottom (both constant while the bubble follows its row).
    var bubbleSeries: [[Double]] = []
    let seriesStart = Self.now()
    let insideTracks0 = TimelineMessageListAppKit.insideTracksAdded
    let bubbleReference = bubbleGap()
    var bubbleDrift: CGFloat = 0
    var lost = 0
    // Text views by first frame seen: one realised in this frame is drawn in this frame's commit, so only views
    // seen in an earlier frame and still without contents count as text missing on screen.
    var firstSeen: [ObjectIdentifier: Int] = [:]
    var frameIndex = 0
    var undrawnFrames = 0
    var undrawnMax = 0
    var undrawnRows = Set<String>()
    probe.perFrame = {
      frameIndex += 1
      if bubbleReference != nil {
        // Changes made this frame and not yet committed show on the model but their animations don't
        // (`presentation()` ignores uncommitted animations): commit first, so every read below sees what will show
        // (read before it, the row-bottom drift caught a reaction's new height without its animation: 3 pt).
        CATransaction.flush()
      }
      if undrawnText {
        var missing = 0
        for (id, row) in list.placedViews {
          guard let frame = list.presentedFrame(of: row), frame.maxY > 0, frame.minY < list.bounds.height else { continue }
          for text in Self.textViews(in: row) {
            let key = ObjectIdentifier(text)
            guard let seen = firstSeen[key] else {
              firstSeen[key] = frameIndex
              continue
            }
            if seen < frameIndex, !Self.hasContents(text) {
              missing += 1
              undrawnRows.insert("\(id)")
            }
          }
        }
        if missing > 0 { undrawnFrames += 1 }
        undrawnMax = max(undrawnMax, missing)
      }
      performMax = max(performMax, list.diagnostics.lastPerformDuration)
      if blank {
        let frames = list.placedViews.compactMap { list.presentedFrame(of: $0.1) }
          .filter { $0.maxY > 0 && $0.minY < list.bounds.height }.sorted { $0.minY < $1.minY }
        var gap: CGFloat = 0
        for (a, b) in zip(frames, frames.dropFirst()) { gap = max(gap, b.minY - a.maxY) }
        // At the newest end nothing lies below the newest row: the composer's inset (and a pull past the end) is the
        // end, not a hole. There the bottom edge counts only a gap above the usable bottom, at rest within the end
        // (counted, it read the 50–61 pt inset as uncovered after every drag back to the pinned end).
        let layout = list.timelineLayout
        let bottomEdge = layout.distanceToNewest != nil
          ? (abs(layout.restShift) > 0.5 ? 0 : max(0, list.bounds.height - list.bottomInset - (frames.last?.maxY ?? 0)))
          : list.bounds.height - (frames.last?.maxY ?? 0)
        let edges = max(frames.first.map { $0.minY } ?? list.bounds.height, bottomEdge)
        blankMax = max(blankMax, gap)
        edgeMax = max(edgeMax, edges)
        if gap > 0.5 { blankFrames += 1 }
      }
      if let reference {
        if let value = tracked() { drift = max(drift, abs(value - reference)) } else { lost += 1 }
      }
      if let bubbleReference, let value = bubbleGap() {
        bubbleDrift = max(bubbleDrift, abs(value.top - bubbleReference.top))
        bubbleGapDrift = max(bubbleGapDrift, abs(value.bottom - bubbleReference.bottom))
        if bubbleSeries.count < 2000, let bubbleGapOf, let row = list.view(for: bubbleGapOf),
           let bubble = Self.bubble(in: row), let bubbleFrame = list.presentedFrame(of: bubble),
           let rowFrame = list.presentedFrame(for: bubbleGapOf) {
          func r(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
          var revealed: Int?
          if case let .message(id) = bubbleGapOf { revealed = MessageStreamPacer.shared.revealedLength(for: id) }
          bubbleSeries.append([
            (Self.now() - seriesStart).rounded(), r(rowFrame.height), r(bubbleFrame.minY - rowFrame.minY),
            r(rowFrame.maxY - bubbleFrame.maxY), r(rowFrame.maxY), list.isMoving ? 1 : 0,
            list.timelineLayout.distanceToNewest.map { r($0) } ?? -1, r(list.timelineLayout.restShift),
            revealed.map(Double.init) ?? -1, Double(MessageStreamPacer.shared.linkState),
          ])
        }
      }
    }
    probe.start(on: window)
    await body()
    var stats = probe.stop()
    let end = list.diagnostics
    stats["performs"] = end.performCount - startDiag.performCount
    stats["performMs"] = Self.round((end.totalPerformDuration - startDiag.totalPerformDuration) * 1000)
    stats["performMaxMs"] = Self.round(performMax * 1000)
    stats["rowsMade"] = end.makes - startDiag.makes
    stats["attachMs"] = Self.round((end.totalAttachDuration - startDiag.totalAttachDuration) * 1000)
    stats["cpuMs"] = Self.round(Self.cpuMs() - cpu0)
    if undrawnText {
      stats["undrawnTextFrames"] = undrawnFrames
      stats["undrawnTextMaxPerFrame"] = undrawnMax
      stats["undrawnTextRows"] = undrawnRows.count
    }
    if blank {
      stats["blankGapMaxPt"] = Self.round(Double(blankMax))
      stats["blankFrames"] = blankFrames
      stats["edgeUncoveredMaxPt"] = Self.round(Double(edgeMax))
    }
    if bubbleReference != nil {
      stats["bubbleBottomDriftMaxPt"] = Self.round(Double(bubbleDrift))
      stats["bubbleToRowBottomDriftMaxPt"] = Self.round(Double(bubbleGapDrift))
      if let value = bubbleGap(), let bubbleReference {
        stats["bubbleBottomEndPt"] = Self.round(Double(value.top - bubbleReference.top))
      }
      stats["insideTracks"] = TimelineMessageListAppKit.insideTracksAdded - insideTracks0
      stats["bubbleSeries"] = bubbleSeries
      stats["insideTracked"] = Array(TimelineMessageListAppKit.insideTrackedClasses.sorted().prefix(40))
    }
    if reference != nil {
      stats["driftMaxPt"] = Self.round(Double(drift))
      if let value = tracked(), let reference { stats["driftEndPt"] = Self.round(Double(value - reference)) }
      if lost > 0 { stats["trackedLostFrames"] = lost }
    } else if topOf != nil || bottomOf != nil || bottomOfNewest || composer != nil {
      stats["driftError"] = "tracked row not placed at start"
    }
    return stats
  }

  /// A message row's bubble background (`MessageBubbleBackgroundView`), if it has one.
  /// The bubble, or in minimal style (no bubble) the message text, whose gaps to the row hold the same way.
  static func bubble(in root: NSView) -> NSView? {
    var stack = [root]
    var text: NSView?
    while let view = stack.popLast() {
      let name = String(describing: type(of: view))
      if name == "MessageBubbleBackgroundView" { return view }
      if text == nil, name == "CoreTextMessageView" { text = view }
      stack.append(contentsOf: view.subviews)
    }
    return text
  }

  /// The views that draw a row's text: plain text (`CoreTextGlyphView`) and rich blocks' TextKit views.
  static func textViews(in root: NSView) -> [NSView] {
    var found: [NSView] = []
    var stack = [root]
    while let view = stack.popLast() {
      if let glyph = view as? CoreTextGlyphView {
        if !glyph.textLayout.lines.isEmpty, !glyph.isHiddenOrHasHiddenAncestor { found.append(glyph) }
        continue
      }
      if let text = view as? MessageTextView {
        if !text.string.isEmpty, !text.isHiddenOrHasHiddenAncestor, text.bounds.height > 0 { found.append(text) }
        continue
      }
      stack.append(contentsOf: view.subviews)
    }
    return found
  }

  /// Whether the view's layer, or a layer under it, holds drawn contents.
  static func hasContents(_ view: NSView) -> Bool {
    guard let layer = view.layer else { return false }
    if layer.contents != nil { return true }
    var stack = layer.sublayers ?? []
    while let sublayer = stack.popLast() {
      if sublayer.contents != nil { return true }
      stack.append(contentsOf: sublayer.sublayers ?? [])
    }
    return false
  }

  // MARK: Captures

  /// A capture of the window as it shows now: an external capturer's (`screencapture -l`, served by `run.sh`) when
  /// one answers within 2 s, else the window's own drawing.
  func capture(_ tag: String) async {
    guard captureMode != "none" else { return }
    let png = outDir.appendingPathComponent("\(label)-\(scenario)-\(tag).png")
    try? FileManager.default.removeItem(at: png)
    if captureMode == "external" {
      requestCapture(png)
      if await until(2000, { (try? png.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 }) { return }
      note("capture \(tag): no external capturer, drawing in-app")
    }
    drawInApp(to: png)
  }

  /// A capture requested now and taken by the external capturer as soon as it can (mid-motion); not waited for.
  func captureSoon(_ tag: String, after seconds: Double) {
    guard captureMode == "external" else { return }
    let png = outDir.appendingPathComponent("\(label)-\(scenario)-\(tag).png")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.requestCapture(png) }
  }

  private func requestCapture(_ png: URL) {
    let request = png.deletingPathExtension().appendingPathExtension("request")
    try? Data("\(window.windowNumber)\n".utf8).write(to: request)
    pendingCaptures.append(request)
  }

  func drainCaptures() async {
    _ = await until(4000) { pendingCaptures.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
  }

  private func drawInApp(to png: URL) {
    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: png)
  }

  // MARK: Helpers

  static func largestVisible<T: NSView>(_ type: T.Type, in root: NSView?) -> T? {
    guard let root else { return nil }
    var best: T?
    var stack = [root]
    while let view = stack.popLast() {
      // A chat switch leaves the outgoing chat transparent in the window until the incoming one shows its
      // first messages: not what's on screen.
      if let match = view as? T, !match.isHiddenOrHasHiddenAncestor, !isTransparent(match),
         match.bounds.width * match.bounds.height > (best.map { $0.bounds.width * $0.bounds.height } ?? 0)
      {
        best = match
      }
      stack.append(contentsOf: view.subviews)
    }
    return best
  }

  static func isTransparent(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
      if candidate.alphaValue <= 0.001 { return true }
      current = candidate.superview
    }
    return false
  }

  /// Milliseconds until the main thread is free: three main-queue hops in a row under 3 ms.
  static func settle(from start: Double, limitMs: Double = 4000) async -> Double {
    var fast = 0
    while now() - start < limitMs {
      let t = now()
      await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
      fast = now() - t < 3 ? fast + 1 : 0
      if fast >= 3 { return t - start }
      await sleep(ms: 4)
    }
    return limitMs
  }

  static func sleep(ms: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, ms) * 1_000_000))
  }

  static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e6 }

  static func cpuMs() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
    return ms(usage.ru_utime) + ms(usage.ru_stime)
  }

  static func loadAverage() -> Double {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) > 0 ? round(loads[0]) : -1
  }

  static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }

  static func stats(_ values: [Double]) -> [String: Any] {
    guard !values.isEmpty else { return ["n": 0] }
    let sorted = values.sorted()
    func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
    return ["n": values.count, "median": round(at(0.5)), "p95": round(at(0.95)), "max": round(sorted.last ?? 0)]
  }

  private static let sentences = [
    "Reading the files you pointed at, the cache is rebuilt on every launch.",
    "The fix is small: keep the measured layout per width and reuse it.",
    "I ran the tests again and they pass on both machines.",
    "Next I'll check the scroll position after a resize.",
    "Here is a summary of what changed and why.",
    "One thing to watch: long code blocks wrap differently at narrow widths.",
    "Done with the first pass.",
    "That should cover the edge case you mentioned yesterday.",
  ]

  static func sentence(_ index: Int) -> String { sentences[index % sentences.count] }
}

/// Counts display frames on the window's screen and runs a probe on each (main thread).
@MainActor
final class FrameProbe: NSObject {
  private var link: CADisplayLink?
  private var stamps: [CFTimeInterval] = []
  private var expected: CFTimeInterval = 1.0 / 60
  var perFrame: (() -> Void)?

  func start(on window: NSWindow) {
    guard let view = window.contentView else { return }
    expected = window.screen?.minimumRefreshInterval ?? 1.0 / 60
    let link = view.displayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  @objc private func tick(_ link: CADisplayLink) {
    stamps.append(link.timestamp)
    perFrame?()
  }

  /// Frames seen, hitches (an interval over 1.5× the refresh) and the frames they lost, the worst interval.
  func stop() -> [String: Any] {
    link?.invalidate()
    link = nil
    perFrame = nil
    let intervals = zip(stamps, stamps.dropFirst()).map { $1 - $0 }
    let hitches = intervals.filter { $0 > expected * 1.5 }
    let lost = hitches.reduce(0) { $0 + max(0, Int(($1 / expected).rounded()) - 1) }
    return [
      "frames": stamps.count,
      "refreshMs": Journey.round(expected * 1000),
      "hitches": hitches.count,
      "lostFrames": lost,
      "worstIntervalMs": Journey.round((intervals.max() ?? 0) * 1000),
    ]
  }
}
#endif
