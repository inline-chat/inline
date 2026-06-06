import Foundation
import OSLog
import Sentry
import os.signpost

public enum PerformanceTrace {
  public enum Category: String, Sendable {
    case sync = "SyncPerformance"
    case updates = "UpdateApply"
    case messages = "MessageList"
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
        "%{public}s",
        message()
      )
    }
  }

  private static let subsystem = Bundle.main.bundleIdentifier ?? "chat.inline"
  private static let syncLog = OSLog(subsystem: subsystem, category: Category.sync.rawValue)
  private static let updatesLog = OSLog(subsystem: subsystem, category: Category.updates.rawValue)
  private static let messagesLog = OSLog(subsystem: subsystem, category: Category.messages.rawValue)
  private static let realtimeLog = OSLog(subsystem: subsystem, category: Category.realtime.rawValue)

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
      "%{public}s",
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
      "%{public}s",
      message()
    )
  }

  public static func breadcrumb(
    _ message: String,
    category: String,
    level: BreadcrumbLevel = .info,
    data: [String: Any] = [:]
  ) {
    let crumb = Breadcrumb(level: level.sentryLevel, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
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
      case .realtime:
        realtimeLog
    }
  }
}
