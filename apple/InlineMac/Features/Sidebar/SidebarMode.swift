import Foundation

enum SidebarMode: String, CaseIterable, Identifiable {
  case inbox
  case allChats

  var id: String { rawValue }

  var title: String {
    switch self {
    case .allChats:
      "All Chats"
    case .inbox:
      "Open"
    }
  }

  var detail: String {
    switch self {
    case .allChats:
      "Every chat, ordered by recent activity"
    case .inbox:
      "Chats you keep open in the sidebar"
    }
  }
}
