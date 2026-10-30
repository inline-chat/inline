import Foundation
import ChatListCore

/// Checks package output without reimplementing its anchor or layout policy.
struct LabGeometryProbe {
  private(set) var sampledFrames = 0
  private(set) var sampledGlyphs = 0
  private(set) var sampledNativeCells = 0
  private(set) var sampledDecorations = 0
  private(set) var sampledOcclusions = 0
  private(set) var sampledIndicatorInsets = 0
  private(set) var legalClampSamples = 0
  private(set) var retiredWitnesses = 0
  private(set) var outOfViewWitnesses = 0
  private(set) var changedGlyphContent = 0
  private(set) var unrepresentableWitnesses = 0
  private(set) var blankTextWindows = 0
  private(set) var blankTextExamples: [String] = []
  private(set) var negativeControlPassed = false
  private(set) var failureCount = 0
  private(set) var failures: [String] = []
  private var advanceDurationsMs: [Double] = []

  private mutating func record(_ failure: String) {
    failureCount += 1
    if failures.count < 256 { failures.append(failure) }
  }

  mutating func recordAdvanceDuration(_ milliseconds: Double) {
    if milliseconds.isFinite, milliseconds >= 0 { advanceDurationsMs.append(milliseconds) }
  }

  var advanceCPU: LabAdvanceCPU {
    let sorted = advanceDurationsMs.sorted()
    guard !sorted.isEmpty else { return .init(samples: 0, p50Ms: 0, p95Ms: 0, maxMs: 0) }
    return .init(
      samples: sorted.count,
      p50Ms: sorted[(sorted.count - 1) / 2],
      p95Ms: sorted[Int(Double(sorted.count - 1) * 0.95)],
      maxMs: sorted[sorted.count - 1]
    )
  }

  mutating func inspect(_ layout: TimelineLayout<Int64>, label: String) {
    sampledFrames += 1
    guard layout.contentHeight.isFinite, layout.originY.isFinite,
          layout.contentHeight >= layout.viewport.height else {
      record("\(label): invalid extent or origin")
      return
    }
    var previousMaxY: CGFloat = -.greatestFiniteMagnitude
    var ids = Set<Int64>()
    for placement in layout.rows {
      let frame = placement.frame
      if !ids.insert(placement.row.id).inserted {
        record("\(label): duplicate row \(placement.row.id)")
      }
      if !frame.minY.isFinite || !frame.maxY.isFinite || frame.height < 0 ||
        frame.minY + 0.02 < previousMaxY {
        record("\(label): invalid ordering at \(placement.row.id)")
      }
      previousMaxY = frame.maxY
    }
  }

  mutating func inspectGlyph(
    screenDrift: CGFloat, afterDocumentY: CGFloat,
    beforeViewportPoint: CGFloat, beforeEdgeDistance: CGFloat,
    edge: TimelineAnchorEdge, viewport: TimelineViewport,
    actualOrigin: CGFloat, maximumOrigin: CGFloat,
    rowID: Int64, rowFrame: CGRect, localY: CGFloat, intent: String,
    preIntent: String, isUserScrolling: Bool,
    contextWidth: CGFloat, nativeViewportWidth: CGFloat,
    beforeRowFrame: CGRect, beforeLocalY: CGFloat,
    beforeBodyFrame: CGRect, afterBodyFrame: CGRect, textOffsetDelta: CGFloat,
    macScreenYUp: Bool, label: String, scale: CGFloat
  ) {
    sampledGlyphs += 1
    let targetViewportPoint: CGFloat = switch edge {
    case .top: viewport.topInset + beforeEdgeDistance
    case .bottom: viewport.height - viewport.bottomInset - beforeEdgeDistance
    }
    let desiredOrigin = afterDocumentY - targetViewportPoint
    let legalOrigin = min(maximumOrigin, max(0, desiredOrigin))
    let legalRelativeDrift = afterDocumentY - legalOrigin - beforeViewportPoint
    let expectedScreenDrift = macScreenYUp ? -legalRelativeDrift : legalRelativeDrift
    let residual = screenDrift - expectedScreenDrift
    let clamped = abs(desiredOrigin - legalOrigin) > 0.5
    if clamped { legalClampSamples += 1 }
    let context = "origin \(actualOrigin)/max \(maximumOrigin), desired \(desiredOrigin), " +
      "legal \(legalOrigin), clamp \(clamped), row \(rowID) frame \(rowFrame), " +
      "local \(localY), prior frame \(beforeRowFrame), prior local \(beforeLocalY), " +
      "body \(beforeBodyFrame)->\(afterBodyFrame), text offset delta \(textOffsetDelta), " +
      "edge \(edge), distance \(beforeEdgeDistance), prior viewport point \(beforeViewportPoint), " +
      "viewport \(viewport), pre-intent \(preIntent), intent \(intent), " +
      "user scrolling \(isUserScrolling), context width \(contextWidth), " +
      "native viewport width \(nativeViewportWidth)"
    guard residual.isFinite, desiredOrigin.isFinite, legalOrigin.isFinite else {
      record("\(label): nonfinite glyph coordinate")
      return
    }
    if abs(actualOrigin - legalOrigin) * max(1, scale) > 2.1 {
      record("\(label): package origin missed independent legal clamp; \(context)")
    }
    if abs(residual) * max(1, scale) > 2.1 {
      record("\(label): glyph residual \(residual) points, observed \(screenDrift), " +
             "expected \(expectedScreenDrift); \(context)")
    }
  }

