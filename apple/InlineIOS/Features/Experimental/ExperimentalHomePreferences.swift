import Foundation

enum ExperimentalHomePreferenceKeys {
  static let chatScope = "ios.experimental.home.chatScope"
}

enum ExperimentalHomeChatScope: String, CaseIterable, Identifiable {
  case all
  case home
  case spaces

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all:
      "All Chats"
    case .home:
      "Home Only"
    case .spaces:
      "Spaces Only"
    }
  }

  var systemImage: String {
    switch self {
    case .all:
      "tray.full"
    case .home:
      "house.fill"
    case .spaces:
      "building.2"
    }
  }
}

