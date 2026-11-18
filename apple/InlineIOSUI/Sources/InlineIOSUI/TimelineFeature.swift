import Foundation
@_exported import TimelineCore
#if canImport(UIKit)
@_exported import TimelineUIKit
#endif

/// The iOS message list (`InlineTimeline`), read when a chat is built. It is the default; builds that show
/// developer tools keep a switch to go back to the collection view list.
public enum TimelineFeature {
  public static let preferenceKey = "experimental.iosTimeline"

  /// On, unless the build shows developer tools and its switch was turned off.
  public static func isEnabled(defaults: UserDefaults = .standard, allowsOverride: Bool) -> Bool {
    guard allowsOverride else { return true }
    return defaults.object(forKey: preferenceKey) as? Bool ?? true
  }
}
