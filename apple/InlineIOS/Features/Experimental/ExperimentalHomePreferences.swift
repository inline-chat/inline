import Foundation

enum ExperimentalHomePreferenceKeys {
  static let chatScope = "ios.experimental.home.chatScope"
  static let chatItemRenderMode = "ios.experimental.home.chatItemRenderMode"
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

enum ExperimentalHomeChatItemRenderMode: String, CaseIterable, Identifiable {
  case twoLineLastMessage
  case oneLineLastMessage
  case noLastMessage = "minimal"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .twoLineLastMessage:
      "2-Line Last Message"
    case .oneLineLastMessage:
      "1-Line Last Message"
    case .noLastMessage:
      "No Last Message"
    }
  }

  var systemImage: String {
    switch self {
    case .twoLineLastMessage:
      "text.alignleft"
    case .oneLineLastMessage:
      "text.justify.left"
    case .noLastMessage:
      "text.badge.minus"
    }
  }
}