  mutating func recordRetiredWitness() { retiredWitnesses += 1 }
  mutating func recordOutOfViewWitness() { outOfViewWitnesses += 1 }
  mutating func recordChangedGlyphContent() { changedGlyphContent += 1 }
  mutating func recordUnrepresentableWitness() { unrepresentableWitnesses += 1 }
  mutating func recordBlankTextWindow(label: String, layout: TimelineLayout<Int64>) {
    blankTextWindows += 1
    if blankTextExamples.count < 16 {
      let anchor = layout.anchor().map { String(describing: $0.id) } ?? "none"
      blankTextExamples.append(
        "\(label): no native glyph in reading rect \(layout.readingRect), fallback row \(anchor)"
      )
    }
  }

  mutating func inspectReadingFallback(_ layout: TimelineLayout<Int64>,
                                       intent: TimelineIntent<Int64>, label: String) {
    guard case let .reading(anchor) = intent,
          let placement = layout.placement(for: anchor.id), !placement.isExiting,
          anchor.localY.isFinite else {
      record("\(label): no valid reading row/neighbor fallback after witness loss")
      return
    }
  }

  mutating func recordMissingGlyph(label: String) {
    record("\(label): native glyph witness unavailable")
  }

  mutating func inspectNativeCell(
    id: Int64, slot: CGRect?, cell: CGRect, body: CGRect,
    placement: TimelineLayout<Int64>.Placement, expectedCellHeight: CGFloat,
    scale: CGFloat, label: String
  ) {
    sampledNativeCells += 1
    let tolerance = 0.6 / max(1, scale)
    guard let slot else {
      record("\(label): row \(id) has no native slot")
      return
    }
    if !slot.near(placement.frame, tolerance: tolerance) {
      record("\(label): row \(id) native slot differs from package placement")
    }
    let expectedCell = CGRect(x: 0, y: 0, width: placement.frame.width, height: expectedCellHeight)
    if !cell.near(expectedCell, tolerance: tolerance) {
      record("\(label): row \(id) native cell differs from prepared frame")
    }
    if !placement.isExiting, let expectedBody = placement.row.elements["body"],
       !body.near(expectedBody, tolerance: tolerance) {
      record("\(label): row \(id) native text \(body) differs from child placement \(expectedBody), " +
             "slot \(slot), cell \(cell), row \(placement.frame)")
    }
  }

  mutating func inspectNativeOrigin(
    _ actual: CGFloat, expected: CGFloat, scale: CGFloat, label: String
  ) {
    if abs(actual - expected) * max(1, scale) > 0.6 {
      record("\(label): native scroll origin \(actual) differs from package origin \(expected)")
    }
  }

  mutating func inspectDecoration(
    _ actual: CGRect?, placement: ChatListDecorationPlacement,
    scale: CGFloat, label: String
  ) {
    sampledDecorations += 1
    guard let actual, actual.near(placement.frame, tolerance: 0.6 / max(1, scale)) else {
      record("\(label): native decoration \(placement.id) differs from package placement")
      return
    }
  }

  mutating func inspectOcclusions(
    top: CGRect, bottom: CGRect, viewport: TimelineViewport,
    scale: CGFloat, label: String
  ) {
    sampledOcclusions += 2
    let expectedTop = CGRect(x: 0, y: 0, width: viewport.width, height: viewport.topInset)
    let expectedBottom = CGRect(
      x: 0, y: viewport.height - viewport.bottomInset,
      width: viewport.width, height: viewport.bottomInset
    )
    let tolerance = 0.6 / max(1, scale)
    if !top.near(expectedTop, tolerance: tolerance) {
      record("\(label): top occlusion differs from presented viewport")
    }
    if !bottom.near(expectedBottom, tolerance: tolerance) {
      record("\(label): bottom occlusion differs from presented viewport")
    }
  }

