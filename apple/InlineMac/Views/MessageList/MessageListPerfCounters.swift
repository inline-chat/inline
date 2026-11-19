#if DEBUG
import AppKit
import os.signpost

/// Debug-only tallies for the message list perf journeys: cells built versus reconfigured,
/// height measures per row, and how many views and layers a newly built row holds.
///
/// Release builds keep only the always-on `PerformanceTrace` intervals (`CellBuild`,
/// `CellReconfigure`, `HeightMeasure`, ...). `flush(_:)` emits these tallies as one public
/// `MessageListCounters` signpost event and starts over, so a journey sums its events.
@MainActor
enum MessageListPerfCounters {
  enum CellPath {
    case unchanged
    case resized
    case reconfigured
    case built
  }

  private static let log = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")

  private static var unchanged = 0
  private static var resized = 0
  private static var reconfigured = 0
  private static var built = 0
  private static var builtViews = 0
  private static var builtLayers = 0
  private static var maxBuiltViews = 0
  private static var maxBuiltLayers = 0
  private static var measures = 0
  private static var measuresByMessage: [Int64: Int] = [:]

  static func noteCell(_ path: CellPath) {
    switch path {
      case .unchanged: unchanged += 1
      case .resized: resized += 1
      case .reconfigured: reconfigured += 1
      case .built: built += 1
    }
  }

  /// Counts the hierarchy a freshly built message view starts with, hidden parts included.
  static func noteBuiltRow(_ view: NSView) {
    let views = viewCount(view)
    let layers = view.layer.map(layerCount) ?? 0
    builtViews += views
    builtLayers += layers
    maxBuiltViews = max(maxBuiltViews, views)
    maxBuiltLayers = max(maxBuiltLayers, layers)
  }

  static func noteMeasure(messageId: Int64) {
    measures += 1
    measuresByMessage[messageId, default: 0] += 1
  }

  static func flush(_ reason: StaticString) {
    let total = unchanged + resized + reconfigured + built
    guard total > 0 || measures > 0 else { return }

    let measuredMessages = measuresByMessage.count
    let maxMeasures = measuresByMessage.values.max() ?? 0
    os_signpost(
      .event,
      log: log,
      name: "MessageListCounters",
      "reason=%{public}s built=%ld reconfigured=%ld resized=%ld unchanged=%ld measures=%ld measured_messages=%ld max_measures_per_message=%ld built_views=%ld built_layers=%ld max_views=%ld max_layers=%ld",
      reason.description,
      built,
      reconfigured,
      resized,
      unchanged,
      measures,
      measuredMessages,
      maxMeasures,
      builtViews,
      builtLayers,
      maxBuiltViews,
      maxBuiltLayers
    )

    unchanged = 0
    resized = 0
    reconfigured = 0
    built = 0
    builtViews = 0
    builtLayers = 0
    maxBuiltViews = 0
    maxBuiltLayers = 0
    measures = 0
    measuresByMessage.removeAll(keepingCapacity: true)
  }

  private static func viewCount(_ view: NSView) -> Int {
    view.subviews.reduce(1) { $0 + viewCount($1) }
  }

  private static func layerCount(_ layer: CALayer) -> Int {
    (layer.sublayers ?? []).reduce(1) { $0 + layerCount($1) }
  }
}
#endif
