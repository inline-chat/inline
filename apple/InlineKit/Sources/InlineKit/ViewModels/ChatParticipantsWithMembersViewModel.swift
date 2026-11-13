import Auth
import Combine
import GRDB
import Logger
import SwiftUI

/// Chat participants view model that falls back to space members for public threads
/// and parent participants for subthreads. Mention candidates live in
/// `MentionCandidatesSource`.
public final class ChatParticipantsWithMembersViewModel: ObservableObject {
  private enum RefreshRequest {
    case none
    case participants(Int64)
    case spaceMembers(Int64)
  }

  private struct ParticipantsSnapshot {
    var participants: [UserInfo]
    var groupParticipants: [UserGroup]
    var effectiveUserIds: Set<Int64>
  }

  public struct EffectiveParticipantAccess: Sendable {
    public let sourceChat: Chat
    public let userIds: Set<Int64>
    public let groupIds: Set<Int64>
  }

  @Published public private(set) var participants: [UserInfo] = []
  @Published public private(set) var groupParticipants: [UserGroup] = []
  @Published public private(set) var effectiveUserIds: Set<Int64> = []

  private var participantsCancellable: AnyCancellable?
  private let db: AppDatabase
  private let chatId: Int64
  private let log = Log.scoped("EnhancedChatParticipantsViewModel")

  public init(db: AppDatabase, chatId: Int64) {
    self.db = db
    self.chatId = chatId

    fetchParticipants()
  }

