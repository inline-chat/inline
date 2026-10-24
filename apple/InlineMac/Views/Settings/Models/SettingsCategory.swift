import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
  case account
  case activeSessions
  case audioAndVideo
  case bots
  case connectors
  case dataStorage
  case general
  case hotkeys
#if SPARKLE
  case updates
#endif
  case appearance
  case notifications
  case privacy
  case experimental
  case debug

  var id: String { rawValue }

  /// Sidebar groups, in order. Search uses the same categories so hidden pages never match.
  static func sidebarGroups(isLoggedIn: Bool) -> [[SettingsCategory]] {
    var updates: [SettingsCategory] = []
#if SPARKLE
    updates.append(.updates)
#endif
    let groups: [[SettingsCategory]] = [
      isLoggedIn ? [.account] : [],
      [.general, .appearance, .notifications, .audioAndVideo],
      isLoggedIn ? [.privacy, .dataStorage, .activeSessions] : [.dataStorage],
      isLoggedIn ? [.connectors, .bots, .hotkeys] : [.hotkeys],
      updates + [.experimental, .debug],
    ]
    return groups.filter { !$0.isEmpty }
  }

  static func available(isLoggedIn: Bool) -> [SettingsCategory] {
    sidebarGroups(isLoggedIn: isLoggedIn).flatMap(\.self)
  }

  var title: String {
    switch self {
    case .general:
      return "General"
    case .audioAndVideo:
      return "Audio and Video"
    case .dataStorage:
      return "Data & Storage"
    case .connectors:
      return "Connectors"
    case .hotkeys:
      return "Hotkeys"
    case .appearance:
      return "Appearance"
    case .account:
      return "Account"
    case .activeSessions:
      return "Active Sessions"
    case .bots:
      return "Bots"
#if SPARKLE
    case .updates:
      return "Updates"
#endif
    case .notifications:
      return "Notifications"
    case .privacy:
      return "Privacy"
    case .experimental:
      return "Experimental"
    case .debug:
      return "Debug"
    }
  }

  /// Image asset shown in the sidebar and search results.
  var iconImageName: String {
    switch self {
    case .general:
      return "SettingsIconGeneral"
    case .audioAndVideo:
      return "SettingsIconAudioAndVideo"
    case .dataStorage:
      return "SettingsIconDataStorage"
    case .connectors:
      return "SettingsIconConnectors"
    case .hotkeys:
      return "SettingsIconHotkeys"
    case .appearance:
      return "SettingsIconAppearance"
    case .account:
      return "SettingsIconAccount"
    case .activeSessions:
      return "SettingsIconActiveSessions"
    case .bots:
      return "SettingsIconBots"
#if SPARKLE
    case .updates:
      return "SettingsIconUpdates"
#endif
    case .notifications:
      return "SettingsIconNotifications"
    case .privacy:
      return "SettingsIconPrivacy"
    case .experimental:
      return "SettingsIconExperimental"
    case .debug:
      return "SettingsIconDebug"
    }
  }
}
