import InlineKit
import SwiftUI

@MainActor
class Navigation: ObservableObject, @unchecked Sendable {
  static let shared = Navigation()

  // MARK: - Destinations

  enum Destination: Identifiable, Hashable {
    case main
    case space(id: Int64)
    case chat(peer: Peer)
    case settings
    case contacts
    case createSpace
    case createDM
    case createThread(spaceId: Int64)

    // MARK: - Identifiable Conformance

    var id: String {
      switch self {
      case .main: return "main"
      case .space(let id): return "space-\(id)"
      case .chat(let peer): return "chat-\(peer.hashValue)"
      case .settings: return "settings"
      case .contacts: return "contacts"
      case .createSpace: return "createSpace"
      case .createDM: return "createDM"
      case .createThread(let spaceId): return "createThread-\(spaceId)"
      }
    }
  }

  // MARK: - Navigation State

  @Published private(set) var path = NavigationPath()
  @Published var activeSheet: Destination?
  @Published private(set) var activeDestination: Destination = .main

  // MARK: - Tab Navigation

  @Published var selectedTab: TabItem = .home
  @Published private var navigationStacks: [TabItem: NavigationPath] = [
    .home: NavigationPath(),
    .contacts: NavigationPath(),
    .settings: NavigationPath(),
  ]

  @Published var isTabBarVisible: Bool = true

  // MARK: - Navigation Actions

  func setToolbarVisibility(_ isTabBarVisible: Bool) {
    self.isTabBarVisible = isTabBarVisible
  }
  func push(_ destination: Destination) {
    switch destination {
    case .chat:
      isTabBarVisible = false
      activeDestination = destination
      navigationStacks[selectedTab]?.append(destination)
    case .createSpace, .createDM, .createThread:
      activeSheet = destination
    default:
      isTabBarVisible = true
      activeDestination = destination
      navigationStacks[selectedTab]?.append(destination)
    }
  }

  func popPush(_ destination: Destination) {
    activeDestination = destination
    navigationStacks[selectedTab] = NavigationPath()
    navigationStacks[selectedTab]?.append(destination)
  }

  func popToRoot() {
    navigationStacks[selectedTab] = NavigationPath()
    isTabBarVisible = true
  }

  func pop() {
    if let stack = navigationStacks[selectedTab], !stack.isEmpty {
      navigationStacks[selectedTab]?.removeLast()
      if stack.count <= 1 {
        isTabBarVisible = true
      }
    }
  }

  func dismissSheet() {
    activeSheet = nil
  }

  // MARK: - Reset

  func reset() {
    path = NavigationPath()
    activeSheet = nil
    activeDestination = .main
    selectedTab = .home
    navigationStacks = [
      .home: NavigationPath(),
      .contacts: NavigationPath(),
      .settings: NavigationPath(),
    ]
    isTabBarVisible = true
  }

  // MARK: - Navigation Stack Access

  var currentStack: NavigationPath {
    navigationStacks[selectedTab] ?? NavigationPath()
  }

  var currentStackBinding: Binding<NavigationPath> {
    Binding(
      get: { [weak self] in
        self?.navigationStacks[self?.selectedTab ?? .home] ?? NavigationPath()
      },
      set: { [weak self] newValue in
        guard let self = self else { return }
        self.navigationStacks[self.selectedTab] = newValue
      }
    )
  }
}