  mutating func inspectIndicatorInsets(
    top: CGFloat, bottom: CGFloat, contentTop: CGFloat, contentBottom: CGFloat,
    viewport: TimelineViewport, scale: CGFloat, label: String
  ) {
    sampledIndicatorInsets += 1
    let tolerance = 0.6 / max(1, scale)
    if abs(top - viewport.topInset) > tolerance || abs(bottom - viewport.bottomInset) > tolerance {
      record("\(label): native indicator insets \(top)/\(bottom) differ from presented " +
             "viewport \(viewport.topInset)/\(viewport.bottomInset)")
    }
    if abs(contentTop) > tolerance || abs(contentBottom) > tolerance {
      record("\(label): native content insets \(contentTop)/\(contentBottom) are not zero")
    }
  }

  mutating func inspectNegativeControl(
    originBefore: CGFloat, originAfter: CGFloat,
    glyphBefore: CGFloat, glyphAfter: CGFloat
  ) {
    negativeControlPassed = abs(originAfter - originBefore) < 0.01
      && abs(glyphAfter - glyphBefore) >= 4
    if !negativeControlPassed {
      record("negative control: native glyph shift was not detected with fixed origin")
    }
  }

  var report: String {
    "\(sampledFrames) geometry frames, \(sampledNativeCells) native cell frames, " +
      "\(sampledDecorations) sticky decorations, " +
      "\(sampledOcclusions) native occlusions, " +
      "\(sampledGlyphs) native glyph samples, \(legalClampSamples) legal clamps, " +
      "\(failureCount) failures; advance CPU p95 \(String(format: "%.2f", advanceCPU.p95Ms)) ms" +
      (failures.isEmpty ? "" : "\n" + failures.prefix(12).joined(separator: "\n"))
  }
}

struct LabAdvanceCPU: Codable {
  let samples: Int
  let p50Ms: Double
  let p95Ms: Double
  let maxMs: Double
}

private extension CGRect {
  func near(_ other: CGRect, tolerance: CGFloat) -> Bool {
    abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
      && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
  }
}

struct LabRunReport: Codable {
  let platform: String
  let seed: String
  let requestedEvents: Int
  let completedEvents: Int
  let focusedEventsCompleted: Int
  let maximumWindowCount: Int
  let virtualPresentationSamples: Int
  let nativeCellFrameSamples: Int
  let nativeDecorationSamples: Int
  let nativeOcclusionSamples: Int
  let nativeIndicatorInsetSamples: Int
  let nativeGlyphSamples: Int
  let legalClampSamples: Int
  let retiredWitnesses: Int
  let outOfViewWitnesses: Int
  let changedGlyphContent: Int
  let unrepresentableWitnesses: Int
  let blankTextWindows: Int
  let blankTextExamples: [String]
  let negativeControlPassed: Bool
  let deliveredDisplayFramesMeasured: Bool
  let debugVirtualPresentationCPU: LabAdvanceCPU
  let failureCount: Int
  let failures: [String]

  init(platform: String, requestedEvents: Int = 2_048,
       completedEvents: Int, focusedEventsCompleted: Int, probe: LabGeometryProbe) {
    self.platform = platform
    seed = "0x57414c4b54455354"
    self.requestedEvents = requestedEvents
    self.completedEvents = completedEvents
    self.focusedEventsCompleted = focusedEventsCompleted
    maximumWindowCount = LabScenario.maximumWindowCount
    virtualPresentationSamples = probe.sampledFrames
    nativeCellFrameSamples = probe.sampledNativeCells
    nativeDecorationSamples = probe.sampledDecorations
    nativeOcclusionSamples = probe.sampledOcclusions
    nativeIndicatorInsetSamples = probe.sampledIndicatorInsets
    nativeGlyphSamples = probe.sampledGlyphs
    legalClampSamples = probe.legalClampSamples
    retiredWitnesses = probe.retiredWitnesses
    outOfViewWitnesses = probe.outOfViewWitnesses
    changedGlyphContent = probe.changedGlyphContent
    unrepresentableWitnesses = probe.unrepresentableWitnesses
    blankTextWindows = probe.blankTextWindows
    blankTextExamples = probe.blankTextExamples
    negativeControlPassed = probe.negativeControlPassed
    deliveredDisplayFramesMeasured = false
    debugVirtualPresentationCPU = probe.advanceCPU
    failureCount = probe.failureCount
    failures = probe.failures
  }

  func write(to directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("ChatListLabResults-\(UUID().uuidString).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
    return url
  }
}
