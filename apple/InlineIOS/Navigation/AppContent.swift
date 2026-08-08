import InlineKit
import SwiftUI

typealias Router = NavigationModel<AppTab, Destination, Sheet>

enum AppNavigationRequest: Sendable {
  case chat(peer: Peer)
  case message(peer: Peer, messageID: Int64)

  var peer: Peer {
    switch self {
    case let .chat(peer), let .message(peer, _):
      peer
    }
  }
}

@MainActor
final class IOSSceneRouterRegistry {
  private struct Entry {
    weak var router: Router?
    var activationOrder: UInt64
    var isActive: Bool
  }

  private var entries: [UUID: Entry] = [:]
  private var nextActivationOrder: UInt64 = 0
  private var pendingRequest: AppNavigationRequest?

  func register(_ router: Router, sceneID: UUID, isActive: Bool) {
    entries[sceneID] = Entry(router: router, activationOrder: 0, isActive: isActive)
    if isActive {
      activate(sceneID)
    }
    deliverPendingRequestIfPossible()
  }

  func activate(_ sceneID: UUID) {
    guard var entry = entries[sceneID], entry.router != nil else { return }
    nextActivationOrder &+= 1
    entry.activationOrder = nextActivationOrder
    entry.isActive = true
    entries[sceneID] = entry
    deliverPendingRequestIfPossible()
  }

  func deactivate(_ sceneID: UUID) {
    guard var entry = entries[sceneID] else { return }
    entry.isActive = false
    entries[sceneID] = entry
  }

  func unregister(_ sceneID: UUID) {
    entries.removeValue(forKey: sceneID)
  }

  func navigate(_ request: AppNavigationRequest) {
    pruneReleasedRouters()
    guard let router = activeRouter else {
      pendingRequest = request
      return
    }
    router.navigate(request)
  }

  private var activeRouter: Router? {
    let liveEntries = entries.values.filter { $0.router != nil }
    return (liveEntries.filter(\.isActive).max { $0.activationOrder < $1.activationOrder }
      ?? liveEntries.max { $0.activationOrder < $1.activationOrder })?
      .router
  }

  private func deliverPendingRequestIfPossible() {
    guard let pendingRequest, let router = activeRouter else { return }
    self.pendingRequest = nil
    router.navigate(pendingRequest)
  }

  private func pruneReleasedRouters() {
    entries = entries.filter { $0.value.router != nil }
  }
}

enum AppTab: String, TabType, CaseIterable, Codable {
  case inbox, allChats, search
  case archived, chats, spaces

  var id: String { rawValue }
  var icon: String {
    switch self {
    case .inbox: "tray.full.fill"
    case .allChats: "bubble.left.and.bubble.right.fill"
    case .archived: "archivebox.fill"
    case .chats: "bubble.left.and.bubble.right.fill"
    case .search: "magnifyingglass"
    case .spaces: "building.2.fill"
    }
  }
}

extension AppTab {
  var currentChatsTab: AppTab {
    switch self {
    case .inbox, .allChats:
      self
    case .archived, .chats, .search, .spaces:
      .chats
    }
  }

  var experimentalHomeFallbackTab: AppTab {
    self == .inbox ? .inbox : .allChats
  }
}

enum Destination: DestinationType, Codable {
  case chats
  case archived
  case spaces
  case space(id: Int64)
  case chat(peer: Peer)
  case chatMessage(peer: Peer, messageID: Int64)
  case chatInfo(chatItem: SpaceChatItem)
  case spaceSettings(spaceId: Int64)
  case spaceIntegrations(spaceId: Int64)
  case integrationOptions(spaceId: Int64, provider: String)
  case createSpaceChat
  case createThread(spaceId: Int64)
  case createSpace
}

enum Sheet: SheetType, Codable {
  case createSpace

  case alphaSheet

  case settings

  case addMember(spaceId: Int64)
  case members(spaceId: Int64)
  case chatInfo(chatItem: SpaceChatItem)
  var id: String {
    switch self {
    case .createSpace:
      "createSpace"

    case .alphaSheet:
      "alphaSheet"

    case .settings:
      "settings"

    case let .addMember(spaceId):
      "addMember_\(spaceId)"

    case let .members(spaceId):
      "members_\(spaceId)"

    case let .chatInfo(chatItem):
      "chatInfo_\(chatItem.id)"
    }
  }
}

@MainActor
extension Router {
  func navigate(_ request: AppNavigationRequest) {
    switch request {
    case let .chat(peer):
      navigateFromNotification(peer: peer)
    case let .message(peer, messageID):
      selectedTab = .inbox
      self[.inbox] = [.chatMessage(peer: peer, messageID: messageID)]
    }
  }

  func navigateFromNotification(peer: Peer) {
    // Keep external chat opens canonical: they belong to Inbox even when the
    // same peer happens to be visible through another tab's navigation path.
    if selectedTab == .inbox,
       let currentDestination = self[.inbox].last,
       currentDestination.chatPeer == peer {
      return
    }

    selectedTab = .inbox
    self[.inbox] = [.chat(peer: peer)]
  }
}

extension Destination {
  var chatPeer: Peer? {
    switch self {
    case let .chat(peer), let .chatMessage(peer, _):
      peer
    case .chats, .archived, .spaces, .space, .chatInfo, .spaceSettings,
         .spaceIntegrations, .integrationOptions, .createSpaceChat, .createThread, .createSpace:
      nil
    }
  }
}
