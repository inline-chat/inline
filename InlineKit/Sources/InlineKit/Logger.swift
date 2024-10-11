import Foundation
import Sentry

public enum LogScope: String {
    case chat = "💬 Chat"
    case api = "🔗 API"
    case space = "⚪️ Space"
    case none = "🗂️ None scoped"
}

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

public final class Log: @unchecked Sendable {
    public static let shared = Log()
    
    private let dateFormatter: DateFormatter
    
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }
    
    private func log(_ message: String, level: LogLevel, scope: LogScope, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "\(level.rawValue) [\(scope.rawValue)] [\(fileName):\(line) \(function)] \(message) \(error)"
        
        print(logMessage)
        
        if level == .error {
            SentrySDK.capture(message: message) { sentryScope in
                sentryScope.setLevel(level.sentryLevel)
                sentryScope.setTag(value: scope.rawValue, key: "scope")
                if let error = error {
                    sentryScope.setExtra(value: error.localizedDescription, key: "error")
                }
            }
        }
    }
    
    public func error(_ message: String, error: Error? = nil, scope: LogScope = .none, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, scope: scope, error: error, file: file, function: function, line: line)
    }
    
    public func warning(_ message: String, scope: LogScope = .none, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .warning, scope: scope, file: file, function: function, line: line)
    }
    
    public func info(_ message: String, scope: LogScope = .none, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .info, scope: scope, file: file, function: function, line: line)
    }
    
    public func debug(_ message: String, scope: LogScope = .none, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(message, level: .debug, scope: scope, file: file, function: function, line: line)
        #endif
    }
}
