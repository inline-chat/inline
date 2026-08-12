import CoreFoundation
import Foundation
import OSLog
import Sentry
import os.signpost

public enum PerformanceTrace {
  struct BreadcrumbProjection {
    let message: String
    let category: String
    let data: [String: Any]
  }

  public enum Category: String, Sendable {
    case sync = "SyncPerformance"
    case updates = "UpdateApply"
    case messages = "MessageList"
    case home = "HomeList"
    case realtime = "RealtimePerformance"
  }

  public enum BreadcrumbLevel: Sendable {
    case info
    case warning
    case error

    fileprivate var sentryLevel: SentryLevel {
      switch self {
        case .info:
          .info
        case .warning:
          .warning
        case .error:
          .error
      }
    }
  }

  public struct Span: @unchecked Sendable {
    fileprivate let log: OSLog
    fileprivate let id: OSSignpostID
    fileprivate let name: StaticString

    public func end(_ message: @autoclosure () -> String = "") {
      os_signpost(
        .end,
        log: log,
        name: name,
        signpostID: id,
        "%{private}s",
        message()
      )
    }
  }

  private static let subsystem = Bundle.main.bundleIdentifier ?? "chat.inline"
  private static let syncLog = OSLog(subsystem: subsystem, category: Category.sync.rawValue)
  private static let updatesLog = OSLog(subsystem: subsystem, category: Category.updates.rawValue)
  private static let messagesLog = OSLog(subsystem: subsystem, category: Category.messages.rawValue)
  private static let homeLog = OSLog(subsystem: subsystem, category: Category.home.rawValue)
  private static let realtimeLog = OSLog(subsystem: subsystem, category: Category.realtime.rawValue)
  private static let breadcrumbCategories: Set<String> = [
    "Grid.Access",
    "Grid.Connection",
    "Grid.Home",
    "Grid.RTC",
    "Grid.Snapshot",
    "Grid.State",
    "Navigation",
    "PointsOfInterest",
    "ios.home.commit",
    "ios.home.diff",
    "ios.home.navigation.back",
    "ios.home.navigation.chat",
    "ios.home.navigation.tab",
    "ios.home.prepare",
    "ios.home.query",
    "messages.db",
    "messages.ios",
    "messages.layout",
    "messages.mac",
    "messages.publisher",
    "messages.reload",
    "realtime.protocol",
    "realtime.transport",
    "sync.catchup",
    "sync.lifecycle",
    "sync.realtime",
    "updates.apply",
  ]
  private static let breadcrumbNumericKeys: Set<String> = [
    "abandoned_operations",
    "applied",
    "attempt",
    "attempts",
    "attachment_count",
    "buffered",
    "changed",
    "click_to_connected_ms",
    "connect_ms",
    "deleted",
    "duration_ms",
    "elapsed_ms",
    "failed",
    "fitted_height",
    "fitting_width",
    "inserted",
    "large_url_preview_count",
    "last_sync_age_sec",
    "max_attempts",
    "measured_height",
    "previous_height",
    "reconnect_count",
    "response_bytes",
    "retry_count",
    "rtc_connect_ms",
    "stabilized_height",
    "threshold_ms",
    "updates",
    "visible_count",
  ]
  private static let breadcrumbBooleanKeys: Set<String> = [
    "cold_start",
    "interrupted",
    "requested",
    "success",
  ]
  private static let maxBreadcrumbMetricMagnitude = 1_000_000_000_000.0
  private static let maxBreadcrumbMetricCount = 16

  @discardableResult
  public static func begin(
    _ name: StaticString,
    category: Category,
    _ message: @autoclosure () -> String = ""
  ) -> Span {
    let log = osLog(for: category)
    let id = OSSignpostID(log: log)
    os_signpost(
      .begin,
      log: log,
      name: name,
      signpostID: id,
      "%{private}s",
      message()
    )
    return Span(log: log, id: id, name: name)
  }

  public static func event(
    _ name: StaticString,
    category: Category,
    _ message: @autoclosure () -> String = ""
  ) {
    os_signpost(
      .event,
      log: osLog(for: category),
      name: name,
      "%{private}s",
      message()
    )
  }

  public static func breadcrumb(
    _ message: String,
    category: String,
    level: BreadcrumbLevel = .info,
    data: [String: Any] = [:]
  ) {
    guard SentrySDK.isEnabled else { return }

    let projection = privacySafeBreadcrumbProjection(message: message, category: category, data: data)
    let crumb = Breadcrumb(level: level.sentryLevel, category: projection.category)
    crumb.message = projection.message
    crumb.data = projection.data
    SentrySDK.addBreadcrumb(crumb)
  }

  static func privacySafeBreadcrumbProjection(
    message _: String,
    category: String,
    data: [String: Any]
  ) -> BreadcrumbProjection {
    var projectedData: [String: Any] = [:]

    for key in data.keys.sorted() {
      guard projectedData.count < maxBreadcrumbMetricCount, let value = data[key] else { break }

      if breadcrumbBooleanKeys.contains(key),
         let number = value as? NSNumber,
         CFGetTypeID(number) == CFBooleanGetTypeID() {
        projectedData[key] = number.boolValue
        continue
      }

      guard breadcrumbNumericKeys.contains(key), let number = value as? NSNumber else { continue }
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
      let numericValue = number.doubleValue
      guard numericValue.isFinite else { continue }
      projectedData[key] = min(max(numericValue, -maxBreadcrumbMetricMagnitude), maxBreadcrumbMetricMagnitude)
    }

    return BreadcrumbProjection(
      message: "performance_event",
      category: breadcrumbCategories.contains(category) ? category : "performance",
      data: projectedData
    )
  }

  public static func slowBreadcrumb(
    _ message: String,
    category: String,
    durationMs: Int,
    thresholdMs: Int,
    data: @autoclosure () -> [String: Any] = [:]
  ) {
    guard durationMs >= thresholdMs else { return }

    var data = data()
    data["duration_ms"] = durationMs
    data["threshold_ms"] = thresholdMs
    breadcrumb(message, category: category, level: .warning, data: data)
  }

  public static func elapsedMilliseconds(since date: Date) -> Int {
    Int((Date().timeIntervalSince(date) * 1_000).rounded())
  }

  private static func osLog(for category: Category) -> OSLog {
    switch category {
      case .sync:
        syncLog
      case .updates:
        updatesLog
      case .messages:
        messagesLog
      case .home:
        homeLog
      case .realtime:
        realtimeLog
    }
  }
}
