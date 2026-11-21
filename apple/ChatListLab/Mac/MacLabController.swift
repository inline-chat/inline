import AppKit
import ChatListCore
import ChatListAppKit

private final class FlippedRootView: NSView {
  override var isFlipped: Bool { true }
}

private final class PassiveOverlay: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class ActionButton: NSButton {
  var handler: (() -> Void)?

  init(_ label: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    title = label
    bezelStyle = .rounded
    target = self
    action = #selector(pressed)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  @objc private func pressed() { handler?() }
}

@MainActor
final class MacLabController: NSViewController {
  private struct GlyphWitness {
    let row: Int64
    let character: Int
    let y: CGFloat
    let edge: TimelineAnchorEdge
    let viewportPoint: CGFloat
    let edgeDistance: CGFloat
    let rowFrame: CGRect
    let localY: CGFloat
    let bodyFrame: CGRect
  }

  private let session = ChatListSession<Int64, LabContent>()
  private lazy var list = ChatListView<Int64, LabContent>(
    session: session,
    configuration: .init(usesAutomaticDisplayClock: !replayRequested),
    makeCell: { _, recycled in recycled ?? MacLabTextCell(frame: .zero) }
  )
  private var scenario = LabScenario()
  private var probe = LabGeometryProbe()
  private var replay = LabReplay()
  private let replayRequested = CommandLine.arguments.contains("--replay")
    || CommandLine.arguments.contains("--replay-exit")
    || CommandLine.arguments.contains("--replay-events")
  private let requestedReplayEvents: Int = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--replay-events"),
          arguments.indices.contains(index + 1),
          let count = Int(arguments[index + 1]) else { return 2_048 }
    return min(2_048, max(0, count))
  }()
  private let controls = NSStackView()
  private let status = NSTextField(labelWithString: "Native text · prepared geometry")
  private let topOcclusion = PassiveOverlay()
  private let bottomOcclusion = PassiveOverlay()
  private let decorations = MacDecorations()
  private var replayRunning = false
  private var hasStartedLaunchReplay = false
  private var widthReduction: CGFloat = 0
  private var transactionTime: Double?
  private var manualClock: Double?

  override func loadView() {
    view = FlippedRootView(frame: CGRect(x: 0, y: 0, width: 900, height: 720))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    controls.orientation = .vertical
    controls.distribution = .fillEqually
    controls.spacing = 5
    for row in [
      [("Older", LabOperation.prepend), ("Newer", .append), ("Delete", .delete), ("Height", .toggleHeight)],
      [("Top", LabOperation.topInset), ("Bottom", .bottomInset), ("Both", .heightAndInset), ("Width", .resizeWidth)]
    ] {
      let buttons = NSStackView()
      buttons.orientation = .horizontal
      buttons.distribution = .fillEqually
      buttons.spacing = 5
      for (label, operation) in row {
        buttons.addArrangedSubview(ActionButton(label) { [weak self] in self?.perform(operation) })
      }
      controls.addArrangedSubview(buttons)
    }
    let navigation = NSStackView()
    navigation.orientation = .horizontal
    navigation.distribution = .fillEqually
    navigation.spacing = 5
    navigation.addArrangedSubview(ActionButton("Latest") { [weak self] in self?.showLatest() })
    navigation.addArrangedSubview(ActionButton("Replay") { [weak self] in self?.startReplay() })
    controls.addArrangedSubview(navigation)
    status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    status.maximumNumberOfLines = 2
    for (overlay, color) in [
      (topOcclusion, NSColor.systemOrange.withAlphaComponent(0.36)),
      (bottomOcclusion, NSColor.systemPurple.withAlphaComponent(0.36))
    ] {
      overlay.wantsLayer = true
      overlay.layer?.backgroundColor = color.cgColor
    }
    view.addSubview(controls)
    view.addSubview(list)
    view.addSubview(status)

    list.bindCell = { view, item, _ in (view as? MacLabTextCell)?.bind(item) }
    list.presentCell = { view, placement in (view as? MacLabTextCell)?.present(placement) }
    list.recycleCell = { view in (view as? MacLabTextCell)?.recycle() }
    list.captureCellAnchor = { view, _, visible in (view as? MacLabTextCell)?.capture(visible) }
    list.resolveCellAnchor = { view, _, anchor in (view as? MacLabTextCell)?.resolve(anchor) }
    list.presentOverlays = { [weak self] root, layout in
      guard let self else { return }
      if self.topOcclusion.superview !== root { root.addSubview(self.topOcclusion) }
      if self.bottomOcclusion.superview !== root { root.addSubview(self.bottomOcclusion) }
      self.topOcclusion.frame = CGRect(
        x: 0, y: 0, width: layout.viewport.width, height: layout.viewport.topInset
      )
      self.bottomOcclusion.frame = CGRect(
        x: 0, y: layout.viewport.height - layout.viewport.bottomInset,
        width: layout.viewport.width, height: layout.viewport.bottomInset
      )
      self.decorations.present(in: root, placements: self.session.decorationPlacements)
    }
    session.onNeedsSnapshot = { [weak self] _ in
      guard let self else { return }
      _ = self.applyCurrent(at: self.transactionTime ?? ProcessInfo.processInfo.systemUptime, animation: .none)
    }
    session.onPreparationError = { [weak self] error in self?.status.stringValue = "Preparation: \(error)" }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    controls.frame = CGRect(x: 12, y: 10, width: view.bounds.width - 24, height: 96)
    let listTop = controls.frame.maxY + 8
    let statusHeight: CGFloat = 35
    list.frame = CGRect(
      x: widthReduction / 2, y: listTop, width: max(180, view.bounds.width - widthReduction),
      height: max(1, view.bounds.height - listTop - statusHeight - 5)
    )
    status.frame = CGRect(x: 12, y: list.frame.maxY + 3, width: view.bounds.width - 24, height: statusHeight)
    list.layoutSubtreeIfNeeded()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    if replayRequested, !hasStartedLaunchReplay {
      hasStartedLaunchReplay = true
      startReplay()
    }
  }

