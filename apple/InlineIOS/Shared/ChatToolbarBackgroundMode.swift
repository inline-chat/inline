import Foundation

enum ChatToolbarBackgroundMode: String {
  case soft
  case hard

  static let key = "chatToolbarBackgroundMode"
  private static let legacyHardModeKey = "enableCustomChatToolbarBackground"

  /// Preserves the approved experimental choice until the user changes the new Appearance setting.
  static var initialValue: Self {
    let defaults = UserDefaults.standard
    if let rawValue = defaults.string(forKey: key), let mode = Self(rawValue: rawValue) {
      return mode
    }
    return defaults.bool(forKey: legacyHardModeKey) ? .hard : .soft
  }
}
