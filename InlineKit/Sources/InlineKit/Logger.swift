import Foundation
import Sentry

public enum LogLevel: String {
  case error = "❌ ERROR"
  case warning = "⚠️ WARNING"
  case info = "ℹ️ INFO"
  case debug = "🐛 DEBUG"

  var sentryLevel: SentryLevel {
    switch self {
    case .error: return .error
    case .warning: return .warning
    case .info: return .info
    case .debug: return .debug
    }
  }
}

public protocol Logging {
  func error(_ message: String, error: Error?, file: String, function: String, line: Int)
  func warning(_ message: String, file: String, function: String, line: Int)
  func info(_ message: String, file: String, function: String, line: Int)
  func debug(_ message: String, file: String, function: String, line: Int)
}

public final class Log: @unchecked Sendable {
  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  public static let shared = Log(scope: "shared")

  private let scope: String

  private init(scope: String) {
    self.scope = scope
  }

  public static func scoped(_ scope: String) -> Log {
    Log(scope: scope)
  }

  private func log(
    _ message: String, level: LogLevel, error: Error? = nil, file: String = #file,
    function: String = #function, line: Int = #line
  ) {
    let timestamp = Self.dateFormatter.string(from: Date())
    let fileName = (file as NSString).lastPathComponent
    #if DEBUG
    // Don't log time when in debug mode cleaner logs
      let logMessage =
        "\(level.rawValue) [\(scope)]: \(message) \(error?.localizedDescription ?? "") - [\(fileName):\(line) \(function)]"
    #else
      let logMessage =
        "\(timestamp) \(level.rawValue) [\(scope)] [\(fileName):\(line) \(function)] \(message) \(error?.localizedDescription ?? "")"
    #endif

    print(logMessage)

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
    _ message: String, error: Error? = nil, file: String = #file, function: String = #function,
    line: Int = #line
  ) {
    log(message, level: .error, error: error, file: file, function: function, line: line)
  }

  public func warning(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    log(message, level: .warning, file: file, function: function, line: line)
  }

  public func info(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    log(message, level: .info, file: file, function: function, line: line)
  }

  public func debug(
    _ message: String, file: String = #file, function: String = #function, line: Int = #line
  ) {
    #if DEBUG
      log(message, level: .debug, file: file, function: function, line: line)
    #endif
  }
}
