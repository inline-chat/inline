import Foundation
import Logger

extension LogLevel {
  static let macDevtoolsMinimumLevels: [LogLevel] = [
    .trace,
    .debug,
    .info,
    .warning,
    .error,
  ]

  var macDevtoolsTitle: String {
    switch self {
    case .error: "Error"
    case .warning: "Warning"
    case .info: "Info"
    case .debug: "Debug"
    case .trace: "Trace"
    }
  }

  var macDevtoolsPriority: Int {
    switch self {
    case .trace: 0
    case .debug: 1
    case .info: 2
    case .warning: 3
    case .error: 4
    }
  }
}
