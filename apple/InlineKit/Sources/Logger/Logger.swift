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
      case .warning: .default
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
  public let eventName: String
  public let fields: [LogField]
  public let isStructured: Bool

  public init(
    entry: LogEntry,
    error: Error?,
    eventName: String = "unstructured_log",
    fields: [LogField] = [],
    isStructured: Bool = false
  ) {
    self.entry = entry
    self.error = error
    self.eventName = eventName
    self.fields = fields
    self.isStructured = isStructured
  }

  /// The only message default remote/public sinks may export. The original
  /// message remains available to explicitly local sinks through `entry`.
  public var exportedMessage: String {
    var components = [
      "scope=\(exportedScope)",
      "event=\(LogExportSanitizer.identifier(eventName, fallback: "unstructured_log"))",
      "source=\(LogExportSanitizer.source(fileName: entry.fileName, line: entry.line))",
    ]
    components.append(contentsOf: exportedFields.map { "\($0.name)=\($0.value)" })
    return components.joined(separator: " ")
  }

  public var exportedScope: String {
    LogExportSanitizer.identifier(entry.scope, fallback: "unknown")
  }

  public var exportedFields: [LogExportField] {
    fields
      .compactMap(LogExportSanitizer.export)
      .sorted { lhs, rhs in lhs.name < rhs.name }
  }

  public var exportedError: LogExportError? {
    guard let error else { return nil }
    let nsError = error as NSError
    return LogExportError(
      type: LogExportSanitizer.identifier(
        String(describing: type(of: error)),
        fallback: "Error"
      ),
      domain: LogExportSanitizer.identifier(nsError.domain, fallback: "unknown"),
      code: nsError.code
    )
  }
}

public enum LogFieldPrivacy: String, Sendable, Equatable {
  /// A deliberately non-sensitive value that can be emitted to remote/public sinks.
  case diagnostic
  /// A value retained only in the local `LogEntry` representation.
  case sensitive
}

public struct LogField: Sendable, Equatable {
  public let name: String
  public let value: String
  public let privacy: LogFieldPrivacy

  private init(name: StaticString, value: String, privacy: LogFieldPrivacy) {
    self.name = String(describing: name)
    self.value = value
    self.privacy = privacy
  }

  public static func diagnostic(_ name: StaticString, _ value: StaticString) -> LogField {
    LogField(name: name, value: String(describing: value), privacy: .diagnostic)
  }

  public static func diagnostic(_ name: StaticString, _ value: Int) -> LogField {
    LogField(name: name, value: String(value), privacy: .diagnostic)
  }

  public static func diagnostic(_ name: StaticString, _ value: Int64) -> LogField {
    LogField(name: name, value: String(value), privacy: .diagnostic)
  }

  public static func diagnostic(_ name: StaticString, _ value: Double) -> LogField {
    LogField(name: name, value: String(value), privacy: .diagnostic)
  }

  public static func diagnostic(_ name: StaticString, _ value: Bool) -> LogField {
    LogField(name: name, value: String(value), privacy: .diagnostic)
  }

  /// An explicitly reviewed runtime identifier. Prefer the typed or
  /// `StaticString` overloads; export sanitization is still applied.
  public static func diagnosticIdentifier(_ name: StaticString, _ value: String) -> LogField {
    LogField(name: name, value: value, privacy: .diagnostic)
  }

  public static func sensitive(_ name: StaticString, _ value: some CustomStringConvertible) -> LogField {
    LogField(name: name, value: String(describing: value), privacy: .sensitive)
  }
}

public struct LogExportField: Sendable, Equatable {
  public let name: String
  public let value: String
}

public struct LogExportError: Sendable, Equatable {
  public let type: String
  public let domain: String
  public let code: Int
}

public enum LogPrivacy {
  /// Keeps route-level diagnostics while removing credentials, query values,
  /// fragments, and URL user info.
  public static func redactedURL(_ value: String) -> String {
    guard var components = URLComponents(string: value),
          let scheme = components.scheme,
          scheme == "http" || scheme == "https" else {
      return "redacted_url"
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? "redacted_url"
  }
}

private enum LogExportSanitizer {
  private static let identifierScalars = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/"
  )
  private static let sensitiveFieldNames: Set<String> = [
    "authorization", "body", "challenge", "challenge_token", "code", "content", "cookie",
    "email", "file", "file_path", "invite", "invite_code", "message", "otp", "password",
    "path", "phone", "query", "response_body", "secret", "subtitle", "text", "title", "token",
    "url", "user_text",
  ]

  static func export(_ field: LogField) -> LogExportField? {
    guard field.privacy == .diagnostic else { return nil }
    let name = identifier(field.name, fallback: "field")
    guard !isSensitiveFieldName(name) else { return nil }
    return LogExportField(name: name, value: value(field.value))
  }

  static func identifier(_ value: String, fallback: String) -> String {
    guard !value.isEmpty, value.count <= 160 else { return fallback }
    guard value.unicodeScalars.allSatisfy(identifierScalars.contains) else { return fallback }
    return value
  }

  static func source(fileName: String, line: Int) -> String {
    "\(identifier(fileName, fallback: "unknown.swift")):\(max(0, line))"
  }

