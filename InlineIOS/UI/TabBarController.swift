import SwiftUI

enum TabItem: Int {
  case contacts
  case home
  case settings

  var title: String {
    switch self {
    case .home: return "Home"
    case .contacts: return "Contacts"
    case .settings: return "Settings"
    }
  }

  var icon: String {
    switch self {
    case .home: return "house"
    case .contacts: return "person.2"
    case .settings: return "gearshape"
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
