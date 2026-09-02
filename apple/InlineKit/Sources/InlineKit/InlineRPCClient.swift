import Foundation
import InlineProtocol

public enum InlineRPCClientError: Error {
  case unexpectedResponse
}

/// Application-facing authenticated operations carried by the negotiated realtime session.
/// Public authentication and CDN traffic intentionally remain outside this boundary.
public actor InlineRPCClient {
  public static let shared = InlineRPCClient()

  public func createSpace(name: String) async throws -> InlineProtocol.CreateSpaceResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .createSpace,
      input: .createSpace(.with { $0.name = name })
    )
    guard case let .createSpace(result)? = response else { throw InlineRPCClientError.unexpectedResponse }
    return result
  }

  public func getMe() async throws -> InlineProtocol.GetMeResult {
    let response = try await Api.realtime.callRpcDirect(method: .getMe, input: .getMe(.init()))
    guard case let .getMe(result)? = response else { throw InlineRPCClientError.unexpectedResponse }
    return result
  }

  public func getChats() async throws -> InlineProtocol.GetChatsResult {
    let response = try await Api.realtime.callRpcDirect(method: .getChats, input: .getChats(.init()))
    guard case let .getChats(result)? = response else { throw InlineRPCClientError.unexpectedResponse }
    return result
  }

  public func getChat(peerID: Peer) async throws -> InlineProtocol.GetChatResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .getChat,
      input: .getChat(.with { $0.peerID = peerID.toInputPeer() })
    )
    guard case let .getChat(result)? = response else { throw InlineRPCClientError.unexpectedResponse }
    return result
  }

  public func getSpaceMembers(spaceID: Int64) async throws -> InlineProtocol.GetSpaceMembersResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .getSpaceMembers,
      input: .getSpaceMembers(.with { $0.spaceID = spaceID })
    )
    guard case let .getSpaceMembers(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result
  }

  public func getSpace(spaceID: Int64) async throws -> InlineProtocol.GetSpaceResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .getSpace,
      input: .getSpace(.with { $0.spaceID = spaceID })
    )
    guard case let .getSpace(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result
  }

  public func createThread(
    title: String,
    spaceID: Int64,
    emoji: String?
  ) async throws -> InlineProtocol.CreateChatResult {
    try await createChat(title: title, spaceID: spaceID, emoji: emoji)
  }

  public func searchUsers(query: String, limit: Int32 = 20) async throws -> [InlineProtocol.User] {
    let response = try await Api.realtime.callRpcDirect(
      method: .searchUsers,
      input: .searchUsers(.with {
        $0.query = query
        $0.limit = limit
      })
    )
    guard case let .searchUsers(result)? = response else { throw InlineRPCClientError.unexpectedResponse }
    return result.users
  }

  public func searchContacts(query: String) async throws -> SearchContacts {
    SearchContacts(users: try await searchUsers(query: query).map(ApiUser.init(from:)))
  }

  public func setProfilePhoto(fileUniqueID: String) async throws -> UpdateProfile {
    let response = try await Api.realtime.callRpcDirect(
      method: .setProfilePhoto,
      input: .setProfilePhoto(.with { $0.fileUniqueID = fileUniqueID })
    )
    guard case let .setProfilePhoto(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    await Api.realtime.applyUpdatesAndWait(result.updates)
    return UpdateProfile(user: ApiUser(from: result.user))
  }

  public func deleteMessageAttachment(
    peerID: Peer,
    messageID: Int64,
    attachmentID: Int64
  ) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .deleteMessageAttachment,
      input: .deleteMessageAttachment(.with {
        $0.peerID = peerID.toInputPeer()
        $0.messageID = messageID
        $0.attachmentID = attachmentID
      })
    )
    guard case let .deleteMessageAttachment(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    await Api.realtime.applyUpdatesAndWait(result.updates)
  }

  public func getChatHistory(peerID: Peer, limit: Int32 = 100) async throws -> InlineProtocol.GetChatHistoryResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .getChatHistory,
      input: .getChatHistory(.with {
        $0.peerID = peerID.toInputPeer()
        $0.limit = limit
        $0.mode = .historyModeLatest
      })
    )
    guard case let .getChatHistory(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result
  }

  public func inviteToSpace(spaceID: Int64, userID: Int64) async throws -> InlineProtocol.InviteToSpaceResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .inviteToSpace,
      input: .inviteToSpace(.with {
        $0.spaceID = spaceID
        $0.userID = userID
        $0.role = .with { $0.member = .with { $0.canAccessPublicChats = true } }
      })
    )
    guard case let .inviteToSpace(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result
  }

  public func deleteMessage(peerID: Peer, messageID: Int64) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .deleteMessages,
      input: .deleteMessages(.with {
        $0.peerID = peerID.toInputPeer()
        $0.messageIds = [messageID]
      })
    )
    guard case let .deleteMessages(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    await Api.realtime.applyUpdatesAndWait(result.updates)
  }

  public func addReaction(peerID: Peer, messageID: Int64, emoji: String) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .addReaction,
      input: .addReaction(.with {
        $0.peerID = peerID.toInputPeer()
        $0.messageID = messageID
        $0.emoji = emoji
      })
    )
    guard case let .addReaction(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    await Api.realtime.applyUpdatesAndWait(result.updates)
  }

  public func deleteSpace(spaceID: Int64) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .deleteSpace,
      input: .deleteSpace(.with { $0.spaceID = spaceID })
    )
    guard case .deleteSpace? = response else { throw InlineRPCClientError.unexpectedResponse }
  }

  public func leaveSpace(spaceID: Int64) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .leaveSpace,
      input: .leaveSpace(.with { $0.spaceID = spaceID })
    )
    guard case .leaveSpace? = response else { throw InlineRPCClientError.unexpectedResponse }
  }

  public func logout(timeout: Duration? = .seconds(15)) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .logOut,
      input: .logOut(.init()),
      timeout: timeout
    )
    guard case let .logOut(result)? = response, result.loggedOut else {
      throw InlineRPCClientError.unexpectedResponse
    }
  }

  public func updateSession(
    timeZone: String? = nil,
    deviceName: String? = nil,
    clientVersion: String? = nil,
    osVersion: String? = nil
  ) async throws -> InlineProtocol.AccountSession {
    let response = try await Api.realtime.callRpcDirect(
      method: .updateSession,
      input: .updateSession(.with {
        if let timeZone { $0.timeZone = timeZone }
        if let deviceName { $0.deviceName = deviceName }
        if let clientVersion { $0.clientVersion = clientVersion }
        if let osVersion { $0.osVersion = osVersion }
      })
    )
    guard case let .updateSession(result)? = response, result.hasSession else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result.session
  }

  public func updateDialogArchived(peerID: Peer, archived: Bool) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .updateDialogArchived,
      input: .updateDialogArchived(.with {
        $0.peerID = peerID.toInputPeer()
        $0.archived = archived
      })
    )
    guard case let .updateDialogArchived(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    await Api.realtime.applyUpdatesAndWait(result.updates)
  }

  public func updateDialogOrder(
    peerID: Peer,
    pinned: Bool?,
    order: String?,
    pinnedOrder: String?
  ) async throws -> InlineProtocol.UpdateDialogOrderResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .updateDialogOrder,
      input: .updateDialogOrder(.with {
        $0.peerID = peerID.toInputPeer()
        if let pinned { $0.pinned = pinned }
        if let order { $0.order = order }
        if let pinnedOrder { $0.pinnedOrder = pinnedOrder }
      })
    )
    guard case let .updateDialogOrder(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result
  }

  public func integrations(userID: Int64, spaceID: Int64? = nil) async throws -> GetIntegrations {
    let response = try await Api.realtime.callRpcDirect(
      method: .listConnectors,
      input: .listConnectors(.init())
    )
    guard case let .listConnectors(result)? = response else { throw InlineRPCClientError.unexpectedResponse }

    let matchingConnections = result.connections.filter { connection in
      guard connection.hasScope else { return false }
      guard let spaceID else { return true }
      guard case let .space(scope)? = connection.scope.type else { return false }
      return scope.hasSpace && scope.space.id == spaceID
    }
    let notionConnections = matchingConnections.filter { $0.provider == .notion }
    let linearConnections = matchingConnections.filter { $0.provider == .linear }

    var notionDatabaseID: String?
    var linearTeamID: String?
    if let spaceID {
      if !notionConnections.isEmpty {
        notionDatabaseID = try await connectorConfig(provider: .notion, spaceID: spaceID).selectedID
      }
      if !linearConnections.isEmpty {
        linearTeamID = try await connectorConfig(provider: .linear, spaceID: spaceID).selectedID
      }
    }

    return GetIntegrations(
      hasLinearConnected: !linearConnections.isEmpty,
      hasNotionConnected: !notionConnections.isEmpty,
      hasIntegrationAccess: !matchingConnections.isEmpty,
      linearTeamId: linearTeamID,
      notionDatabaseId: notionDatabaseID,
      notionSpaces: integrationSpaces(from: notionConnections).map {
        NotionSpace(spaceId: $0.id, spaceName: $0.name)
      },
      linearSpaces: integrationSpaces(from: linearConnections).map {
        LinearSpace(spaceId: $0.id, spaceName: $0.name)
      }
    )
  }

  public func notionDatabases(spaceID: Int64) async throws -> [NotionSimplifiedDatabase] {
    let result = try await connectorConfig(provider: .notion, spaceID: spaceID)
    return result.options.map {
      NotionSimplifiedDatabase(id: $0.id, title: $0.title, icon: $0.hasSubtitle ? $0.subtitle : nil)
    }
  }

  public func linearTeams(spaceID: Int64) async throws -> [LinearTeam] {
    let result = try await connectorConfig(provider: .linear, spaceID: spaceID)
    return result.options.map {
      LinearTeam(id: $0.id, name: $0.title, key: $0.hasSubtitle ? $0.subtitle : "")
    }
  }

  public func setNotionDatabase(spaceID: Int64, databaseID: String) async throws {
    try await setConnectorConfig(provider: .notion, spaceID: spaceID, selectedID: databaseID)
  }

  public func setLinearTeam(spaceID: Int64, teamID: String) async throws {
    try await setConnectorConfig(provider: .linear, spaceID: spaceID, selectedID: teamID)
  }

  public func disconnect(provider: String, spaceID: Int64) async throws {
    guard let provider = ConnectorKind(rawValue: provider) else { throw InlineRPCClientError.unexpectedResponse }
    let response = try await Api.realtime.callRpcDirect(
      method: .disconnectConnector,
      input: .disconnectConnector(.with {
        $0.provider = provider.protocolValue
        $0.scope = Self.spaceScope(spaceID)
      })
    )
    guard case .disconnectConnector? = response else { throw InlineRPCClientError.unexpectedResponse }
  }

  public func createNotionTask(spaceID: Int64, messageID: Int64, peerID: Peer) async throws -> NotionTaskResult {
    let result = try await createExternalTask(
      provider: .notion,
      spaceID: spaceID,
      messageID: messageID,
      peerID: peerID
    )
    return NotionTaskResult(url: result.url, taskTitle: "")
  }

  public func createLinearIssue(spaceID: Int64, messageID: Int64, peerID: Peer) async throws -> CreateLinearIssue {
    let result = try await createExternalTask(
      provider: .linear,
      spaceID: spaceID,
      messageID: messageID,
      peerID: peerID
    )
    return CreateLinearIssue(link: result.url)
  }

  private func connectorConfig(
    provider: InlineProtocol.ConnectorProvider,
    spaceID: Int64
  ) async throws -> InlineProtocol.GetConnectorConfigResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .getConnectorConfig,
      input: .getConnectorConfig(.with {
        $0.provider = provider
        $0.scope = Self.spaceScope(spaceID)
      })
    )
    guard case let .getConnectorConfig(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result
  }

  private func createChat(
    title: String?,
    spaceID: Int64?,
    emoji: String?
  ) async throws -> InlineProtocol.CreateChatResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .createChat,
      input: .createChat(.with {
        if let title { $0.title = title }
        if let spaceID { $0.spaceID = spaceID }
        if let emoji { $0.emoji = emoji }
        $0.isPublic = true
      })
    )
    guard case let .createChat(result)? = response else { throw InlineRPCClientError.unexpectedResponse }
    return result
  }

  private func setConnectorConfig(
    provider: InlineProtocol.ConnectorProvider,
    spaceID: Int64,
    selectedID: String
  ) async throws {
    let response = try await Api.realtime.callRpcDirect(
      method: .setConnectorConfig,
      input: .setConnectorConfig(.with {
        $0.provider = provider
        $0.scope = Self.spaceScope(spaceID)
        $0.selectedID = selectedID
      })
    )
    guard case .setConnectorConfig? = response else { throw InlineRPCClientError.unexpectedResponse }
  }

  private func createExternalTask(
    provider: InlineProtocol.ConnectorProvider,
    spaceID: Int64,
    messageID: Int64,
    peerID: Peer
  ) async throws -> InlineProtocol.CreateExternalTaskResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .createExternalTask,
      input: .createExternalTask(.with {
        $0.provider = provider
        $0.scope = Self.spaceScope(spaceID)
        $0.peerID = peerID.toInputPeer()
        $0.messageID = messageID
      })
    )
    guard case let .createExternalTask(result)? = response else {
      throw InlineRPCClientError.unexpectedResponse
    }
    return result
  }

  private static func spaceScope(_ spaceID: Int64) -> InlineProtocol.InputScope {
    .with { $0.space = .with { $0.spaceID = spaceID } }
  }

  private func integrationSpaces(
    from connections: [InlineProtocol.ConnectorConnection]
  ) -> [(id: Int64, name: String)] {
    var seen = Set<Int64>()
    return connections.compactMap { connection in
      guard case let .space(scope)? = connection.scope.type, scope.hasSpace else { return nil }
      let space = scope.space
      guard seen.insert(space.id).inserted else { return nil }
      return (space.id, space.name)
    }
  }
}
