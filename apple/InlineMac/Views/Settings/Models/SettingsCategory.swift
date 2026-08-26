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

  var iconName: String {
    switch self {
    case .general:
      return "gear"
    case .audioAndVideo:
      return "speaker.wave.2"
    case .dataStorage:
      return "externaldrive"
    case .connectors:
      return "app.connected.to.app.below.fill"
    case .hotkeys:
      return "keyboard"
    case .appearance:
      return "paintbrush"
    case .account:
      return "person.circle"
    case .activeSessions:
      return "laptopcomputer.and.iphone"
    case .bots:
      return "cpu"
#if SPARKLE
    case .updates:
      return "arrow.triangle.2.circlepath"
#endif
    case .notifications:
      return "bell"
    case .privacy:
      return "hand.raised"
    case .experimental:
      return "testtube.2"
    case .debug:
      return "ladybug.fill"
    }
  }
}
