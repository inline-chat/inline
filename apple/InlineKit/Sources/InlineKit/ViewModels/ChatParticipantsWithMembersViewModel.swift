import Auth
import Combine
import GRDB
import Logger
import SwiftUI

/// Chat participants view model that falls back to space members for public threads
/// and parent participants for linked subthreads.
public final class ChatParticipantsWithMembersViewModel: ObservableObject {
  public enum Purpose: Sendable {
    case participantsList
    case mentionCandidates
  }

  private enum RefreshRequest {
    case none
    case participants(Int64)
    case spaceMembers(Int64)
  }

  private struct ParticipantsSnapshot {
    var participants: [UserInfo]
    var mentionCandidates: [MentionCompletionUser]
  }

  @Published public private(set) var participants: [UserInfo] = []
  @Published public private(set) var mentionCandidates: [MentionCompletionUser] = []

  private var participantsCancellable: AnyCancellable?
  private var spaceMembersCancellable: AnyCancellable?
  private let db: AppDatabase
  private let chatId: Int64
  private let purpose: Purpose
  private let log = Log.scoped("EnhancedChatParticipantsViewModel")

  public init(db: AppDatabase, chatId: Int64, purpose: Purpose = .participantsList) {
    self.db = db
    self.chatId = chatId
    self.purpose = purpose

    fetchParticipants()
  }

  private static func filterMentionCandidates(_ users: [UserInfo]) -> [UserInfo] {
    let currentUserId = Auth.shared.getCurrentUserId()
    return users.filter { userInfo in
      if userInfo.user.pendingSetup == true {
        return false
      }
      if let currentUserId {
        return userInfo.user.id != currentUserId
      }
      return true
    }
  }

  private static func uniqueUsers(_ users: [UserInfo]) -> [UserInfo] {
    var seen = Set<Int64>()
    return users.filter { seen.insert($0.id).inserted }
  }

  private static func userInfoRequest(_ userIds: [Int64]? = nil) -> QueryInterfaceRequest<UserInfo> {
    var request = User
      .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      .asRequest(of: UserInfo.self)

    if let userIds {
      request = request.filter(userIds.contains(Column("id")))
    }

    return request
  }

