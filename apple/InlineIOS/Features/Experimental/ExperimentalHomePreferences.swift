import Foundation

enum ExperimentalHomePreferenceKeys {
  static let chatScope = "ios.experimental.home.chatScope"
  static let chatItemRenderMode = "ios.experimental.home.chatItemRenderMode"
}

enum ExperimentalHomeChatScope: String, CaseIterable, Identifiable {
  case all
  case home

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all:
      "All"
    case .home:
      "Only Home"
    }
  }

  var systemImage: String {
    switch self {
    case .all:
      "tray.full"
    case .home:
      "house.fill"
    }
  }
}

enum ExperimentalHomeChatItemRenderMode: String, CaseIterable, Identifiable {
  case twoLineLastMessage
  case oneLineLastMessage
  case noLastMessage = "minimal"

  static var allCases: [ExperimentalHomeChatItemRenderMode] {
    [.noLastMessage, .oneLineLastMessage, .twoLineLastMessage]
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .twoLineLastMessage:
      "Default"
    case .oneLineLastMessage:
      "Medium"
    case .noLastMessage:
      "Compact"
    }
  }

  var systemImage: String {
    switch self {
    case .twoLineLastMessage:
      "text.alignleft"
    case .oneLineLastMessage:
      "text.justify.left"
    case .noLastMessage:
      "line.3.horizontal.decrease"
    }
  }
}