  private func updateViewport(at time: Double, animation: ChatListAnimation) {
    guard list.bounds.width > 0, list.bounds.height > 0 else { return }
    transactionTime = time
    session.updateViewport(
      .init(width: list.bounds.width, height: list.bounds.height,
            topInset: scenario.topInset, bottomInset: scenario.bottomInset),
      displayScale: view.window?.backingScaleFactor ?? 1,
      animation: animation, at: time
    )
    transactionTime = nil
  }

  @discardableResult
  private func applyCurrent(at time: Double, animation: ChatListAnimation = .animated) -> Bool {
    let context = session.layoutContext
    guard context.width > 0 else { return false }
    do {
      _ = try session.apply(
        scenario.snapshot(width: context.width, scale: context.displayScale,
                          environmentRevision: context.environmentRevision),
        animation: animation, at: time
      )
      return true
    } catch {
      status.stringValue = "Apply failed: \(error)"
      return false
    }
  }

  private func perform(_ operation: LabOperation) {
    guard !replayRunning else { return }
    let time = nextTime()
    scenario.perform(operation, visibleID: session.timeline.layout.anchor()?.id)
    if operation == .resizeWidth { resizeList(at: time) }
    let generation = session.generation
    if operation.changesViewport { updateViewport(at: time, animation: .animated) }
    if session.generation == generation { _ = applyCurrent(at: time) }
    if manualClock != nil { list.advance(to: time + 0.4) }
    status.stringValue = "\(scenario.eventCount) · \(operation) · \(scenario.ids.count) rows"
  }

  private func showLatest() {
    let time = nextTime()
    session.navigate(to: .latest, animation: .animated, at: time)
    if manualClock != nil { list.advance(to: time + 0.4) }
  }

  private func nextTime() -> Double {
    guard let manualClock else { return ProcessInfo.processInfo.systemUptime }
    let next = manualClock + 0.5
    self.manualClock = next
    return next
  }

  private func resizeList(at time: Double) {
    widthReduction = widthReduction >= 96 ? 0 : widthReduction + 48
    transactionTime = time
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    transactionTime = nil
  }

