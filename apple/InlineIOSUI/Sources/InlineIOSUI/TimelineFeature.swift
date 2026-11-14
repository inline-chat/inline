import Foundation
@_exported import TimelineCore
#if canImport(UIKit)
@_exported import TimelineUIKit
#endif

/// The new iOS message list (`InlineTimeline`), behind a switch read when a chat is built.
public enum TimelineFeature {
  public static let preferenceKey = "experimental.iosTimeline"

  /// Off unless the build shows developer tools and the switch is on.
  public static func isEnabled(defaults: UserDefaults = .standard, allowsOverride: Bool) -> Bool {
    allowsOverride && defaults.bool(forKey: preferenceKey)
  }
}
