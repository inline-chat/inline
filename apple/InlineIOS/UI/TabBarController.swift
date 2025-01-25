import SwiftUI

enum TabItem: Int {
  case contacts
  case home
  case settings

  var title: String {
    switch self {
      case .home: "Home"
      case .contacts: "Contacts"
      case .settings: "Settings"
    }
  }

  var icon: String {
    switch self {
      case .home: "house"
      case .contacts: "person.2"
      case .settings: "gearshape"
    }
  }
}

class TabBarController: ObservableObject {
  @Published var selectedTab: TabItem = .home
  @Published var navigationStacks: [TabItem: NavigationPath] = [
    .home: NavigationPath(),
    .contacts: NavigationPath(),
    .settings: NavigationPath(),
  ]
}