  private static func isSensitiveFieldName(_ value: String) -> Bool {
    let normalized = value.lowercased().replacingOccurrences(of: "-", with: "_")
    return sensitiveFieldNames.contains(normalized)
  }

  private static func value(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "empty" }

    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("file:") {
      return "redacted_path"
    }

    if let components = URLComponents(string: trimmed),
       let scheme = components.scheme,
       scheme == "http" || scheme == "https" {
      return LogPrivacy.redactedURL(components.string ?? trimmed)
    }

    if trimmed.contains("@") {
      return "redacted_email"
    }

    let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
    if singleLine.count <= 256 {
      return singleLine
    }
    return "\(singleLine.prefix(256))…"
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
    logger(for: event.exportedScope).log(
      level: entry.level.osLogType,
      "\(entry.level.rawValue, privacy: .public) | \(event.exportedMessage, privacy: .public) | details=\(entry.message, privacy: .private)"
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
    guard SentrySDK.isEnabled else { return }

    let entry = event.entry

    if entry.level == .info {
      SentrySDK.logger.info(event.exportedMessage)
    }

    guard entry.level == .error else { return }

    Task {
      if let error = event.error {
        await SentryReporter.shared.reportError(
          error,
          event: event
        )
      } else {
        await SentryReporter.shared.reportMessage(
          event
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
    eventName: String = "unstructured_log",
    fields: [LogField] = [],
    isStructured: Bool = false,
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

    let event = LogEvent(
      entry: entry,
      error: error,
      eventName: eventName,
      fields: fields,
      isStructured: isStructured
    )
    for sink in Self.registry.snapshot() {
      sink.write(event)
    }
  }

  private func log(
    event: StaticString,
    fields: [LogField],
    level: LogLevel,
    error: Error? = nil,
    file: String,
    function: String,
    line: Int
  ) {
    let eventName = String(describing: event)
    let localFields = fields.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
    let localMessage = localFields.isEmpty ? eventName : "\(eventName) \(localFields)"
    log(
      localMessage,
      level: level,
      error: error,
      eventName: eventName,
      fields: fields,
      isStructured: true,
      file: file,
      function: function,
      line: line
    )
  }

  public func error(
    event: StaticString,
    fields: [LogField] = [],
    error: Error? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(
      event: event,
      fields: fields,
      level: .error,
      error: error,
      file: file,
      function: function,
      line: line
    )
  }

  public func warning(
    event: StaticString,
    fields: [LogField] = [],
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(event: event, fields: fields, level: .warning, file: file, function: function, line: line)
  }

  public func info(
    event: StaticString,
    fields: [LogField] = [],
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(event: event, fields: fields, level: .info, file: file, function: function, line: line)
  }

  /// Emits only catalogued event names and fields to public/remote sinks.
  /// Invalid schemas are contained as a metadata-only warning rather than
  /// crashing the caller or exporting the rejected value.
  public func telemetry(
    _ event: TelemetryEvent,
    fields: [TelemetryField] = [],
    error: Error? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    let record: TelemetryRecord
    do {
      record = try TelemetryRecord(event: event, fields: fields)
    } catch {
      log(
        "telemetry_schema_violation rejected_event=\(event.rawValue)",
        level: .warning,
        eventName: "telemetry_schema_violation",
        fields: [.diagnosticIdentifier("rejected_event", event.rawValue)],
        isStructured: true,
        file: file,
        function: function,
        line: line
      )
      return
    }

    let logFields = record.logFields
    let localFields = logFields.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
    let localMessage = localFields.isEmpty ? event.rawValue : "\(event.rawValue) \(localFields)"
    log(
      localMessage,
      level: event.level,
      error: error,
      eventName: event.rawValue,
      fields: logFields,
      isStructured: true,
      file: file,
      function: function,
      line: line
    )
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
    event: LogEvent
  ) async {
    guard SentrySDK.isEnabled else { return }
    guard shouldReport(error) else { return }

    await MainActor.run {
      _ = SentrySDK.capture(message: event.exportedMessage) { sentryScope in
        Self.configure(scope: sentryScope, for: event)
      }
    }
  }

  func reportMessage(
    _ event: LogEvent
  ) async {
    guard SentrySDK.isEnabled else { return }

    await MainActor.run {
      _ = SentrySDK.capture(message: event.exportedMessage) { sentryScope in
        Self.configure(scope: sentryScope, for: event)
      }
    }
  }

  private nonisolated static func configure(scope: Scope, for event: LogEvent) {
    let entry = event.entry
    scope.setTag(
      value: event.exportedScope,
      key: "scope"
    )
    scope.setTag(value: event.isStructured ? "structured" : "legacy", key: "log_contract")
    scope.setExtra(value: entry.fileName, key: "file_name")
    scope.setExtra(value: entry.function, key: "function")
    scope.setExtra(value: entry.line, key: "line")
    for field in event.exportedFields {
      scope.setExtra(value: field.value, key: field.name)
    }
    if let error = event.exportedError {
      scope.setExtra(value: error.type, key: "error_type")
      scope.setExtra(value: error.domain, key: "error_domain")
      scope.setExtra(value: error.code, key: "error_code")
    }
  }
}
