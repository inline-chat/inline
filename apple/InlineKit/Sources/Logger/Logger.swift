import Foundation
import OSLog
import Sentry
import Darwin
import Synchronization

/// Supplies a bounded, non-sensitive error discriminator for release telemetry.
/// Values must describe only static program state (for example, an enum case or
/// protocol code) and must never contain request, account, or user data.
public protocol PrivacySafeErrorCategoryProviding: Error {
  var privacySafeErrorCategory: String { get }
}

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

public enum LogDetail: String, Codable, Sendable {
  /// Caller-provided text, unmodified. Debug builds or the local unredacted-logs override.
  case full
  /// Text passed through `LogScrubber`. Default for release builds and always for Sentry.
  case scrubbed
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
  /// Whether `message` and `error` hold full or scrubbed text.
  public let detail: LogDetail

  // Entries persisted before `detail` existed decode as scrubbed.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    level = try container.decode(LogLevel.self, forKey: .level)
    scope = try container.decode(String.self, forKey: .scope)
    message = try container.decode(String.self, forKey: .message)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    file = try container.decode(String.self, forKey: .file)
    fileName = try container.decode(String.self, forKey: .fileName)
    function = try container.decode(String.self, forKey: .function)
    line = try container.decode(Int.self, forKey: .line)
    processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
    threadIdentifier = try container.decode(UInt64.self, forKey: .threadIdentifier)
    detail = try container.decodeIfPresent(LogDetail.self, forKey: .detail) ?? .scrubbed
  }

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
    threadIdentifier: UInt64? = nil,
    detail: LogDetail = .full
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
    self.detail = detail
  }

  /// The same entry with free-form text scrubbed; returns `self` if already scrubbed.
  func scrubbed() -> LogEntry {
    guard detail == .full else { return self }
    return LogEntry(
      id: id,
      timestamp: timestamp,
      level: level,
      scope: Log.safeScope(scope),
      message: LogScrubber.scrub(message),
      error: error.map(LogScrubber.scrub),
      file: fileName,
      fileName: fileName,
      function: function,
      line: line,
      processIdentifier: processIdentifier,
      threadIdentifier: threadIdentifier,
      detail: .scrubbed
    )
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
  public let http: HTTPLogMetadata?

  public init(entry: LogEntry, error: Error?, http: HTTPLogMetadata? = nil) {
    self.entry = entry
    self.error = error
    self.http = http
  }
}

/// A deliberately narrow projection of an HTTP failure that is safe to persist.
/// It accepts endpoint templates only; raw URLs, queries, headers, and bodies have
/// no representation here.
public struct HTTPLogMetadata: Sendable, Equatable {
  public let method: String
  public let endpointTemplate: String
  public let statusCode: Int
  public let requestID: String?
  public let responseBytes: Int?
  public let apiErrorCode: Int?

  public init?(
    method: String,
    endpointTemplate: String,
    statusCode: Int,
    requestID: String? = nil,
    responseBytes: Int? = nil,
    apiErrorCode: Int? = nil
  ) {
    let normalizedMethod = method.uppercased()
    guard Self.allowedMethods.contains(normalizedMethod),
          Self.isSafeEndpointTemplate(endpointTemplate),
          (100 ... 599).contains(statusCode)
    else {
      return nil
    }

    self.method = normalizedMethod
    self.endpointTemplate = endpointTemplate
    self.statusCode = statusCode
    self.requestID = requestID.flatMap(Self.safeRequestID)
    self.responseBytes = responseBytes.map { max(0, $0) }
    self.apiErrorCode = apiErrorCode
  }

  var consoleMessage: String {
    var fields = [
      "event=http.request_failed",
      "method=\(method)",
      "endpoint=\(endpointTemplate)",
      "status=\(statusCode)",
    ]
    if let requestID { fields.append("request_id=\(requestID)") }
    if let responseBytes { fields.append("response_bytes=\(responseBytes)") }
    if let apiErrorCode { fields.append("api_error_code=\(apiErrorCode)") }
    return fields.joined(separator: " ")
  }

  private static let allowedMethods: Set<String> = ["DELETE", "GET", "HEAD", "PATCH", "POST", "PUT"]

  private static func isSafeEndpointTemplate(_ value: String) -> Bool {
    guard value.hasPrefix("/"), value.count <= 160 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      CharacterSet.alphanumerics.contains(scalar) || "/-_.{}".unicodeScalars.contains(scalar)
    }
  }

  private static func safeRequestID(_ value: String) -> String? {
    guard !value.isEmpty, value.count <= 128 else { return nil }
    let isSafe = value.utf8.allSatisfy { byte in
      switch byte {
      case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
        true
      default:
        false
      }
    }
    return isSafe ? value : nil
  }

}

