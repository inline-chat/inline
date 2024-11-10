import Foundation

// Common macOS versions
enum MacOSVersion {
  static let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
  static let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
  static let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

  static func isAtLeast(_ version: OperatingSystemVersion) -> Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
  }
}
