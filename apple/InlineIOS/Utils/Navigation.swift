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
        case .alphaSheet: "alphaSheet"
        case let .chatInfo(chatItem): "chatInfo-\(chatItem.id)"
      }
    }
  }

  // MARK: - Published Properties

  @Published var activeSheet: Destination?
  @Published var activeDestination: Destination?
  @Published var selectedTab: TabItem = .chats

  // Navigation paths for each tab
  @Published var chatsPath: [Destination] = []
  @Published var archivedPath: [Destination] = []
  @Published var spacesPath: [Destination] = []

  // MARK: - Computed Properties

  var currentPath: [Destination] {
    switch selectedTab {
      case .chats: chatsPath
      case .archived: archivedPath
      case .spaces: spacesPath
    }
  }

  // MARK: - Navigation Actions

  init() {
    loadNavigationState()
  }

  // MARK: - View Builders

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

  // MARK: - Persistence

  func saveNavigationState() {
    let chatsPath_ = chatsPath
    let archivedPath_ = archivedPath
    let spacesPath_ = spacesPath
    let activeSheet_ = activeSheet
    let selectedTab_ = selectedTab

    Task.detached(priority: .background) {
      if let encodedChatsPath = try? JSONEncoder().encode(chatsPath_) {
        UserDefaults.standard.set(encodedChatsPath, forKey: "chatsPath")
      }
      if let encodedArchivedPath = try? JSONEncoder().encode(archivedPath_) {
        UserDefaults.standard.set(encodedArchivedPath, forKey: "archivedPath")
      }
      if let encodedSpacesPath = try? JSONEncoder().encode(spacesPath_) {
        UserDefaults.standard.set(encodedSpacesPath, forKey: "spacesPath")
      }
      if let encodedSheet = try? JSONEncoder().encode(activeSheet_) {
        UserDefaults.standard.set(encodedSheet, forKey: Self.sheetKey)
      }
      UserDefaults.standard.set(selectedTab_.rawValue, forKey: "selectedTab")
    }
  }

  func loadNavigationState() {
    if let chatsPathData = UserDefaults.standard.data(forKey: "chatsPath"),
       let decodedChatsPath = try? JSONDecoder().decode([Destination].self, from: chatsPathData)
    {
      chatsPath = decodedChatsPath
    }

    if let archivedPathData = UserDefaults.standard.data(forKey: "archivedPath"),
       let decodedArchivedPath = try? JSONDecoder().decode([Destination].self, from: archivedPathData)
    {
      archivedPath = decodedArchivedPath
    }

    if let spacesPathData = UserDefaults.standard.data(forKey: "spacesPath"),
       let decodedSpacesPath = try? JSONDecoder().decode([Destination].self, from: spacesPathData)
    {
      spacesPath = decodedSpacesPath
    }

    if let sheetData = UserDefaults.standard.data(forKey: Self.sheetKey),
       let decodedSheet = try? JSONDecoder().decode(Destination?.self, from: sheetData)
    {
      activeSheet = decodedSheet
    }

    if let tabRawValue = UserDefaults.standard.integer(forKey: "selectedTab") as Int?,
       let tab = TabItem(rawValue: tabRawValue)
    {
      selectedTab = tab
    }
  }

  // MARK: - Navigation Actions

  func push(_ destination: Destination) {
    switch destination {
      case .createSpace, .createThread, .alphaSheet:
        activeSheet = destination
      default:
        switch selectedTab {
          case .chats:
            if chatsPath.last == destination { return }
            chatsPath.append(destination)
          case .archived:
            if archivedPath.last == destination { return }
            archivedPath.append(destination)
          case .spaces:
            if spacesPath.last == destination { return }
            spacesPath.append(destination)
        }
        saveNavigationState()
    }
  }

  func navigateToChatFromNotification(peer: Peer) {
    if let spaceDestination = currentPath.first(where: { destination in
      if case .space = destination {
        return true
      }
      return false
    }) {
      if case let .space(id: spaceId) = spaceDestination {
        switch selectedTab {
          case .chats: chatsPath = [.space(id: spaceId)]
          case .archived: archivedPath = [.space(id: spaceId)]
          case .spaces: spacesPath = [.space(id: spaceId)]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          self.push(.chat(peer: peer))
        }
      }
    } else {
      popToRoot()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.push(.chat(peer: peer))
      }
    }
  }

  func popPush(_ destination: Destination) {
    activeDestination = destination
    switch selectedTab {
      case .chats: chatsPath = [destination]
      case .archived: archivedPath = [destination]
      case .spaces: spacesPath = [destination]
    }
    saveNavigationState()
  }

  func popToRoot() {
    DispatchQueue.main.async {
      switch self.selectedTab {
        case .chats: self.chatsPath = []
        case .archived: self.archivedPath = []
        case .spaces: self.spacesPath = []
      }
      self.activeSheet = nil
      self.saveNavigationState()
    }
  }

  func pop() {
    switch selectedTab {
      case .chats:
        guard !chatsPath.isEmpty else { return }
        withAnimation(.snappy) {
          chatsPath.removeLast()
          saveNavigationState()
        }
      case .archived:
        guard !archivedPath.isEmpty else { return }
        withAnimation(.snappy) {
          archivedPath.removeLast()
          saveNavigationState()
        }
      case .spaces:
        guard !spacesPath.isEmpty else { return }
        withAnimation(.snappy) {
          spacesPath.removeLast()
          saveNavigationState()
        }
    }
  }

  func dismissSheet() {
    activeSheet = nil
    saveNavigationState()
  }

  // MARK: - Tab Management

  func switchToTab(_ tab: TabItem) {
    selectedTab = tab
    saveNavigationState()
  }

  // MARK: - Reset

  func reset() {
    chatsPath = []
    archivedPath = []
    spacesPath = []
    activeSheet = nil
    activeDestination = .main
    selectedTab = .chats
    saveNavigationState()
  }
}