  private func inspectNative(label: String) {
    let layout = session.timeline.layout
    let scale = view.window?.backingScaleFactor ?? 1
    probe.inspect(layout, label: label)
    probe.inspectNativeOrigin(list.scrollView.contentView.bounds.minY, expected: layout.originY,
                              scale: scale, label: label)
    for (id, view) in list.materializedCells {
      guard let cell = view as? MacLabTextCell,
            let placement = layout.placement(for: id),
            let item = session.item(for: id) else {
        probe.recordMissingGlyph(label: "\(label): unresolved native row \(id)")
        continue
      }
      probe.inspectNativeCell(
        id: id, slot: cell.superview?.frame, cell: cell.frame, body: cell.text.frame,
        placement: placement, expectedCellHeight: item.height, scale: scale, label: label
      )
    }
    for placement in session.decorationPlacements {
      probe.inspectDecoration(decorations.frame(for: placement.id), placement: placement,
                              scale: scale, label: label)
    }
    probe.inspectOcclusions(top: topOcclusion.frame, bottom: bottomOcclusion.frame,
                            viewport: layout.viewport, scale: scale, label: label)
  }

  private func runNegativeControl() {
    guard let witness = witness(), let cell = list.cell(for: witness.row) as? MacLabTextCell else {
      let layout = session.timeline.layout
      let details = list.materializedCells.compactMap { id, view -> String? in
        guard let cell = view as? MacLabTextCell,
              let placement = layout.placement(for: id),
              !placement.frame.intersection(layout.readingRect).isNull else { return nil }
        let visible = placement.frame.intersection(layout.readingRect).offsetBy(
          dx: -placement.frame.minX, dy: -placement.frame.minY
        )
        return cell.glyphDiagnostics(visible)
      }
      probe.recordMissingGlyph(
        label: "negative control; reading \(layout.readingRect), " +
          "intent \(session.timeline.intent), native candidates [\(details.joined(separator: "; "))]"
      )
      return
    }
    let origin = session.timeline.layout.originY
    let original = cell.text.frame
    cell.text.frame.origin.y += 6
    let shifted = cell.screenGlyphY(witness.character)
    cell.text.frame = original
    if let shifted {
      probe.inspectNegativeControl(
        originBefore: origin, originAfter: session.timeline.layout.originY,
        glyphBefore: witness.y, glyphAfter: shifted
      )
    } else {
      probe.recordMissingGlyph(label: "negative control")
    }
  }

  private func witness(edge requestedEdge: TimelineAnchorEdge? = nil) -> GlyphWitness? {
    let layout = session.timeline.layout
    let edge = requestedEdge ?? currentReadingEdge
    let visible = layout.visibleRows(in: layout.readingRect)
    let indices = edge == .top ? Array(visible) : Array(visible.reversed())
    for index in indices {
      let placement = layout.rows[index]
      guard !placement.isExiting, placement.row.canAnchor else { continue }
      guard let cell = list.cell(for: placement.row.id) as? MacLabTextCell else { continue }
      let local = layout.readingRect.intersection(placement.frame).offsetBy(
        dx: -placement.frame.minX, dy: -placement.frame.minY
      )
      guard let anchor = cell.capture(local),
            let token = anchor.token.base as? MacGlyphToken,
            let y = cell.screenGlyphY(token.character) else { continue }
      let viewportPoint = placement.frame.minY + anchor.localY - layout.originY
      let edgeDistance: CGFloat = switch edge {
      case .top: viewportPoint - layout.viewport.topInset
      case .bottom: layout.viewport.height - layout.viewport.bottomInset - viewportPoint
      }
      return .init(
        row: token.row, character: token.character, y: y,
        edge: edge, viewportPoint: viewportPoint, edgeDistance: edgeDistance,
        rowFrame: placement.frame, localY: anchor.localY, bodyFrame: cell.text.frame
      )
    }
    return nil
  }

  private var currentReadingEdge: TimelineAnchorEdge {
    if case let .reading(anchor) = session.timeline.intent { return anchor.edge }
    return .bottom
  }