struct LogSourceLocation: Sendable {
  let file: String
  let function: String
  let line: Int
}

enum SentryLogPolicy {
  static func shouldReport(http: HTTPLogMetadata?) -> Bool {
    http?.statusCode != 429
  }

  static func fingerprint(entry: LogEntry, errorCategory: String?, http: HTTPLogMetadata?) -> [String] {
    var components = ["app-error", entry.fileName, String(entry.line), errorCategory ?? "none"]
    if let http {
      components.append(contentsOf: [
        http.method,
        http.endpointTemplate,
        String(http.statusCode),
      ])
    }
    return components
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
    let logger = logger(for: entry.scope)
    // Entries are already scrubbed unless full local details were requested, so they
    // are public in the unified log and readable via Console or `log stream`.
    if let http = event.http {
      logger.log(level: entry.level.osLogType, "\(http.consoleMessage, privacy: .public) \(entry.consoleMessage, privacy: .public)")
    } else {
      logger.log(level: entry.level.osLogType, "\(entry.consoleMessage, privacy: .public)")
    }
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

    // Sentry always receives the scrubbed projection, even when local logs are unredacted.
    let projection = entry.scrubbed()

    switch entry.level {
    case .error:
      let errorCategory = Log.errorCategory(event.error)
      Task {
        await SentryReporter.shared.report(
          projection,
          errorCategory: errorCategory,
          originalError: event.error,
          http: event.http
        )
      }
    case .warning, .info:
      Task {
        await SentryReporter.shared.addBreadcrumb(projection)
      }
    case .debug, .trace:
      break
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

  /// UserDefaults key backing the local unredacted-logs override.
  public static let unredactedLocalLogsDefaultsKey = "logger.unredactedLocalLogs"

  private static let unredactedLocalLogsFlag = Atomic<Bool>(
    UserDefaults.standard.bool(forKey: unredactedLocalLogsDefaultsKey)
  )

  /// When enabled, release builds write unscrubbed log messages (including debug and trace
  /// logs) to local sinks: the unified log and in-process sinks such as MacDevtools.
  /// Sentry always receives the scrubbed projection regardless of this flag.
  public static var unredactedLocalLogs: Bool {
    unredactedLocalLogsFlag.load(ordering: .relaxed)
  }

  public static func setUnredactedLocalLogs(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: unredactedLocalLogsDefaultsKey)
    unredactedLocalLogsFlag.store(enabled, ordering: .relaxed)
  }

  private func log(
    _ message: String,
    level: LogLevel,
    error: Error? = nil,
    http: HTTPLogMetadata? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    // Respect the logger's configured minimum level
    guard level.priority >= self.level.priority else { return }

    let entry = Self.makeEntry(
      level: level,
      scope: scope,
      message: message,
      error: error,
      source: LogSourceLocation(file: file, function: function, line: line),
      detail: Self.localDetail
    )

    let event = LogEvent(entry: entry, error: error, http: http)
    for sink in Self.registry.snapshot() {
      sink.write(event)
    }
  }

  public func httpError(
    _ metadata: HTTPLogMetadata,
    error: Error? = nil,
    file: String = #file,
    function: String = #function,
    line: Int = #line
  ) {
    log(
      "HTTP request failed",
      level: .error,
      error: error,
      http: metadata,
      file: file,
      function: function,
      line: line
    )
  }

  static func makeEntry(
    level: LogLevel,
    scope: String,
    message: String,
    error: Error?,
    source: LogSourceLocation,
    detail: LogDetail
  ) -> LogEntry {
    let fileName = (source.file as NSString).lastPathComponent
    let errorDescription = errorDetail(error)

    func render(_ value: String) -> String {
      detail == .full ? value : LogScrubber.scrub(value)
    }
    let renderedMessage = render(message)
    let renderedError = errorDescription.map(render)
    let location = if scope == "shared" || level == .error {
      "[\(fileName):\(source.line) \(source.function)] "
    } else {
      ""
    }
    let fullMessage = [location + renderedMessage, renderedError]
      .compactMap { $0 }
      .joined(separator: " | ")

    return LogEntry(
      level: level,
      scope: detail == .full ? scope : safeScope(scope),
      message: fullMessage,
      error: renderedError,
      file: detail == .full ? source.file : fileName,
      fileName: fileName,
      function: source.function,
      line: source.line,
      detail: detail
    )
  }

  static var localDetail: LogDetail {
    #if DEBUG || DEBUG_BUILD
    localDetail(isDebugBuild: true, unredactedLocalLogs: unredactedLocalLogs)
    #else
    localDetail(isDebugBuild: false, unredactedLocalLogs: unredactedLocalLogs)
    #endif
  }

  static func localDetail(isDebugBuild: Bool, unredactedLocalLogs: Bool) -> LogDetail {
    isDebugBuild || unredactedLocalLogs ? .full : .scrubbed
  }

  /// Type, domain, code, and description: enough to tell errors apart without a debugger.
  static func errorDetail(_ error: Error?) -> String? {
    guard let error else { return nil }
    let nsError = error as NSError
    let described = String(describing: error)
    var parts = ["\(String(reflecting: type(of: error))) (\(nsError.domain):\(nsError.code))"]
    if !described.isEmpty { parts.append(described) }
    let localized = nsError.localizedDescription
    if !localized.isEmpty, !described.contains(localized) { parts.append(localized) }
    return parts.joined(separator: " ")
  }

  static func safeScope(_ scope: String) -> String {
    guard !scope.isEmpty, scope.utf8.count <= 64 else { return "app" }
    let isSafe = scope.utf8.allSatisfy { byte in
      switch byte {
      case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
        true
      default:
        false
      }
    }
    return isSafe ? scope : "app"
  }

  static func errorCategory(_ error: Error?) -> String? {
    guard let error else { return nil }
    if error is CancellationError { return "cancelled" }
    if let urlError = error as? URLError {
      return "url:\(urlError.errorCode)"
    }
    if let categorized = error as? any PrivacySafeErrorCategoryProviding,
       let category = validatedErrorCategory(categorized.privacySafeErrorCategory) {
      return category
    }
    return "other"
  }

  private static func validatedErrorCategory(_ value: String) -> String? {
    guard !value.isEmpty, value.utf8.count <= 96 else { return nil }
    let isSafe = value.utf8.allSatisfy { byte in
      switch byte {
      case 45, 46, 48 ... 57, 58, 65 ... 90, 95, 97 ... 122:
        true
      default:
        false
      }
    }
    return isSafe ? value : nil
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
    #else
    guard Self.unredactedLocalLogs else { return }
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
    #else
    guard Self.unredactedLocalLogs else { return }
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

  func addBreadcrumb(_ entry: LogEntry) {
    guard SentrySDK.isEnabled else { return }
    let crumb = Breadcrumb(level: entry.level == .warning ? .warning : .info, category: entry.scope)
    crumb.type = "debug"
    crumb.message = entry.message
    crumb.timestamp = entry.timestamp
    SentrySDK.addBreadcrumb(crumb)
  }

  func report(
    _ entry: LogEntry,
    errorCategory: String?,
    originalError: Error?,
    http: HTTPLogMetadata?
  ) async {
    guard SentrySDK.isEnabled else { return }
    guard SentryLogPolicy.shouldReport(http: http) else { return }
    if let originalError, !shouldReport(originalError) { return }

    // Scope copying and capture are synchronous in sentry-cocoa. Keep that work on
    // this serial reporter actor so an ordinary handled error cannot stall the UI.
    // Grouping uses the bounded fingerprint, so the scrubbed message can vary freely.
    _ = SentrySDK.capture(message: entry.message) { sentryScope in
      sentryScope.setLevel(.error)
      sentryScope.setFingerprint(SentryLogPolicy.fingerprint(entry: entry, errorCategory: errorCategory, http: http))
      sentryScope.setTag(value: entry.scope, key: "scope")
      sentryScope.setTag(value: entry.fileName, key: "source_file")
      sentryScope.setTag(value: entry.function, key: "source_function")
      sentryScope.setExtra(value: errorCategory ?? "none", key: "error_category")
      if let errorCategory {
        sentryScope.setTag(value: errorCategory, key: "error_category")
      }
      if let errorDetail = entry.error {
        sentryScope.setExtra(value: errorDetail, key: "error_detail")
      }
      sentryScope.setExtra(value: entry.line, key: "line")
      if let http {
        sentryScope.setTag(value: "http.request_failed", key: "event")
        sentryScope.setTag(value: http.method, key: "http.method")
        sentryScope.setTag(value: http.endpointTemplate, key: "http.endpoint_template")
        sentryScope.setTag(value: String(http.statusCode), key: "http.status_code")
        if let requestID = http.requestID {
          sentryScope.setExtra(value: requestID, key: "http.request_id")
        }
        if let responseBytes = http.responseBytes {
          sentryScope.setExtra(value: responseBytes, key: "http.response_bytes")
        }
        if let apiErrorCode = http.apiErrorCode {
          sentryScope.setExtra(value: apiErrorCode, key: "http.api_error_code")
        }
      }
    }
  }
}
