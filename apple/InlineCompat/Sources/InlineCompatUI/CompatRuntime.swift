@_exported import InlineCompat

/// Gate for "use the newest API when the OS has it".
///
/// Every helper in InlineCompatUI checks `#available` first and then `CompatRuntime.allows`,
/// so a current device can be switched to the legacy code paths to preview how the app looks
/// and behaves on iOS 15. Pattern for new code:
///
///     if #available(iOS 17.0, *), CompatRuntime.allows(.iOS17) {
///       imageView.addSymbolEffect(.bounce)
///     } else {
///       imageView.compatPulse()
///     }
public enum CompatRuntime {
  public enum Release: Int, Comparable, Sendable, CaseIterable {
    case iOS15 = 15, iOS16 = 16, iOS17 = 17, iOS18 = 18, iOS26 = 26, iOS27 = 27

    public static func < (lhs: Release, rhs: Release) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// Newest release whose APIs helpers may use. `nil` means no cap (use everything available).
  /// Set it early at launch, for example from a debug setting.
  nonisolated(unsafe) public static var apiCeiling: Release?

  /// Whether helpers may use APIs introduced in `release`. Combine with `#available`.
  @inline(__always)
  public static func allows(_ release: Release) -> Bool {
    guard let apiCeiling else { return true }
    return release <= apiCeiling
  }
}
