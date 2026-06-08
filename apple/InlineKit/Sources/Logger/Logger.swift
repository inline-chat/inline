import Foundation
import OSLog
import Sentry
import Darwin

public enum LogLevel: String, Codable, Sendable {
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

  var priority: Int {
    switch self {
      case .trace: 0
      case .debug: 1
      case .info: 2
      case .warning: 3
      case .error: 4
    }
  }
}

public struct LogEntry: Codable, Identifiable, Sendable, Equatable {
  public let id: UUID
  public let timestamp: Date
  public let level: LogLevel
  public let scope: String
  public let message: String
  public let error: String?
  public let file: String
  public let fileName: String
  public let function: String
  public let line: Int
  public let processIdentifier: Int32
  public let threadIdentifier: UInt64

  public init(
    id: UUID = UUID(),
    timestamp: Date = Date(),
    level: LogLevel,
    scope: String,
    message: String,
    error: String?,
    file: String,
    fileName: String,
    function: String,
    line: Int,
    processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
    threadIdentifier: UInt64? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.level = level
    self.scope = scope
    self.message = message
    self.error = error
    self.file = file
    self.fileName = fileName
    self.function = function
    self.line = line
    self.processIdentifier = processIdentifier
    self.threadIdentifier = threadIdentifier ?? Self.currentThreadIdentifier()
  }

  public var consoleMessage: String {
    "\(level.rawValue) |  \(scope) | \(message)"
  }

  private static func currentThreadIdentifier() -> UInt64 {
    var id: UInt64 = 0
    pthread_threadid_np(nil, &id)
    return id
  }
}

public struct LogEvent: @unchecked Sendable {
  public let entry: LogEntry
  public let error: Error?

  public init(entry: LogEntry, error: Error?) {
    self.entry = entry
    self.error = error
  }
}

public protocol LogSink: AnyObject, Sendable {
  func write(_ event: LogEvent)
}

public enum DefaultLogSinkID {
  public static let console = "logger.console"
  public static let sentry = "logger.sentry"
}

public protocol Logging {
  func error(_ message: String, error: Error?, file: String, function: String, line: Int)
  func warning(_ message: String, file: String, function: String, line: Int)
  func info(_ message: String, file: String, function: String, line: Int)
  func debug(_ message: @autoclosure () -> String, file: String, function: String, line: Int)
  func trace(_ message: @autoclosure () -> String, file: String, function: String, line: Int)
}

public final class ConsoleLogSink: LogSink, @unchecked Sendable {
  private let subsystem: String
  private let lock = NSLock()
  private var loggers: [String: Logger] = [:]

  public init(subsystem: String = Bundle.main.bundleIdentifier ?? "chat.inline") {
    self.subsystem = subsystem
  }

  public func write(_ event: LogEvent) {
    let entry = event.entry
    logger(for: entry.scope).log(
      level: entry.level.osLogType,
      "\(entry.consoleMessage, privacy: .public)"
    )
  }

  private func logger(for scope: String) -> Logger {
    lock.lock()
    defer { lock.unlock() }

    if let logger = loggers[scope] {
      return logger
    }

    let logger = Logger(subsystem: subsystem, category: scope)
    loggers[scope] = logger
    return logger
  }
}

public final class SentryLogSink: LogSink, @unchecked Sendable {
  public init() {}

  public func write(_ event: LogEvent) {
    let entry = event.entry

    if entry.level == .info {
      SentrySDK.logger.info(entry.message)
    }

    guard entry.level == .error else { return }

    Task {
      if let error = event.error {
        await SentryReporter.shared.reportError(
          error,
          entry: entry
        )
      } else {
        await SentryReporter.shared.reportMessage(
          entry
        )
      }
    }
  }
}

private final class LogSinkRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var sinks: [String: any LogSink] = [
    DefaultLogSinkID.console: ConsoleLogSink(),
    DefaultLogSinkID.sentry: SentryLogSink(),
  ]

  func set(_ sink: (any LogSink)?, id: String) {
    lock.lock()
    defer { lock.unlock() }

    sinks[id] = sink
  }

  func snapshot() -> [any LogSink] {
    lock.lock()
    defer { lock.unlock() }

    return Array(sinks.values)
  }
}

public final class Log: @unchecked Sendable {
  public static let shared = Log(scope: "shared")
  private static let registry = LogSinkRegistry()

  private let scope: String
  private let level: LogLevel

  private init(scope: String, level: LogLevel = .debug) {
    self.scope = scope
    self.level = level
  }

  public static func scoped(_ scope: String, enableTracing: Bool = false) -> Log {
    Log(scope: scope, level: enableTracing ? .trace : .debug)
  }

  public static func scoped(_ scope: String, level: LogLevel = .debug) -> Log {
    Log(scope: scope, level: level)
  }

  public static func scoped(_ scope: String) -> Log {
    Log(scope: scope)
  }

  public static func addSink(_ sink: any LogSink, id: String) {
    registry.set(sink, id: id)
  }

  public static func removeSink(id: String) {
    registry.set(nil, id: id)
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

    // Respect the logger's configured minimum level
    guard level.priority >= self.level.priority else { return }

    let logMessage: String
    if scope == "shared" || level == .error {
      logMessage = "[\(fileName):\(line) \(function)] \(message) \(errorDescription)"
    } else {
      logMessage = "\(message) \(errorDescription)"
    }

    let entry = LogEntry(
      level: level,
      scope: scope,
      message: logMessage,
      error: errorDescription.isEmpty ? nil : errorDescription,
      file: file,
      fileName: fileName,
      function: function,
      line: line
    )

    let event = LogEvent(entry: entry, error: error)
    for sink in Self.registry.snapshot() {
      sink.write(event)
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
    _ message: @autoclosure () -> String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    #if DEBUG || DEBUG_BUILD
    log(message(), level: .debug, file: file, function: function, line: line)
    #endif
  }

  public func trace(
    _ message: @autoclosure () -> String,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    guard level == .trace else { return }
    #if DEBUG || DEBUG_BUILD
    log(message(), level: .trace, file: file, function: function, line: line)
    #endif
  }
}

// Create a dedicated actor for handling Sentry operations
private actor SentryReporter {
  static let shared = SentryReporter()

  private func shouldReport(_ error: Error) -> Bool {
    if error is CancellationError {
      return false
    }

    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return true }

    switch nsError.code {
      case NSURLErrorCancelled,
        NSURLErrorTimedOut,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorNetworkConnectionLost:
        return false
      default:
        return true
    }
  }

  func reportError(
    _ error: Error,
    entry: LogEntry
  ) async {
    guard shouldReport(error) else { return }

    await MainActor.run {
      _ = SentrySDK.capture(error: error) { sentryScope in
        sentryScope.setTag(value: entry.scope, key: "scope")
        sentryScope.setExtra(value: entry.message, key: "message")
        sentryScope.setExtra(value: entry.file, key: "file")
        sentryScope.setExtra(value: entry.function, key: "function")
        sentryScope.setExtra(value: entry.line, key: "line")
      }
    }
  }

  func reportMessage(
    _ entry: LogEntry
  ) async {
    await MainActor.run {
      _ = SentrySDK.capture(message: entry.message) { sentryScope in
        sentryScope.setTag(value: entry.scope, key: "scope")
        sentryScope.setExtra(value: entry.file, key: "file")
        sentryScope.setExtra(value: entry.function, key: "function")
        sentryScope.setExtra(value: entry.line, key: "line")
        if let error = entry.error {
          sentryScope.setExtra(value: error, key: "error")
        }
      }
    }
  }
}
