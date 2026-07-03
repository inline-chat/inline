import CoreGraphics
import Foundation
import Logger

enum SendMessageAnimationDiagnostics {
  private static let log = Log.scoped("SendMessageAnimation")

  static func event(_ message: @autoclosure () -> String) {
    #if DEBUG || DEBUG_BUILD
    emit(message())
    #endif
  }

  static func debug(_ message: @autoclosure () -> String) {
    #if DEBUG || DEBUG_BUILD
    guard isVerboseEnabled else { return }
    emit(message())
    #endif
  }

  static func rect(_ rect: CGRect) -> String {
    "x=\(rounded(rect.minX)) y=\(rounded(rect.minY)) w=\(rounded(rect.width)) h=\(rounded(rect.height))"
  }

  static func point(_ point: CGPoint) -> String {
    "x=\(rounded(point.x)) y=\(rounded(point.y))"
  }

  static func size(_ size: CGSize) -> String {
    "w=\(rounded(size.width)) h=\(rounded(size.height))"
  }

  private static func rounded(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
  }

  private static func emit(_ value: String) {
    let prefixedValue = "SEND_ANIM \(value)"
    log.debug(prefixedValue)
    NSLog("%@", prefixedValue)
  }

  private static var isVerboseEnabled: Bool {
    let environment = ProcessInfo.processInfo.environment
    if environment["INLINE_SEND_ANIMATION_VERBOSE_LOGS"] == "1" {
      return true
    }

    return UserDefaults.standard.bool(forKey: "InlineSendAnimationVerboseLogs")
  }
}