  private func witnessEdge(for operation: LabOperation) -> TimelineAnchorEdge {
    switch operation {
    case .bottomInset, .heightAndInset: .bottom
    case .topInset:
      session.timeline.layout.viewport.bottomInset != session.timeline.targetViewport.bottomInset
        ? .bottom : .top
    default: currentReadingEdge
    }
  }

  private func inspectWitness(
    _ before: GlyphWitness?, preIntent: String, label: String
  ) {
    guard let before else {
      if hasPotentialVisibleGlyph() {
        probe.recordMissingGlyph(label: "\(label): visible text exists but no native glyph was captured")
      } else {
        probe.recordBlankTextWindow(label: label, layout: session.timeline.layout)
        probe.inspectReadingFallback(session.timeline.layout, intent: session.timeline.intent, label: label)
      }
      return
    }
    guard let record = scenario.records.first(where: { $0.id == before.row }) else {
      probe.recordRetiredWitness()
      probe.inspectReadingFallback(session.timeline.layout, intent: session.timeline.intent, label: label)
      return
    }
    guard before.character < record.content.text.utf16.count else {
      probe.recordChangedGlyphContent()
      return
    }
    let layout = session.timeline.layout
    guard let placement = layout.placement(for: before.row) else {
      probe.recordMissingGlyph(label: "\(label): retained row has no package placement")
      return
    }
    guard let cell = list.cell(for: before.row) as? MacLabTextCell,
          let y = cell.screenGlyphY(before.character),
          let localY = cell.localGlyphY(before.character) else {
      probe.recordMissingGlyph(label: "\(label): pinned retained glyph unavailable")
      return
    }
    guard localY >= -1, localY <= placement.frame.height + 1 else {
      probe.recordUnrepresentableWitness()
      probe.inspectReadingFallback(layout, intent: session.timeline.intent, label: label)
      return
    }
    guard let body = placement.row.elements["body"],
          localY >= body.minY - 1, localY <= body.maxY + 1 else {
      probe.recordUnrepresentableWitness()
      probe.inspectReadingFallback(layout, intent: session.timeline.intent, label: label)
      return
    }
    probe.inspectGlyph(
      screenDrift: y - before.y,
      afterDocumentY: placement.frame.minY + localY,
      beforeViewportPoint: before.viewportPoint,
      beforeEdgeDistance: before.edgeDistance,
      edge: before.edge, viewport: layout.viewport,
      actualOrigin: layout.originY,
      maximumOrigin: layout.maximumOrigin,
      rowID: before.row, rowFrame: placement.frame, localY: localY,
      intent: String(describing: session.timeline.intent),
      preIntent: preIntent, isUserScrolling: session.isUserScrolling,
      contextWidth: session.layoutContext.width,
      nativeViewportWidth: list.scrollView.contentView.bounds.width,
      beforeRowFrame: before.rowFrame, beforeLocalY: before.localY,
      beforeBodyFrame: before.bodyFrame, afterBodyFrame: cell.text.frame,
      textOffsetDelta: 0,
      macScreenYUp: true, label: label,
      scale: view.window?.backingScaleFactor ?? 1
    )
  }

  private func hasPotentialVisibleGlyph() -> Bool {
    let layout = session.timeline.layout
    for index in layout.visibleRows(in: layout.readingRect) {
      let placement = layout.rows[index]
      guard !placement.isExiting, placement.row.canAnchor else { continue }
      guard let cell = list.cell(for: placement.row.id) as? MacLabTextCell else { return true }
      let localVisible = layout.readingRect.intersection(placement.frame).offsetBy(
        dx: -placement.frame.minX, dy: -placement.frame.minY
      )
      let textVisible = localVisible.intersection(cell.text.frame)
      guard !textVisible.isNull, !textVisible.isEmpty else { continue }
      let count = cell.text.string.utf16.count
      guard count > 0,
            let firstY = cell.localGlyphY(0),
            let lastY = cell.localGlyphY(count - 1) else { return true }
      if textVisible.maxY >= firstY - 20, textVisible.minY <= lastY + 1 { return true }
    }
    return false
  }

