import Foundation
import OSLog
import Sentry

public enum LogLevel: String, Sendable {
  case error = "❌ ERROR"
  case warning = "⚠️ WARNING"
  case info = "ℹ️ INFO"
  case debug = "🐛 DEBUG"
  case trace = "🚧 TRACE"

  var osLogType: OSLogType {
    switch self {
      case .error: .error
      case .warning: .fault
      case .info: .info
      case .debug: .debug
      case .trace: .debug
    }
  }

  var sentryLevel: SentryLevel {
    switch self {
      case .error: .error
      case .warning: .warning
      case .info: .info
      case .debug: .debug
      case .trace: .debug
    }
  }
}

public protocol Logging {
  func error(_ message: String, error: Error?, file: String, function: String, line: Int)
  func warning(_ message: String, file: String, function: String, line: Int)
  func info(_ message: String, file: String, function: String, line: Int)
  func debug(_ message: String, file: String, function: String, line: Int)
  func trace(_ message: String, file: String, function: String, line: Int)
}

public final class Log: @unchecked Sendable {
  public static let shared = Log(scope: "shared")

  private let scope: String
  private let level: LogLevel
  #if DEBUG
  private let logger: String // Using String as identifier for debug builds
  #else
  private let logger: Logger
  #endif

  private init(scope: String, level: LogLevel = .debug) {
    self.scope = scope
    self.level = level
    #if DEBUG
    logger = scope
    #else
    logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "chat.inline", category: scope)
    #endif
  }

  public static func scoped(_ scope: String, enableTracing: Bool = false) -> Log {
    Log(scope: scope, level: enableTracing ? .trace : .debug)
  }

  public static func scoped(_ scope: String) -> Log {
    Log(scope: scope)
  }

  private func log(
    _ message: String,
    level: LogLevel,
    error: Error? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let fileName = (file as NSString).lastPathComponent
    let errorDescription = error?.localizedDescription ?? ""

    let logMessage: String
    let scope_ = scope
    if scope == "shared" || level == .error {
      logMessage = "[\(fileName):\(line) \(function)] \(message) \(errorDescription)"
    } else {
      logMessage = "\(message) \(errorDescription)"
    }

    #if DEBUG
    print("\(level.rawValue) |  \(scope_) | \(logMessage)")
    #else
    logger.log(
      level: level.osLogType,
      "\(level.rawValue, privacy: .public) |  \(scope_, privacy: .public) | \(logMessage, privacy: .public)"
    )
    #endif

    let level_ = level

    // Handle Sentry reporting with proper isolation
    if level == .error || level == .warning {
      Task {
        if level == .error, let error {
          await SentryReporter.shared.reportError(
            error,
            message: message,
            scope: scope_,
            level: level_
          )
        } else {
          await SentryReporter.shared.reportMessage(
            message,
            scope: scope_,
            level: level_,
            error: error
          )
        }
      }
    }
  }
}

extension Log: Logging {
  public func error(
    _ message: String,
    error: Error? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .error, error: error, file: file, function: function, line: line)
  }

  public func warning(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .warning, file: file, function: function, line: line)
  }

  public func info(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .info, file: file, function: function, line: line)
  }

  public func debug(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG
    log(message, level: .debug, file: file, function: function, line: line)
    #endif
  }

  public func trace(
    _ message: String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    guard level == .trace else { return }
    #if DEBUG
    log(message, level: .trace, file: file, function: function, line: line)
    #endif
  }
}

// Create a dedicated actor for handling Sentry operations
private actor SentryReporter {
  static let shared = SentryReporter()

  func reportError(_ error: Error, message: String, scope: String, level: LogLevel) {
    SentrySDK.capture(error: error) { sentryScope in
      sentryScope.setLevel(level.sentryLevel)
      sentryScope.setTag(value: scope, key: "scope")
      sentryScope.setExtra(value: message, key: "message")
    }
  }

  func reportMessage(_ message: String, scope: String, level: LogLevel, error: Error?) {
    SentrySDK.capture(message: message) { sentryScope in
      sentryScope.setLevel(level.sentryLevel)
      sentryScope.setTag(value: scope, key: "scope")
      if let error {
        sentryScope.setExtra(value: error.localizedDescription, key: "error")
      }
    }
  }
}
