import InlineKit
import SwiftUI

@MainActor
class Navigation: ObservableObject, @unchecked Sendable {
  static let shared = Navigation()

  // MARK: - Notification Names

  static let chatDeletedNotification = Notification.Name("chatDeletedNotification")

  // MARK: - Destinations

  nonisolated static let sheetKey = "persistedActiveSheet"
  nonisolated static let pathKey = "persistedNavigationPath"

  enum Destination: Identifiable, Hashable, Codable {
    case main
    case space(id: Int64)
    case chat(peer: Peer)
    case settings
    case createSpace
    case createThread(spaceId: Int64)
    case archivedChats
    case profile(userInfo: UserInfo)
    case alphaSheet
    case chatInfo(chatItem: SpaceChatItem)

    // MARK: - Identifiable Conformance

    var id: String {
      switch self {
        case .main: "main"
        case let .space(id): "space-\(id)"
        case let .chat(peer): "chat-\(peer.hashValue)"
        case .settings: "settings"
        case .createSpace: "createSpace"
        case let .createThread(spaceId): "createThread-\(spaceId)"
        case .archivedChats: "archivedChats"
        case let .profile(userInfo): "profile-\(userInfo.id)"
        case .alphaSheet: "alphaSheet"
        case let .chatInfo(chatItem): "chatInfo-\(chatItem.id)"
      }
    }
  }

  // MARK: - Published Properties

  @Published var navigationPath = NavigationPath()
  @Published var activeSheet: Destination?
  @Published var activeDestination: Destination?

  // MARK: - Computed Properties

  var currentStack: NavigationPath {
    navigationPath
  }

  var currentStackBinding: Binding<NavigationPath> {
    Binding(
      get: { self.navigationPath },
      set: { self.navigationPath = $0 }
    )
  }

  // MARK: - Navigation Actions

  init() {
    loadNavigationState()
  }

  // MARK: - Persistence

  @Published var pathComponents: [Destination] = [] {
    didSet {
      saveNavigationState()
    }
  }

  func saveNavigationState() {
    let pathComponents_ = pathComponents
    let activeSheet_ = activeSheet

    Task.detached(priority: .background) {
      if let encodedPath = try? JSONEncoder().encode(pathComponents_) {
        UserDefaults.standard.set(encodedPath, forKey: Self.pathKey)
      }
      if let encodedSheet = try? JSONEncoder().encode(activeSheet_) {
        UserDefaults.standard.set(encodedSheet, forKey: Self.sheetKey)
      }
    }
  }

  func loadNavigationState() {
    if let pathData = UserDefaults.standard.data(forKey: Self.pathKey),
       let decodedPath = try? JSONDecoder().decode([Destination].self, from: pathData)
    {
      pathComponents = decodedPath
    }

    if let sheetData = UserDefaults.standard.data(forKey: Self.sheetKey),
       let decodedSheet = try? JSONDecoder().decode(Destination?.self, from: sheetData)
    {
      activeSheet = decodedSheet
    }
  }

  // MARK: - Navigation Actions (updated to use pathComponents)

  func push(_ destination: Destination) {
    // TODO: Handle sheets in aother func
    switch destination {
      case .createSpace, .createThread, .profile, .alphaSheet:
        activeSheet = destination
      default:
        if pathComponents.last == destination {
          break
        } else {
          pathComponents.append(destination)
        }
    }
  }

  func popPush(_ destination: Destination) {
    activeDestination = destination
    pathComponents = [destination]
  }

  func popToRoot() {
    pathComponents = []
    activeSheet = nil
  }

  func pop() {
    guard !pathComponents.isEmpty else { return }
    withAnimation(.snappy) {
      pathComponents.removeLast()
    }
  }

  func dismissSheet() {
    activeSheet = nil
  }

  // MARK: - Reset

  func reset() {
    navigationPath = NavigationPath()
    activeSheet = nil
    activeDestination = .main
  }
}
