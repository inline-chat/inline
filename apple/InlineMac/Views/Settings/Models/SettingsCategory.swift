import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
  case account
  case general
  case appearance
  
  var id: String { rawValue }
  
  var title: String {
    switch self {
    case .general:
      return "General"
    case .appearance:
      return "Appearance"
    case .account:
      return "Account"
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
    }
  }
}
