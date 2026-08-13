import InlineKit
import SwiftUI
import UIKit

typealias Router = NavigationModel<AppTab, Destination, Sheet>

enum AppNavigationRequest: Sendable {
  case chat(peer: Peer)
  case externalChat(peer: Peer, contextSpaceID: Int64?)
  case message(peer: Peer, messageID: Int64)

  var peer: Peer {
    switch self {
    case let .chat(peer), let .externalChat(peer, _), let .message(peer, _):
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
  private var nextRequestID: UInt64 = 0
  private var latestRequestID: UInt64 = 0
  private var requiredActivationOrder: UInt64?
  private var pendingRequest: (id: UInt64, request: AppNavigationRequest)?
  private var didObserveAccount = false
  private var accountUserID: Int64?

  func register(_ router: Router, sceneID: UUID, isActive: Bool, accountUserID: Int64?) {
    entries[sceneID] = Entry(router: router, activationOrder: 0, isActive: isActive)
    establishAccountIfNeeded(accountUserID)
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

  func hasActiveRouter() -> Bool {
    pruneReleasedRouters()
    return activeRouter != nil
  }

  /// Reserves ordering before notification context is resolved off the main actor.
  /// The last user-selected external target wins even if older database reads finish later.
  func reserveNavigation(waitForActivation: Bool) -> UInt64 {
    nextRequestID &+= 1
    latestRequestID = nextRequestID
    pendingRequest = nil
    requiredActivationOrder = waitForActivation ? nextActivationOrder &+ 1 : nil
    return latestRequestID
  }

  /// Handles one account boundary for every registered scene. Repeated SwiftUI
  /// observations of the same transition are ignored by matching the old account.
  func accountDidChange(from oldUserID: Int64?, to newUserID: Int64?) {
    if !didObserveAccount {
      didObserveAccount = true
      accountUserID = newUserID
      return
    }

    // Initial credential hydration is not an account transition. A prior
    // non-nil -> nil transition has already reset every scene before a new login.
    guard let oldUserID else {
      if accountUserID == nil {
        accountUserID = newUserID
      }
      return
    }
    guard oldUserID != newUserID, accountUserID == oldUserID else { return }

    resetForAccountChange(to: newUserID)
  }

  func navigate(_ request: AppNavigationRequest) {
    let requestID = reserveNavigation(waitForActivation: false)
    navigate(request, reservation: requestID)
  }

  @discardableResult
  func navigate(_ request: AppNavigationRequest, reservation requestID: UInt64) -> Bool {
    guard requestID == latestRequestID else { return false }
    pruneReleasedRouters()
    guard let router = activeRouter else {
      pendingRequest = (requestID, request)
      return true
    }
    pendingRequest = nil
    requiredActivationOrder = nil
    router.navigate(request)
    return true
  }

  /// Adds context only while a request is still waiting for an active scene.
  /// Once delivered, Home fallback remains stable instead of re-routing visibly.
  func updatePendingRequest(_ request: AppNavigationRequest, reservation requestID: UInt64) {
    guard requestID == latestRequestID,
          pendingRequest?.id == requestID
    else { return }
    pendingRequest = (requestID, request)
  }

  private var activeRouter: Router? {
    entries.values
      .filter { entry in
        guard entry.router != nil, entry.isActive else { return false }
        guard let requiredActivationOrder else { return true }
        return entry.activationOrder >= requiredActivationOrder
      }
      .max { $0.activationOrder < $1.activationOrder }?
      .router
  }

  private func deliverPendingRequestIfPossible() {
    guard let pendingRequest,
          pendingRequest.id == latestRequestID,
          let router = activeRouter
    else { return }
    self.pendingRequest = nil
    requiredActivationOrder = nil
    router.navigate(pendingRequest.request)
  }

  private func pruneReleasedRouters() {
    entries = entries.filter { $0.value.router != nil }
  }

  private func establishAccountIfNeeded(_ userID: Int64?) {
    if !didObserveAccount {
      didObserveAccount = true
      accountUserID = userID
    } else if accountUserID == nil, let userID {
      accountUserID = userID
    } else if let accountUserID, accountUserID != userID {
      // A scene can be recreated after an account transition while no scene was
      // alive to observe it. Reconcile before a pending old-account route delivers.
      resetForAccountChange(to: userID)
    }
  }

  private func resetForAccountChange(to userID: Int64?) {
    accountUserID = userID
    invalidatePendingNavigation()
    for entry in entries.values {
      entry.router?.reset()
    }
  }

  private func invalidatePendingNavigation() {
    nextRequestID &+= 1
    latestRequestID = nextRequestID
    pendingRequest = nil
    requiredActivationOrder = nil
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
  case externalChat(peer: Peer, contextSpaceID: Int64?)
  case chatMessage(peer: Peer, messageID: Int64)
  case chatInfo(chatItem: SpaceChatItem)
  case spaceSettings(spaceId: Int64)
  case spaceIntegrations(spaceId: Int64)
  case integrationOptions(spaceId: Int64, provider: String)
  case createSpaceChat
  case createThread(spaceId: Int64)
  case createSpace
}

struct LegacySpaceDestinationRedirect: View {
  let spaceID: Int64
  let onRedirect: (Int64) -> Void

  var body: some View {
    Color.clear
      .accessibilityHidden(true)
      .task {
        onRedirect(spaceID)
      }
  }
}

enum Sheet: SheetType, Codable {
  case createSpace

  case settings
  case connectors(callbackURL: String)

  case addMember(spaceId: Int64)
  case inviteToInline
  case members(spaceId: Int64)
  case chatInfo(chatItem: SpaceChatItem)
  var id: String {
    switch self {
    case .createSpace:
      "createSpace"

    case .settings:
      "settings"

    case let .connectors(callbackURL):
      "connectors_\(callbackURL)"

    case let .addMember(spaceId):
      "addMember_\(spaceId)"

    case .inviteToInline:
      "inviteToInline"

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
    case let .externalChat(peer, contextSpaceID):
      navigateFromExternalNotification(peer: peer, contextSpaceID: contextSpaceID)
    case let .message(peer, messageID):
      resignFirstResponderForExternalRoute()
      resetTransientPresentation()
      let targetTab = canonicalDeepLinkTab
      self[targetTab] = [.chatMessage(peer: peer, messageID: messageID)]
      selectedTab = targetTab
    }
  }

  func navigateFromExternalNotification(peer: Peer, contextSpaceID: Int64?) {
    let targetTab = selectedTab.experimentalHomeFallbackTab
    let destination = Destination.externalChat(peer: peer, contextSpaceID: contextSpaceID)

    // External navigation replaces the root stack and any covering sheet. Assign
    // the target path before switching tabs so no stale chat is presented between updates.
    resignFirstResponderForExternalRoute()
    resetTransientPresentation()
    guard selectedTab != targetTab || self[targetTab] != [destination] else { return }
    self[targetTab] = [destination]
    selectedTab = targetTab
  }

  func navigateFromNotification(peer: Peer) {
    resignFirstResponderForExternalRoute()
    resetTransientPresentation()
    let targetTab = canonicalDeepLinkTab

    // Keep external chat opens canonical: they belong to Inbox even when the
    // same peer happens to be visible through another tab's navigation path.
    if selectedTab == targetTab,
       let currentDestination = self[targetTab].last,
       currentDestination.chatPeer == peer {
      return
    }

    self[targetTab] = [.chat(peer: peer)]
    selectedTab = targetTab
  }

  private var canonicalDeepLinkTab: AppTab {
    switch selectedTab {
    case .archived, .chats, .spaces:
      .chats
    case .inbox, .allChats, .search:
      .inbox
    }
  }

  private func resignFirstResponderForExternalRoute() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }
}

extension Destination {
  var legacySpaceID: Int64? {
    if case let .space(id) = self {
      id
    } else {
      nil
    }
  }

  var chatPeer: Peer? {
    switch self {
    case let .chat(peer), let .externalChat(peer, _), let .chatMessage(peer, _):
      peer
    case .chats, .archived, .spaces, .space, .chatInfo, .spaceSettings,
         .spaceIntegrations, .integrationOptions, .createSpaceChat, .createThread, .createSpace:
      nil
    }
  }
}
