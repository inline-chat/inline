import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
  case account
  case general
  case appearance
  case notifications
  case experimental
  case debug
  
  var id: String { rawValue }
  
  var title: String {
    switch self {
    case .general:
      return "General"
    case .appearance:
      return "Appearance"
    case .account:
      return "Account"
    case .notifications:
      return "Notifications"
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
    case .appearance:
      return "paintbrush"
    case .account:
      return "person.circle"
    case .notifications:
      return "bell"
    case .experimental:
      return "testtube.2"
    case .debug:
      return "ladybug.fill"
    }
  }
}
