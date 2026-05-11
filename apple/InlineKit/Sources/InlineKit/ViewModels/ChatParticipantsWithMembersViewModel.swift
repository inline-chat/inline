import Auth
import Combine
import GRDB
import Logger
import SwiftUI

/// Chat participants view model that falls back to space members for public threads
public final class ChatParticipantsWithMembersViewModel: ObservableObject {
  public enum Purpose: Sendable {
    case participantsList
    case mentionCandidates
  }

  private enum RefreshRequest {
    case none
    case participants
    case spaceMembers(Int64)
  }

  @Published public private(set) var participants: [UserInfo] = []

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

  private static func fetchAllKnownUsers(_ db: Database) throws -> [UserInfo] {
    try User
      .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      .asRequest(of: UserInfo.self)
      .fetchAll(db)
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
        let chat = try Chat.fetchOne(db, id: chatId)

        // DMs: mention candidates should only include the peer (not chat_participants).
        if let chat, chat.type == .privateChat, let peerUserId = chat.peerUserId {
          log.trace("DM chat, fetching peer user")
          let peer = try User
            .filter(Column("id") == peerUserId)
            .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
            .asRequest(of: UserInfo.self)
            .fetchOne(db)

          let users = peer.map { [$0] } ?? []
          return purpose == .mentionCandidates ? Self.filterMentionCandidates(users) : users
        }

        if let chat {
          if let spaceId = chat.spaceId {
            switch purpose {
            case .mentionCandidates:
              log.trace("Space thread, fetching space members for mention candidates")
              let spaceMembers = try Member
                .fullMemberQuery()
                .filter(Column("spaceId") == spaceId)
                .fetchAll(db)

              return Self.filterMentionCandidates(spaceMembers.map(\.userInfo))

            case .participantsList:
              if chat.isPublic == true {
                log.trace("Public space thread, fetching space members")
                let spaceMembers = try Member
                  .fullMemberQuery()
                  .filter(Column("spaceId") == spaceId)
                  .fetchAll(db)

                return spaceMembers.map(\.userInfo)
              }

              log.trace("Private space thread, fetching chat participants")
              return try ChatParticipant
                .including(
                  required: ChatParticipant.user
                    .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
                )
                .filter(Column("chatId") == chatId)
                .asRequest(of: UserInfo.self)
                .fetchAll(db)
            }
          }

          if purpose == .mentionCandidates {
            // Non-space threads: users use @mentions to add new participants, so show all known users.
            log.trace("Home thread mention candidates, fetching all known users")
            return Self.filterMentionCandidates(try Self.fetchAllKnownUsers(db))
          }

          log.trace("Home thread, fetching chat participants")
          let participants = try ChatParticipant
            .including(
              required: ChatParticipant.user
                .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
            )
            .filter(Column("chatId") == chatId)
            .asRequest(of: UserInfo.self)
            .fetchAll(db)

          return participants
        }

        if purpose == .mentionCandidates {
          log.trace("Missing chat, falling back to local users for mention candidates")
          return Self.filterMentionCandidates(try Self.fetchAllKnownUsers(db))
        }

        return []
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Failed to get enhanced chat participants: \(error)")
          }
        },
        receiveValue: { [weak self] participants in
          self?.log.trace("Updated participants: \(participants.count) users")
          self?.participants = participants
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
      case .participants:
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
      // First try to get chat participants
      try await Api.realtime.send(.getChatParticipants(chatID: chatId))

      // Also try to get space members if this is a space thread
      let chat = try? await db.reader.read { db in
        try Chat.fetchOne(db, id: chatId)
      }

      if let chat,
         let spaceId = chat.spaceId
      {
        if purpose == .mentionCandidates || chat.isPublic == true {
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
    guard let chat = try Chat.fetchOne(db, id: chatId) else {
      return .participants
    }

    if let spaceId = chat.spaceId, purpose == .mentionCandidates || chat.isPublic == true {
      let hasMembers = try Member
        .filter(Member.Columns.spaceId == spaceId)
        .limit(1)
        .fetchCount(db) > 0

      return hasMembers ? .none : .spaceMembers(spaceId)
    }

    let hasParticipants = try ChatParticipant
      .filter(ChatParticipant.Columns.chatId == chatId)
      .limit(1)
      .fetchCount(db) > 0

    return hasParticipants ? .none : .participants
  }
}