  private static func fetchChatParticipants(_ db: Database, chatId: Int64) throws -> [UserInfo] {
    try ChatParticipant
      .including(
        required: ChatParticipant.user
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .filter(Column("chatId") == chatId)
      .asRequest(of: UserInfo.self)
      .fetchAll(db)
  }

  private static func fetchSpaceMembers(_ db: Database, spaceId: Int64) throws -> [UserInfo] {
    try Member
      .fullMemberQuery()
      .filter(Column("spaceId") == spaceId)
      .fetchAll(db)
      .map(\.userInfo)
  }

  private static func fetchChatParticipantGroups(_ db: Database, chatId: Int64) throws -> [UserGroup] {
    let groupIds = try ChatParticipantGroup
      .filter(ChatParticipantGroup.Columns.chatId == chatId)
      .fetchAll(db)
      .map(\.groupId)

    guard !groupIds.isEmpty else { return [] }

    return try UserGroup
      .filter(groupIds.contains(UserGroup.Columns.id))
      .order(UserGroup.Columns.name)
      .fetchAll(db)
  }

  private static func fetchGroupMemberIds(_ db: Database, groupIds: [Int64]) throws -> Set<Int64> {
    guard !groupIds.isEmpty else { return [] }

    let memberships = try UserGroupMember
      .filter(groupIds.contains(UserGroupMember.Columns.groupId))
      .fetchAll(db)
    guard !memberships.isEmpty else { return [] }

    let groups = try UserGroup
      .filter(groupIds.contains(UserGroup.Columns.id))
      .fetchAll(db)
    let spaceIdByGroupId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.spaceId) })
    let userIds = Set(memberships.map(\.userId))
    let spaceIds = Set(groups.map(\.spaceId))
    let members = try Member
      .filter(spaceIds.contains(Member.Columns.spaceId))
      .filter(userIds.contains(Member.Columns.userId))
      .fetchAll(db)
    let currentMemberships = Set(members.map { SpaceUserKey(spaceId: $0.spaceId, userId: $0.userId) })

    return Set(memberships.compactMap { membership in
      guard let spaceId = spaceIdByGroupId[membership.groupId],
            currentMemberships.contains(SpaceUserKey(spaceId: spaceId, userId: membership.userId))
      else {
        return nil
      }
      return membership.userId
    })
  }

  private struct SpaceUserKey: Hashable {
    let spaceId: Int64
    let userId: Int64
  }

  static func participantsSourceChat(_ db: Database, chatId: Int64) throws -> Chat? {
    guard let chat = try Chat.fetchOne(db, id: chatId) else { return nil }
    return try participantsSourceChat(db, for: chat)
  }

  static func participantsSourceChat(_ db: Database, for chat: Chat) throws -> Chat {
    // Every subthread inherits access from its top-level parent. Participant and
    // mention projections therefore use that same source instead of presenting
    // an empty child-local participant set on first open.
    try participantAccessChain(db, for: chat).last ?? chat
  }

  /// Resolves access already granted to a chat directly or by its top-level root.
  ///
  /// Mention autocomplete ranks these users first. Send-time mention handling uses
  /// the target's direct grants plus the server-defined root access mode: normal
  /// root grants, a DM peer, or eligible public members. Intermediate subthread
  /// grants do not propagate. A missing parent or cycle simply ends the chain.
  public static func effectiveParticipantAccess(
    _ db: Database,
    for chat: Chat
  ) throws -> EffectiveParticipantAccess {
    let chain = try participantAccessChain(db, for: chat)
    let sourceChat = chain.last ?? chat
    let isPublicRoot = sourceChat.type == .thread &&
      sourceChat.parentChatId == nil &&
      sourceChat.isPublic == true
    var directGrantChatIds: Set<Int64> = [chat.id]

    // Top-level chats always retain their own direct grants. An inherited
    // normal thread also contributes root grants, while inherited DM/public
    // roots use their dedicated access modes below.
    if sourceChat.id == chat.id || (sourceChat.type == .thread && !isPublicRoot) {
      directGrantChatIds.insert(sourceChat.id)
    }

    var userIds = Set(try ChatParticipant
      .filter(directGrantChatIds.contains(ChatParticipant.Columns.chatId))
      .fetchAll(db)
      .map(\.userId))

    let groupIds = Set(try ChatParticipantGroup
      .filter(directGrantChatIds.contains(ChatParticipantGroup.Columns.chatId))
      .fetchAll(db)
      .map(\.groupId))

    userIds.formUnion(try fetchGroupMemberIds(db, groupIds: Array(groupIds)))

    if sourceChat.type == .privateChat, let peerUserId = sourceChat.peerUserId {
      userIds.insert(peerUserId)
    }

    if isPublicRoot, let spaceId = sourceChat.spaceId {
      userIds.formUnion(try Member
        .filter(Member.Columns.spaceId == spaceId)
        .filter(Member.Columns.canAccessPublicChats == true)
        .fetchAll(db)
        .map(\.userId))
    }

    return EffectiveParticipantAccess(
      sourceChat: sourceChat,
      userIds: userIds,
      groupIds: groupIds
    )
  }

  private static func participantAccessChain(_ db: Database, for chat: Chat) throws -> [Chat] {
    var chain = [chat]
    var seenIds: Set<Int64> = [chat.id]
    var current = chat

    while let parentChatId = current.parentChatId, seenIds.insert(parentChatId).inserted {
      guard let parent = try Chat.fetchOne(db, id: parentChatId) else { break }
      chain.append(parent)
      current = parent
    }

    return chain
  }

  private func fetchParticipants() {
    let log = log

    log.trace("Fetching participants for chatId: \(chatId)")

    let chatId = chatId
    db.warnIfInMemoryDatabaseForObservation("ChatParticipantsWithMembersViewModel.participants")

    participantsCancellable = ValueObservation
      .tracking { db in
        let requestedChat = try Chat.fetchOne(db, id: chatId)
        let chat = try requestedChat.flatMap { try Self.participantsSourceChat(db, for: $0) }
        let sourceChatId = chat?.id ?? chatId

        func snapshot(participants: [UserInfo], groupParticipants: [UserGroup] = []) -> ParticipantsSnapshot {
          let groupMemberIds = (try? Self.fetchGroupMemberIds(db, groupIds: groupParticipants.map(\.id))) ?? []
          return ParticipantsSnapshot(
            participants: participants,
            groupParticipants: groupParticipants,
            effectiveUserIds: Set(participants.map(\.id)).union(groupMemberIds)
          )
        }

        guard let chat else { return snapshot(participants: []) }

        // DMs list only the peer, not chat_participants.
        if chat.type == .privateChat, let peerUserId = chat.peerUserId {
          let peer = try User
            .filter(Column("id") == peerUserId)
            .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
            .asRequest(of: UserInfo.self)
            .fetchOne(db)
          return snapshot(participants: peer.map { [$0] } ?? [])
        }

        if let spaceId = chat.spaceId, chat.isPublic == true {
          return snapshot(participants: try Self.fetchSpaceMembers(db, spaceId: spaceId))
        }

        return snapshot(
          participants: try Self.fetchChatParticipants(db, chatId: sourceChatId),
          groupParticipants: chat.spaceId == nil ? [] : try Self.fetchChatParticipantGroups(db, chatId: sourceChatId)
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Failed to get enhanced chat participants: \(error)")
          }
        },
        receiveValue: { [weak self] snapshot in
          self?.log.trace("Updated participants: \(snapshot.participants.count) users")
          self?.participants = snapshot.participants
          self?.groupParticipants = snapshot.groupParticipants
          self?.effectiveUserIds = snapshot.effectiveUserIds
        }
      )
  }

  public func refetchParticipants() async {
    await Self.refetchParticipants(db: db, chatId: chatId)
  }

  public static func ensureParticipantsLoaded(db: AppDatabase, chatId: Int64) async {
    let log = Log.scoped("EnhancedChatParticipantsViewModel")

    do {
      let request = try await db.reader.read { db in
        try refreshRequest(db, chatId: chatId)
      }

      switch request {
      case .none:
        return
      case let .participants(chatId):
        try await Api.realtime.send(.getChatParticipants(chatID: chatId))
      case let .spaceMembers(spaceId):
        try await Api.realtime.send(.getSpaceMembers(spaceId: spaceId))
      }
    } catch {
      log.error("Failed to ensure enhanced chat participants are loaded", error: error)
    }
  }

  public static func refetchParticipants(db: AppDatabase, chatId: Int64) async {
    let log = Log.scoped("EnhancedChatParticipantsViewModel")
    log.trace("Refetching participants...")

    let source: Chat?
    do {
      source = try await db.reader.read { db in
        try participantsSourceChat(db, chatId: chatId)
      }
    } catch {
      log.error("Failed to resolve the participants source chat", error: error)
      return
    }

    // Each request stands alone so one failure doesn't skip the rest.
    do {
      try await Api.realtime.send(.getChatParticipants(chatID: source?.id ?? chatId))
    } catch {
      log.error("Failed to refetch chat participants", error: error)
    }

    if let source, let spaceId = source.spaceId, source.isPublic == true {
      do {
        try await Api.realtime.send(.getSpaceMembers(spaceId: spaceId))
      } catch {
        log.error("Failed to refetch space members", error: error)
      }
    }
  }

  private static func refreshRequest(_ db: Database, chatId: Int64) throws -> RefreshRequest {
    guard let chat = try participantsSourceChat(db, chatId: chatId) else {
      return .participants(chatId)
    }

    if let spaceId = chat.spaceId, chat.isPublic == true {
      let hasMembers = try Member
        .filter(Member.Columns.spaceId == spaceId)
        .limit(1)
        .fetchCount(db) > 0

      return hasMembers ? .none : .spaceMembers(spaceId)
    }

    let hasParticipants = try ChatParticipant
      .filter(ChatParticipant.Columns.chatId == chat.id)
      .limit(1)
      .fetchCount(db) > 0

    return hasParticipants ? .none : .participants(chat.id)
  }
}
