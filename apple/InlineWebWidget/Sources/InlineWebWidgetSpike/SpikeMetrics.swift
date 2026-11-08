import AppKit
import Darwin
import InlineWebWidget

@MainActor
final class SpikeMetrics {
  struct Render: Codable { var key: String; var ms: Double; var cold: Bool }
  struct Sample: Codable {
    var label: String
    var appFootprintMB: Double
    var webContentProcesses: Int
    var webContentFootprintMB: Double
    var liveWidgets: Int
    var pooledWebViews: Int
    var webViewsCreated: Int
  }

  var renders: [Render] = []
  var samples: [Sample] = []
  var mountsWhileScrolling = 0
  var mounts = 0
  var unmounts = 0
  var unmountsWithSnapshot = 0
  var heightReports = 0
  var heightChanges = 0
  var anchorCorrections = 0
  var rowsConfigured = 0
  var rowsWithSnapshot = 0
  var rowsWithMeasuredHeight = 0
  var scriptErrors: [String] = []
  var rejections: [String] = []
  var requests: [String] = []
  var checks: [String: String] = [:]

  func rowConfigured(hadSnapshot: Bool, hadMeasuredHeight: Bool) {
    rowsConfigured += 1
    if hadSnapshot { rowsWithSnapshot += 1 }
    if hadMeasuredHeight { rowsWithMeasuredHeight += 1 }
  }

  func resetRowCounters() {
    rowsConfigured = 0
    rowsWithSnapshot = 0
    rowsWithMeasuredHeight = 0
  }

  func record(_ event: WidgetEvent, isScrolling: Bool) {
    switch event {
    case .mountStarted:
      mounts += 1
      if isScrolling { mountsWhileScrolling += 1 }
    case let .rendered(key, ms, cold):
      renders.append(Render(key: key, ms: ms, cold: cold))
    case let .unmounted(_, snapshotted):
      unmounts += 1
      if snapshotted { unmountsWithSnapshot += 1 }
    case .heightReported:
      heightReports += 1
    case let .scriptError(key, message):
      scriptErrors.append("\(key): \(message)")
    case let .rejected(key, method, reason):
      rejections.append("\(key) \(method): \(reason)")
    case let .processTerminated(key):
      scriptErrors.append("\(key): web content process terminated")
    }
  }

  func sample(_ label: String, coordinator: WidgetCoordinator, webViews: [WidgetWebView]) {
    let pids = Set(webViews.compactMap { $0.webContentProcessIdentifier }.filter { $0 > 0 })
    let webFootprint = pids.compactMap(Self.footprint).reduce(0, +)
    samples.append(Sample(
      label: label,
      appFootprintMB: Self.mb(Self.footprint(getpid()) ?? 0),
      webContentProcesses: pids.count,
      webContentFootprintMB: Self.mb(webFootprint),
      liveWidgets: coordinator.liveKeys.count,
      pooledWebViews: coordinator.idleCount,
      webViewsCreated: coordinator.webViewsCreated
    ))
  }

  static func mb(_ bytes: UInt64) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }

  static func footprint(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return result == 0 ? info.ri_phys_footprint : nil
  }

  func report(mode: String) -> [String: Any] {
    func stats(_ values: [Double]) -> [String: Double] {
      guard !values.isEmpty else { return [:] }
      let sorted = values.sorted()
      let r = { (v: Double) in (v * 10).rounded() / 10 }
      return ["count": Double(sorted.count), "median": r(sorted[sorted.count / 2]), "p90": r(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]), "max": r(sorted.last!)]
    }
    let encoder = JSONEncoder()
    let sampleObjects = samples.compactMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) }
    return [
      "originMode": mode,
      "renderMsCold": stats(renders.filter(\.cold).map(\.ms)),
      "renderMsPooled": stats(renders.filter { !$0.cold }.map(\.ms)),
      "renderByKey": renders.map { "\($0.key) \($0.cold ? "cold" : "pooled") \(Int($0.ms))ms" },
      "mounts": mounts,
      "mountsWhileScrolling": mountsWhileScrolling,
      "unmounts": unmounts,
      "unmountsWithSnapshot": unmountsWithSnapshot,
      "heightReports": heightReports,
      "heightChanges": heightChanges,
      "anchorCorrections": anchorCorrections,
      "rowsConfiguredOnReturn": rowsConfigured,
      "rowsWithSnapshotOnReturn": rowsWithSnapshot,
      "rowsWithMeasuredHeightOnReturn": rowsWithMeasuredHeight,
      "scriptErrors": scriptErrors,
      "rejections": rejections,
      "requests": requests,
      "checks": checks,
      "samples": sampleObjects,
    ]
  }
}
