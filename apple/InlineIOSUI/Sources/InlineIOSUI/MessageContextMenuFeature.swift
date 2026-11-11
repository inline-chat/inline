import Foundation

/// Which context menu a message long press opens.
public enum MessageContextMenuImplementation: Equatable, Sendable {
  /// UIKit's `UIContextMenuInteraction`.
  case system
  /// Inline's own menu: live, selectable preview, Telegram-style scrolling and timing.
  case custom
}

/// The custom menu is the default. The Experimental setting turns it off, and a crash guard
/// turns it off on its own when the app keeps dying with the menu open.
public enum MessageContextMenuFeature {
  public static let preferenceKey = "experimental.iosCustomMessageContextMenu"
  /// Set while a custom menu is on screen and cleared when it closes or the app leaves the
  /// foreground. Still set at launch means the last run ended with the menu open.
  static let openMarkerKey = "messageContextMenu.custom.open"
  static let strikesKey = "messageContextMenu.custom.strikes"
  /// Runs that may end with the menu open before the guard turns it off.
  public static let strikeLimit = 2

  public static func selectedImplementation(
    defaults: UserDefaults = .standard,
    isAvailable: Bool = true
  ) -> MessageContextMenuImplementation {
    guard isAvailable, defaults.object(forKey: preferenceKey) as? Bool != false else { return .system }
    return .custom
  }

  /// What the last run left behind.
  public enum LaunchCheck: Equatable, Sendable {
    case clean
    /// The last run ended with the menu open; `count` such runs so far.
    case strike(count: Int)
    /// That happened `strikeLimit` times, so the preference is now off.
    case turnedOff(count: Int)
  }

  /// Checks once per launch, before the first menu opens, whether the last run ended with the
  /// custom menu open, and turns the menu off after `strikeLimit` of those.
  public static func checkLastRun(defaults: UserDefaults = .standard) -> LaunchCheck {
    guard defaults.bool(forKey: openMarkerKey) else { return .clean }
    defaults.removeObject(forKey: openMarkerKey)
    let count = defaults.integer(forKey: strikesKey) + 1
    defaults.set(count, forKey: strikesKey)
    // Someone who turned the menu on by hand keeps it.
    guard count >= strikeLimit, defaults.object(forKey: preferenceKey) == nil else {
      return .strike(count: count)
    }
    defaults.set(false, forKey: preferenceKey)
    return .turnedOff(count: count)
  }

  public static func markOpen(defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: openMarkerKey)
  }

  public static func markClosed(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: openMarkerKey)
  }

  /// The person chose the menu again in Settings: forget earlier strikes.
  public static func resetCrashGuard(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: strikesKey)
    defaults.removeObject(forKey: openMarkerKey)
  }
}
