import Foundation
import OSLog
import Sentry

public enum LogLevel: String {
  case error = "❌ ERROR"
  case warning = "⚠️ WARNING"
  case info = "ℹ️ INFO"
  case debug = "🐛 DEBUG"
  case trace = "🚧 TRACE"
  
  var osLogType: OSLogType {
    switch self {
    case .error: return .error
    case .warning: return .fault
    case .info: return .info
    case .debug: return .debug
    case .trace: return .debug
    }
  }
  
  var sentryLevel: SentryLevel {
    switch self {
    case .error: return .error
    case .warning: return .warning
    case .info: return .info
    case .debug: return .debug
    case .trace: return .debug
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
  private let logger: Logger
  
  private init(scope: String, level: LogLevel = .debug) {
    self.scope = scope
    self.level = level
    self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.app", category: scope)
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
    
    logger.log(level: level.osLogType, "\(level.rawValue) | \(scope_) | \(logMessage)")
    
    if level == .error, let error = error {
      SentrySDK.capture(error: error) { sentryScope in
        sentryScope.setLevel(level.sentryLevel)
        sentryScope.setTag(value: self.scope, key: "scope")
        sentryScope.setExtra(value: message, key: "message")
      }
    } else {
      SentrySDK.capture(message: message) { sentryScope in
        sentryScope.setLevel(level.sentryLevel)
        sentryScope.setTag(value: self.scope, key: "scope")
        if let error = error {
          sentryScope.setExtra(value: error.localizedDescription, key: "error")
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