  private static func fetchUserInfos(_ db: Database, ids: [Int64]) throws -> [UserInfo] {
    guard !ids.isEmpty else { return [] }
    return try userInfoRequest(ids).fetchAll(db)
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

  private static func fetchDirectChatCandidates(_ db: Database) throws -> [MentionCompletionUser] {
    let chats = try Chat
      .filter(Chat.Columns.type == ChatType.privateChat.rawValue)
      .filter(Chat.Columns.peerUserId != nil)
      .filter(Chat.Columns.lastMsgId != nil)
      .filter(Chat.Columns.lastMsgId > 0)
      .fetchAll(db)

    let userInfos = try fetchUserInfos(db, ids: chats.compactMap(\.peerUserId))
    let usersById = Dictionary(uniqueKeysWithValues: userInfos.map { ($0.id, $0) })

    return chats.compactMap { chat in
      guard let peerUserId = chat.peerUserId,
            let userInfo = usersById[peerUserId]
      else {
        return nil
      }

      return MentionCompletionUser(userInfo: userInfo, source: .directChat, lastMsgId: chat.lastMsgId)
    }
  }

  private static func participantsSourceChat(_ db: Database, chatId: Int64, purpose: Purpose) throws -> Chat? {
    guard let chat = try Chat.fetchOne(db, id: chatId) else { return nil }
    return try participantsSourceChat(db, for: chat, purpose: purpose)
  }

  private static func participantsSourceChat(_ db: Database, for chat: Chat, purpose: Purpose) throws -> Chat {
    guard purpose == .participantsList else { return chat }

    // Linked reply threads inherit access from their parent, but for now this view
    // only displays the inherited parent participant set. TODO: expose parent +
    // child-direct participants separately so the UI can group inherited users
    // and safely manage direct reply-thread participants.
    var source = chat
    var seenIds: Set<Int64> = [chat.id]
    while let parentChatId = source.parentChatId, !seenIds.contains(parentChatId) {
      guard let parent = try Chat.fetchOne(db, id: parentChatId) else { break }
      source = parent
      seenIds.insert(parent.id)
    }

    return source
  }

  private func fetchParticipants() {
    let purpose = purpose
    let log = log

    log.trace("Fetching participants for chatId: \(chatId)")

    let chatId = chatId
    db.warnIfInMemoryDatabaseForObservation("ChatParticipantsWithMembersViewModel.participants")

    participantsCancellable = ValueObservation
      .tracking { db in
        // First, get the chat to check if it's a public thread
        let requestedChat = try Chat.fetchOne(db, id: chatId)
        let chat = try requestedChat.flatMap { try Self.participantsSourceChat(db, for: $0, purpose: purpose) }
        let sourceChatId = chat?.id ?? chatId
        let directChats = purpose == .mentionCandidates ? try Self.fetchDirectChatCandidates(db) : []

        func snapshot(
          participants: [UserInfo],
          spaceMembers: [UserInfo] = [],
          directChats: [MentionCompletionUser]
        ) -> ParticipantsSnapshot {
          let mentionParticipants = Self.filterMentionCandidates(participants)
          let mentionSpaceMembers = Self.filterMentionCandidates(spaceMembers)

          var mentionCandidates = mentionParticipants.map {
            MentionCompletionUser(userInfo: $0, source: .participant)
          }
          mentionCandidates.append(contentsOf: mentionSpaceMembers.map {
            MentionCompletionUser(userInfo: $0, source: .spaceMember)
          })
          mentionCandidates.append(contentsOf: directChats)

          let users: [UserInfo]
          if purpose == .mentionCandidates {
            users = Self.uniqueUsers(mentionParticipants + mentionSpaceMembers)
          } else {
            users = participants
          }

          return ParticipantsSnapshot(participants: users, mentionCandidates: mentionCandidates)
        }

        // DMs: mention candidates should only include the peer (not chat_participants).
        if let chat, chat.type == .privateChat, let peerUserId = chat.peerUserId {
          log.trace("DM chat, fetching peer user")
          let peer = try User
            .filter(Column("id") == peerUserId)
            .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
            .asRequest(of: UserInfo.self)
            .fetchOne(db)

          let users = peer.map { [$0] } ?? []
          let peerCandidates = users.map {
            MentionCompletionUser(userInfo: $0, source: .participant)
          }
          let candidates = purpose == .mentionCandidates ? directChats + peerCandidates : []
          return snapshot(participants: users, directChats: candidates)
        }

        if let chat {
          if let spaceId = chat.spaceId {
            switch purpose {
            case .mentionCandidates:
              log.trace("Space thread, fetching chat participants and space members for mention candidates")
              let participants = try Self.fetchChatParticipants(db, chatId: sourceChatId)
              let spaceMembers = try Self.fetchSpaceMembers(db, spaceId: spaceId)

              return snapshot(participants: participants, spaceMembers: spaceMembers, directChats: directChats)

            case .participantsList:
              if chat.isPublic == true {
                log.trace("Public space thread, fetching space members")
                let spaceMembers = try Self.fetchSpaceMembers(db, spaceId: spaceId)
                return snapshot(participants: spaceMembers, directChats: [])
              }

              log.trace("Private space thread, fetching chat participants")
              return snapshot(participants: try Self.fetchChatParticipants(db, chatId: sourceChatId), directChats: [])
            }
          }

          if purpose == .mentionCandidates {
            log.trace("Home thread mention candidates, fetching participants and direct chats")
            let participants = try Self.fetchChatParticipants(db, chatId: sourceChatId)
            return snapshot(participants: participants, directChats: directChats)
          }

          log.trace("Home thread, fetching chat participants")
          return snapshot(participants: try Self.fetchChatParticipants(db, chatId: sourceChatId), directChats: [])
        }

        if purpose == .mentionCandidates {
          log.trace("Missing chat, falling back to direct chat mention candidates")
          return snapshot(participants: [], directChats: directChats)
        }

        return snapshot(participants: [], directChats: [])
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
          self?.mentionCandidates = snapshot.mentionCandidates
        }
      )
  }

  public func refetchParticipants() async {
    await Self.refetchParticipants(db: db, chatId: chatId, purpose: purpose)
  }

  public static func ensureParticipantsLoaded(
    db: AppDatabase,
    chatId: Int64,
    purpose: Purpose = .participantsList
  ) async {
    let log = Log.scoped("EnhancedChatParticipantsViewModel")

    do {
      let request = try await db.reader.read { db in
        try refreshRequest(db, chatId: chatId, purpose: purpose)
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

  public static func refetchParticipants(
    db: AppDatabase,
    chatId: Int64,
    purpose: Purpose = .participantsList
  ) async {
    let log = Log.scoped("EnhancedChatParticipantsViewModel")
    log.trace("Refetching participants...")

    do {
      let source = try await db.reader.read { db in
        try participantsSourceChat(db, chatId: chatId, purpose: purpose)
      }
      let sourceChatId = source?.id ?? chatId

      // First try to get chat participants
      try await Api.realtime.send(.getChatParticipants(chatID: sourceChatId))

      // Also try to get space members if this is a space thread
      if let source,
         let spaceId = source.spaceId
      {
        if purpose == .mentionCandidates || source.isPublic == true {
          log.trace("Also fetching space members for space thread, spaceId: \(spaceId)")
          try await Api.realtime.send(.getSpaceMembers(spaceId: spaceId))
        }
      }

    } catch {
      log.error("Failed to refetch enhanced chat participants", error: error)
    }
  }

  private static func refreshRequest(
    _ db: Database,
    chatId: Int64,
    purpose: Purpose
  ) throws -> RefreshRequest {
    guard let chat = try participantsSourceChat(db, chatId: chatId, purpose: purpose) else {
      return .participants(chatId)
    }

    if let spaceId = chat.spaceId, purpose == .mentionCandidates || chat.isPublic == true {
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