  private func runEvent(
    _ operation: LabOperation, at time: Double, label: String, offsets: [Double]
  ) -> Bool {
    let baselineStarted = ProcessInfo.processInfo.systemUptime
    list.advance(to: time)
    probe.recordAdvanceDuration((ProcessInfo.processInfo.systemUptime - baselineStarted) * 1_000)
    let before = witness(edge: witnessEdge(for: operation))
    if let before { list.pinCell(for: before.row) }
    defer { if let before { list.unpinCell(for: before.row) } }
    let preIntent = String(describing: session.timeline.intent)
    scenario.perform(operation, visibleID: session.timeline.layout.anchor()?.id)
    if operation == .resizeWidth { resizeList(at: time) }
    let generation = session.generation
    if operation.changesViewport { updateViewport(at: time, animation: .animated) }
    if session.generation == generation, !applyCurrent(at: time) { return false }
    for (sample, offset) in offsets.enumerated() {
      let started = ProcessInfo.processInfo.systemUptime
      list.advance(to: time + offset)
      probe.recordAdvanceDuration((ProcessInfo.processInfo.systemUptime - started) * 1_000)
      let sampleLabel = "\(label) frame \(sample) \(operation)"
      inspectNative(label: sampleLabel)
      inspectWitness(before, preIntent: preIntent, label: sampleLabel)
    }
    return true
  }

  private func startReplay() {
    guard !replayRunning, session.snapshot != nil else { return }
    replayRunning = true
    list.configuration.usesAutomaticDisplayClock = false
    var time = ProcessInfo.processInfo.systemUptime + 1
    manualClock = time
    scenario = LabScenario(includeLongPassage: true)
    guard applyCurrent(at: time, animation: .none) else { replayRunning = false
      return
    }
    session.navigate(to: .reading(.init(id: 180, localY: 2_500, viewportY: 20)),
                     animation: .none, at: time)
    runNegativeControl()
    Task { @MainActor in
      let offsets: [Double] = [1 / 120, 1 / 60, 1 / 30, 1 / 20, 1 / 12, 1 / 8, 1 / 4, 0.4]
      var focusedEvents = 0
      for operation in [LabOperation.toggleHeight, .topInset, .resizeWidth, .prepend, .heightAndInset] {
        time += 0.5
        manualClock = time
        guard runEvent(operation, at: time, label: "long passage \(focusedEvents)", offsets: offsets) else { break }
        focusedEvents += 1
      }
      scenario = LabScenario()
      widthReduction = 0
      time += 0.5
      manualClock = time
      transactionTime = time
      view.needsLayout = true
      view.layoutSubtreeIfNeeded()
      transactionTime = nil
      let resetGeneration = session.generation
      updateViewport(at: time, animation: .none)
      if session.generation == resetGeneration { _ = applyCurrent(at: time, animation: .none) }
      session.navigate(to: .reading(.init(id: 180, viewportY: 20)), animation: .none, at: time)
      var completedEvents = 0
      for event in 0 ..< requestedReplayEvents {
        time += 0.5
        manualClock = time
        let operation = replay.next()
        guard runEvent(operation, at: time, label: "event \(event)", offsets: offsets) else { break }
        completedEvents += 1
        if event % 16 == 0 {
          status.stringValue = "Replay \(event)/\(requestedReplayEvents) · \(probe.sampledFrames) samples · \(probe.failureCount) failures"
          await Task.yield()
        }
      }
      status.stringValue = "Replay complete · \(probe.report)"
      NSLog("ChatListMacLab: %@", probe.report)
      do {
        let path = try LabRunReport(
          platform: "macOS", requestedEvents: requestedReplayEvents,
          completedEvents: completedEvents,
          focusedEventsCompleted: focusedEvents, probe: probe
        )
          .write(to: URL(fileURLWithPath: "/tmp", isDirectory: true))
        NSLog("ChatListMacLab report: %@", path.path)
      } catch {
        status.stringValue = "Report write failed: \(error)"
      }
      replayRunning = false
      if CommandLine.arguments.contains("--replay-exit") { NSApp.terminate(nil) }
    }
  }
}

private extension LabOperation {
  var changesViewport: Bool {
    switch self {
    case .topInset, .bottomInset, .heightAndInset, .resizeWidth: true
    default: false
    }
  }
}
