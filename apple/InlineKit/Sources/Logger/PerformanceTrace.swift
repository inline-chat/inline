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
    case launch = "AppLaunch"
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
  private static let launchLog = OSLog(subsystem: subsystem, category: Category.launch.rawValue)
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
    "auth.logout",
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
    "realtime.connection",
    "realtime.protocol",
    "realtime.transaction",
    "realtime.transport",
    "sync.catchup",
    "sync.bootstrap.chats",
    "sync.bootstrap.me",
    "sync.bootstrap.settings",
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
    "buffered_bytes",
    "capacity_rejections",
    "changed",
    "click_to_connected_ms",
    "connect_ms",
    "deleted",
    "direct_capacity_rejections",
    "down_ms",
    "duration_ms",
    "elapsed_ms",
    "ephemeral_expired",
    "ephemeral_superseded",
    "failed",
    "fitted_height",
    "fitting_width",
    "inserted",
    "inbound_update_overflow",
    "large_url_preview_count",
    "last_sync_age_sec",
    "max_attempts",
    "maximum_message_bytes",
    "measured_height",
    "oldest_queue_age_ms",
    "outstanding",
    "outbound_write_overflow",
    "pending_probe",
    "pending_rpc",
    "previous_height",
    "queued",
    "queued_bytes",
    "queued_write",
    "reconnect_count",
    "response_bytes",
    "retry_count",
    "session",
    "reconnect_ms",
    "rtc_connect_ms",
    "stabilized_height",
    "threshold_ms",
    "target_seq",
    "transport_generation",
    "updates",
    "visible_count",
    "window_saturations",
  ]
  private static let breadcrumbBooleanKeys: Set<String> = [
    "cold_start",
    "during_handshake",
    "inbound_message_too_large",
    "interrupted",
    "requested",
    "signal_joined",
    "success",
  ]
  private static let breadcrumbOpaqueIdentifierKeys: Set<String> = ["transition_id"]
  /// Low-cardinality program vocabulary. Values outside each set are dropped, so free text,
  /// identifiers and server-supplied strings can never pass through these keys.
  private static let breadcrumbEnumValues: [String: Set<String>] = [
    "state": [
      "stopped", "waiting_for_constraints", "connecting_transport", "authenticating", "open", "backoff",
      "background_suspended",
    ],
    "reason": connectionReasonValues,
    "drop_reason": connectionReasonValues,
    "protocol": ["v2", "v3"],
    "cohort": ["legacy", "upgraded", "native"],
    "outcome": ["prepared", "deferred", "cancelled"],
    "reason_class": [
      "verified", "cancelled", "disabled", "ineligible", "source_rejected", "not_bound", "declined", "network",
      "unexpected", "timeout", "server_rejected", "protocol", "storage",
    ],
    "fallback_reason": ["deadline", "startup_failure", "operator_preference"],
    "provider_state": ["disconnected", "connecting", "reconnecting", "connected", "disconnecting"],
  ]
  private static let connectionReasonValues: Set<String> = [
    "none", "user_stop", "auth_lost", "auth_failed", "auth_timeout", "transport_error", "transport_disconnected",
    "ping_timeout", "network_unavailable", "network_route_changed", "application_resumed", "wake_probe_failed",
    "background_suspended", "constraint_unavailable",
  ]
  private static let healthEventNames: Set<String> = [
    "realtime.connection.opened", "realtime.connection.recovered", "realtime.v3_fallback", "realtime.v3_upgrade",
  ]
  private static let diagnosticTagValues: [String: Set<String>] = ["realtime.protocol": ["v2", "v3"]]
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

  /// Aggregatable health events, sent as Sentry structured logs. Event names are fixed and
  /// attributes use the breadcrumb projection: allow-listed numbers, booleans and enum values only.
  public static func healthEvent(_ name: String, data: [String: Any] = [:]) {
    guard SentrySDK.isEnabled, healthEventNames.contains(name) else { return }
    let projection = privacySafeBreadcrumbProjection(message: name, category: name, data: data)
    SentrySDK.logger.info(name, attributes: projection.data)
  }

  /// Low-cardinality Sentry scope tags, so later errors can be filtered by connection context.
  public static func setDiagnosticTag(_ key: String, value: String) {
    guard SentrySDK.isEnabled, diagnosticTagValues[key]?.contains(value) == true else { return }
    SentrySDK.configureScope { scope in scope.setTag(value: value, key: key) }
  }

  static func isAllowedEnumValue(_ value: String, for key: String) -> Bool {
    breadcrumbEnumValues[key]?.contains(value) == true
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

      if let allowed = breadcrumbEnumValues[key] {
        if let value = value as? String, allowed.contains(value) { projectedData[key] = value }
        continue
      }

      if breadcrumbOpaqueIdentifierKeys.contains(key),
         let identifier = value as? String,
         UUID(uuidString: identifier) != nil
      {
        projectedData[key] = identifier
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
      case .launch:
        launchLog
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
