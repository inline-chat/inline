import AppKit
import TimelineAppKit
import TimelineCore

/// Runs scripts against the new list in a chat-like window and records what is on screen every frame.
@MainActor
final class EngineScenario: Scenario {
  enum Start {
    case latest
    case oldest
    case middle
    /// Latest, then this far up.
    case aboveLatest(CGFloat)
    /// Oldest, then this far down.
    case belowOldest(CGFloat)
  }

  struct Script {
    var count = 3000
    var rowCost: Double = 0
    var start: Start = .middle
    var size = NSSize(width: 520, height: 760)
    var tail: Double = 1.6
    var steps: (EngineScenario) -> [Synth.Step]
  }

  let name: String
  let script: Script
  var window: NSWindow?
  var view: LabChatView!
  var player: Player?
  let probe = Probe()
  /// The row whose screen position a script follows (the reading row when the script starts).
  var tracked: Int?

  init(name: String, script: Script) {
    self.name = name
    self.script = script
  }

  var list: TimelineListView<Int> { view.list }

  func run(done: @escaping (Probe) -> Void) {
    let window = Scenarios.window(size: script.size, title: "engine.\(name)")
    self.window = window
    let chat = LabChat(count: script.count)
    chat.rowCost = script.rowCost
    let view = LabChatView(chat: chat)
    view.frame = window.contentView!.bounds
    view.autoresizingMask = [.width, .height]
    window.contentView!.addSubview(view)
    self.view = view
    view.layoutSubtreeIfNeeded()
    view.start()
    switch script.start {
      case .latest: break
      case .oldest: list.apply(TimelineTransaction(scroll: .to(chat.ids[0], .top(0))))
      case .middle: list.apply(TimelineTransaction(scroll: .to(chat.ids[chat.ids.count / 2], .top(200))))
      case let .aboveLatest(distance): list.apply(TimelineTransaction(scroll: .by(distance)))
      case let .belowOldest(distance):
        list.apply(TimelineTransaction(scroll: .to(chat.ids[0], .top(0))))
        list.apply(TimelineTransaction(scroll: .by(-distance)))
    }
    if case let .row(id, _) = list.position { tracked = id } else { tracked = list.timelineLayout.placements.last?.id }
    probe.note("start", list.diagnostics.presentedScrollPosition)
    probe.note("hasNativeMomentum", NativeScrolling.hasNativeMomentum ? 1 : 0)
    probe.read = { [unowned self] in self.read() }
    probe.start(on: list)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
      let delivery = argument("--delivery") ?? "direct"
      let windowNumber = window.windowNumber
      let center = list.convert(NSPoint(x: list.bounds.midX, y: list.bounds.midY), to: nil)
      let screenPoint = window.convertPoint(toScreen: center)
      let mainHeight = NSScreen.screens.first?.frame.height ?? 0
      let globalPoint = CGPoint(x: screenPoint.x, y: mainHeight - screenPoint.y)
      if delivery == "hid" { CGWarpMouseCursorPosition(globalPoint) }
      let steps = script.steps(self).map { step in
        step.event?.location = globalPoint
        step.event?.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
        step.event?.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        return step
      }
      let player = Player(steps: steps, delivery: delivery) { [unowned self] event, label in
        probe.input(event, label: label)
        if delivery == "direct" { list.scrollWheel(with: event) }
        probe.sample(["afterEvent": 1])
      }
      player.onStep = { [unowned self] label in
        probe.sample(["action": 1])
        probe.text("action.\(probe.now)", label)
      }
      player.onFinish = { [unowned self] in
        DispatchQueue.main.asyncAfter(deadline: .now() + script.tail) {
          probe.stop()
          probe.note("end", list.diagnostics.presentedScrollPosition)
          probe.note("makes", Double(chat.makes))
          probe.note("updates", Double(chat.updates))
          done(probe)
        }
      }
      self.player = player
      player.start()
    }
  }

  /// What is on screen now: the content's presented scroll position, the tracked row, the newest row's bottom and
  /// the composer's top, all in the list's coordinates.
  func read() -> [String: Double] {
    let diagnostics = list.diagnostics
    var values: [String: Double] = [
      "origin": Double(diagnostics.presentedScrollPosition),
      "modelOrigin": Double(diagnostics.scrollPosition),
      "placed": Double(diagnostics.placedCount),
      "lingering": Double(diagnostics.lingeringCount),
      "performMs": diagnostics.lastPerformDuration * 1000,
    ]
    if let tracked, let frame = list.presentedFrame(for: tracked) { values["tracked"] = Double(frame.minY) }
    if let newest = view.chat.ids.last, let frame = list.presentedFrame(for: newest) { values["newestBottom"] = Double(frame.maxY) }
    if let layer = view.composer.layer {
      let presented = layer.presentation() ?? layer
      values["composerTop"] = Double(presented.frame.minY)
    }
    values["usableBottom"] = Double(list.bounds.height - list.bottomInset)
    // Whether the settled rows cover the usable area (no blank strip), unless the content ends there.
    let layout = list.timelineLayout
    if let first = layout.placements.first, let last = layout.placements.last {
      let gapTop = first.index == 0 ? 0 : max(0, first.y - layout.viewport.usableTop)
      let gapBottom = last.index == layout.placements.count + first.index - 1 && last.index == view.chat.ids.count - 1 ? 0 : max(0, layout.viewport.usableBottom - last.maxY)
      values["gap"] = Double(gapTop + gapBottom)
    }
    values["pinned"] = list.position == .latest ? 1 : 0
    return values
  }

  // MARK: - Scripts

  static var scripts: [String: Script] {
    var all: [String: Script] = [:]
    // The native scripts, from the same place in a chat.
    for (name, native) in NativeScenario.scripts {
      var start: Start = .middle
      switch name {
        case "pullTop", "pullTopFine": start = .oldest
        case "pullBottom": start = .latest
        case "flingBottom": start = .aboveLatest(400)
        case "flingTop": start = .belowOldest(400)
        default: break
      }
      all[name] = Script(start: start, tail: native.tail, steps: { _ in native.steps })
    }

    // Anchoring: history pages, arrivals and row growth while the reader scrolls and flings. The tracked row must
    // move only by the scroll.
    all["anchorDuringFling"] = Script(count: 400, start: .middle, tail: 2.5, steps: { s in
      var steps = Synth.gesture(start: 0.2, delta: 24, count: 10, label: "fling")
      for (i, t) in [0.35, 0.5, 0.65, 0.8].enumerated() {
        steps.append(Synth.Step(at: t, label: "prepend\(i)") { s.prependPage() })
      }
      for t in [0.42, 0.58, 0.9] {
        steps.append(Synth.Step(at: t, label: "arrive") { s.arrive() })
      }
      steps.append(Synth.Step(at: 0.7, label: "growAbove") { s.growAboveTracked() })
      return steps
    })
    all["anchorAtRest"] = Script(count: 400, start: .middle, tail: 1.2, steps: { s in
      [
        Synth.Step(at: 0.2, label: "prepend") { s.prependPage() },
        Synth.Step(at: 0.5, label: "arrive") { s.arrive() },
        Synth.Step(at: 0.8, label: "growAbove") { s.growAboveTracked() },
        Synth.Step(at: 1.1, label: "shrinkAbove") { s.growAboveTracked(shrink: true) },
        Synth.Step(at: 1.4, label: "deleteAbove") { s.deleteAboveTracked() },
        Synth.Step(at: 1.7, label: "growTracked") { s.growTracked() },
      ]
    })
    // Pinned to the newest row: arrivals rise in, a streaming message grows, the composer grows and shrinks.
    all["pinnedLive"] = Script(count: 300, start: .latest, tail: 1.2, steps: { s in
      var steps: [Synth.Step] = []
      steps.append(Synth.Step(at: 0.2, label: "arrive") { s.arrive() })
      steps.append(Synth.Step(at: 0.25, label: "arrive") { s.arrive() })
      steps.append(Synth.Step(at: 0.8, label: "streamStart") { s.streamStart() })
      for i in 0 ..< 10 { steps.append(Synth.Step(at: 0.9 + Double(i) * 0.12, label: "stream") { s.streamStep() }) }
      steps.append(Synth.Step(at: 2.3, label: "composer4") { s.view.setComposerLines(4) })
      steps.append(Synth.Step(at: 2.9, label: "composer1") { s.view.setComposerLines(1) })
      steps.append(Synth.Step(at: 3.0, label: "arriveDuringInset") { s.arrive() })
      steps.append(Synth.Step(at: 3.6, label: "deleteNewest") { s.deleteNewest() })
      return steps
    })
    // Scrolled up: the composer grows; the reading row follows the composer's top, as content follows a keyboard.
    all["insetScrolled"] = Script(count: 300, start: .aboveLatest(600), tail: 1.2, steps: { s in
      [
        Synth.Step(at: 0.2, label: "composer5") { s.view.setComposerLines(5) },
        Synth.Step(at: 0.35, label: "composer2") { s.view.setComposerLines(2) },
        Synth.Step(at: 0.9, label: "composer1") { s.view.setComposerLines(1) },
        Synth.Step(at: 1.4, label: "arrive") { s.arrive() },
      ]
    })
    // A live resize: the window's width sweeps every frame, as a drag of its edge does.
    all["liveResize"] = Script(count: 2000, start: .middle, size: NSSize(width: 900, height: 760), tail: 0.6, steps: { s in
      var steps: [Synth.Step] = []
      var t = 0.2
      for w in Array(stride(from: 900, through: 420, by: -8)) + Array(stride(from: 420, through: 1200, by: 10)) + Array(stride(from: 1200, through: 900, by: -10)) {
        steps.append(Synth.Step(at: t, label: "w\(w)") { s.resize(width: CGFloat(w)) })
        t += 1.0 / 60
      }
      return steps
    })
    all["liveResizePinned"] = Script(count: 2000, start: .latest, size: NSSize(width: 900, height: 760), tail: 0.6, steps: { s in
      var steps: [Synth.Step] = []
      var t = 0.2
      for w in Array(stride(from: 900, through: 420, by: -8)) + Array(stride(from: 420, through: 900, by: 10)) {
        steps.append(Synth.Step(at: t, label: "w\(w)") { s.resize(width: CGFloat(w)) })
        t += 1.0 / 60
      }
      for h in stride(from: 760, through: 400, by: -10) {
        steps.append(Synth.Step(at: t, label: "h\(h)") { s.resize(height: CGFloat(h)) })
        t += 1.0 / 60
      }
      return steps
    })
    // Cost: fast flings through a long chat with heavy rows, and with the main thread stalling mid-fling.
    all["perfFling"] = Script(count: 5000, rowCost: 1.0, start: .middle, tail: 3, steps: { _ in
      Synth.gesture(start: 0.2, delta: 64, count: 8, label: "fling")
    })
    all["perfStall"] = Script(count: 5000, rowCost: 1.0, start: .middle, tail: 3, steps: { s in
      var steps = Synth.gesture(start: 0.2, delta: 40, count: 8, label: "fling")
      for t in [0.45, 0.7, 0.95] {
        steps.append(Synth.Step(at: t, label: "stall80") { s.stall(0.08) })
      }
      return steps
    })
    // A long drag with rows realised under it at the trackpad's pace.
    all["perfDrag"] = Script(count: 5000, rowCost: 1.0, start: .middle, tail: 1, steps: { _ in
      Synth.gesture(start: 0.2, delta: 18, count: 200, label: "drag")
    })
    return all
  }

  // MARK: - Actions

  func prependPage() {
    let ids = view.chat.prepend(50)
    _ = ids
    list.apply(TimelineTransaction(rows: view.chat.ids, arrives: false))
  }

  func arrive() {
    view.chat.append("new message \(view.chat.ids.count) " + String(repeating: "arriving ", count: Int.random(in: 1 ... 8)))
    list.apply(TimelineTransaction(rows: view.chat.ids, timing: .standard))
  }

  private var streaming: Int?
  func streamStart() {
    streaming = view.chat.append("streaming…", outgoing: false)
    list.apply(TimelineTransaction(rows: view.chat.ids, timing: .standard))
  }

  func streamStep() {
    guard let id = streaming, let row = view.chat.row(id) else { return }
    view.chat.setText(id, row.text + " and some more streamed words that wrap")
    list.apply(TimelineTransaction(changed: [id], timing: .streamingLine))
  }

  func deleteNewest() {
    guard let id = view.chat.ids.last else { return }
    view.chat.delete(id)
    list.apply(TimelineTransaction(rows: view.chat.ids, timing: .standard))
  }

  /// A row above the tracked one that is on screen changes height (a reaction, an edit).
  func growAboveTracked(shrink: Bool = false) {
    guard let tracked, let target = rowAbove(tracked) else { return }
    guard let row = view.chat.row(target) else { return }
    view.chat.setText(target, shrink ? String(row.text.prefix(12)) : row.text + " grown by a few more words to wrap onto more lines")
    list.apply(TimelineTransaction(changed: [target], timing: .standard))
  }

  func growTracked() {
    guard let tracked, let row = view.chat.row(tracked) else { return }
    view.chat.setText(tracked, row.text + " the reading row itself grows by a line or two of words")
    list.apply(TimelineTransaction(changed: [tracked], timing: .standard))
  }

  func deleteAboveTracked() {
    guard let tracked, let target = rowAbove(tracked) else { return }
    view.chat.delete(target)
    list.apply(TimelineTransaction(rows: view.chat.ids, timing: .standard))
  }

  private func rowAbove(_ id: Int) -> Int? {
    let placements = list.timelineLayout.placements
    guard let at = placements.firstIndex(where: { $0.id == id }) else { return nil }
    return placements[..<at].last(where: { $0.maxY > list.topInset && !(view.chat.row($0.id)?.isDay ?? true) })?.id
  }

  func resize(width: CGFloat? = nil, height: CGFloat? = nil) {
    guard let window else { return }
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
}
