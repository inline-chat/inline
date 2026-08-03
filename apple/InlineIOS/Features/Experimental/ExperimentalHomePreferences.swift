import Foundation
import InlineKit

enum ExperimentalHomePreferenceKeys {
  static let isEnabled = "enableExperimentalView"
  static let chatScope = "ios.experimental.home.chatScope"
  static let chatItemRenderMode = "ios.experimental.home.chatItemRenderMode"
  static let sortMode = "ios.experimental.home.sortMode"
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

enum ExperimentalHomeSortMode: String, CaseIterable, Identifiable {
  case openedTime
  case recentActivity

  var id: String { rawValue }

  var title: String {
    switch self {
    case .openedTime:
      "Opened Time"
    case .recentActivity:
      "Recent Activity"
    }
  }

  var chatListSort: ChatListSort {
    switch self {
    case .openedTime:
      .recentlyOpened
    case .recentActivity:
      .lastUpdated
    }
  }
}

enum ExperimentalHomeChatItemRenderMode: String, CaseIterable, Identifiable {
  case twoLineLastMessage
  // Kept for compatibility with preferences written by the earlier picker.
  case oneLineLastMessage
  case noLastMessage = "minimal"
  case large

  static var allCases: [ExperimentalHomeChatItemRenderMode] {
    [.noLastMessage, .twoLineLastMessage, .large]
  }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .noLastMessage:
      "Compact"
    case .oneLineLastMessage, .twoLineLastMessage:
      "Standard"
    case .large:
      "Large"
    }
  }

  var systemImage: String {
    switch self {
    case .noLastMessage:
      "line.3.horizontal.decrease"
    case .oneLineLastMessage, .twoLineLastMessage:
      "text.justify.left"
    case .large:
      "text.alignleft"
    }
  }
}
