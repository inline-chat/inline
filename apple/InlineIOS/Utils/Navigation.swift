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
    case alphaSheet
    // FIXME: this shouldn't use the whole chat item bc all of it will be persisted
    case chatInfo(chatItem: SpaceChatItem)
    case spaceSettings(spaceId: Int64)
    case spaceIntegrations(spaceId: Int64)
    case integrationOptions(spaceId: Int64, provider: String)

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
        case .alphaSheet: "alphaSheet"
        case let .chatInfo(chatItem): "chatInfo-\(chatItem.id)"
        case let .spaceSettings(spaceId): "spaceSettings-\(spaceId)"
        case let .spaceIntegrations(spaceId): "spaceIntegrations-\(spaceId)"
        case let .integrationOptions(spaceId, provider): "integrationOptions-\(spaceId)-\(provider)"
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

  @ViewBuilder
  func destinationView(for destination: Destination) -> some View {
    switch destination {
      case let .chat(peer):
        ChatView(peer: peer)
      case let .space(id):
        SpaceView(spaceId: id)
      case .settings:
        SettingsView()
      case .main:
        HomeView()
      case .archivedChats:
        ArchivedChatsView()
      case .createSpace:
        CreateSpace()
      case let .createThread(spaceId):
        CreateChatIOSView(spaceId: spaceId)
      case .alphaSheet:
        AlphaSheet()
      case let .chatInfo(chatItem):
        ChatInfoView(chatItem: chatItem)
      case let .spaceSettings(spaceId):
        SpaceSettingsView(spaceId: spaceId)
      case let .spaceIntegrations(spaceId):
        SpaceIntegrationsView(spaceId: spaceId)
      case let .integrationOptions(spaceId, provider):
        IntegrationOptionsView(spaceId: spaceId, provider: provider)
    }
  }

  @ViewBuilder
  func sheetContent(for destination: Destination) -> some View {
    switch destination {
      case let .createThread(spaceId):
        CreateChatIOSView(spaceId: spaceId)
          .presentationCornerRadius(18)
      case .createSpace:
        CreateSpace()
          .presentationCornerRadius(18)
      case .alphaSheet:
        AlphaSheet()
      default:
        EmptyView()
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
      case .createSpace, .createThread, .alphaSheet:
        activeSheet = destination
      default:
        if pathComponents.last == destination {
          break
        } else {
          pathComponents.append(destination)
        }
    }
  }

  func navigateToChatFromNotification(peer: Peer) {
    // Check if user is already in the chat from the notification
    if let currentDestination = pathComponents.last,
       case let .chat(currentPeer) = currentDestination,
       currentPeer == peer
    {
      // User is already in the correct chat, no need to navigate
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      self.popToRoot()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.push(.chat(peer: peer))
      }
    }

    // if let spaceDestination = pathComponents.first(where: { destination in
    //   if case .space = destination {
    //     return true
    //   }
    //   return false
    // }) {
    //   if case let .space(id: spaceId) = spaceDestination {
    //     pathComponents = [.space(id: spaceId)]
    //     DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    //       self.push(.chat(peer: peer))
    //     }
    //   }
    // } else {
    //   popToRoot()
    //   DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
    //     self.push(.chat(peer: peer))
    //   }
    // }
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
