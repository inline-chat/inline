import SwiftUI

enum TabItem: Int, Codable {
  case chats
  case archived
  case spaces

  var title: String {
    switch self {
      case .chats: "Chats"
      case .archived: "Archived"
      case .spaces: "Spaces"
    }
  }

  var icon: String {
    switch self {
      case .chats: "bubble.left.and.bubble.right.fill"
      case .archived: "archivebox.fill"
      case .spaces: "building.2.fill"
    }
  }
}

class TabBarController: ObservableObject {
  @Published var selectedTab: TabItem = .chats
  @Published var navigationStacks: [TabItem: NavigationPath] = [
    .chats: NavigationPath(),
    .archived: NavigationPath(),
    .spaces: NavigationPath(),
  ]
}
