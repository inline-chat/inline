import Foundation

// Small fallbacks for Foundation APIs newer than the iOS deployment target. Each one uses the
// native API where the OS has it (always on macOS), so only older iOS takes the fallback.

extension URL {
  /// `appending(path:)` (iOS 16). The fallback infers the directory hint from a trailing slash,
  /// like `.inferFromPath`, so it never touches the file system.
  func compatAppending(path: String) -> URL {
    if #available(iOS 16.0, macOS 13.0, *) {
      return appending(path: path)
    }
    return appendingPathComponent(path, isDirectory: path.hasSuffix("/"))
  }
}

extension StringProtocol {
  /// `trimmingPrefix(_:)` (iOS 16): drops `prefix` once when the string starts with it.
  func compatTrimmingPrefix(_ prefix: String) -> SubSequence {
    if #available(iOS 16.0, macOS 13.0, *) {
      return trimmingPrefix(prefix)
    }
    return hasPrefix(prefix) ? dropFirst(prefix.count) : self[...]
  }
}
