import GRDB
import InlineKit
import InlineProtocol
import Logger

private enum MentionedParticipantsAutoAddError: Error {
  case chatNotFound
}

@MainActor
final class MentionedParticipantsAutoAddManager {
  private struct Request: Sendable {
    let peer: InlineKit.Peer
    let chat: InlineKit.Chat?
    let currentUserId: Int64?
    let pendingUserIds: Set<Int64>
    let reservedUserIds: Set<Int64>
  }

  private struct Snapshot: Sendable {
    let chat: InlineKit.Chat
    let messageCount: Int
    let participantIds: Set<Int64>
    let users: [UserInfo]
  }

  private let dependencies: AppDependencies
  private weak var toolbarState: ChatToolbarState?
  private let log = Log.scoped("MentionedParticipantsAutoAdd", enableTracing: false)

  private var pendingUserIds: Set<Int64> = []

  init(dependencies: AppDependencies, toolbarState: ChatToolbarState?) {
    self.dependencies = dependencies
    self.toolbarState = toolbarState
  }

  func handle(entities: MessageEntities?, peer: InlineKit.Peer, chat: InlineKit.Chat?) {
    let mentionedUserIds = Self.mentionedUserIds(from: entities)
    let previousPendingUserIds = pendingUserIds
    let reservedUserIds = mentionedUserIds.subtracting(previousPendingUserIds)
    guard !reservedUserIds.isEmpty else { return }

    pendingUserIds.formUnion(reservedUserIds)

    let request = Request(
      peer: peer,
      chat: chat,
      currentUserId: dependencies.auth.currentUserId,
      pendingUserIds: previousPendingUserIds,
      reservedUserIds: reservedUserIds
    )
    let database = dependencies.database

    Task.detached(priority: .userInitiated) { [weak self] in
      do {
        let snapshot = try await Self.snapshot(
          database: database,
          peer: request.peer,
          chat: request.chat,
          userIds: request.reservedUserIds
        )

        let context = MentionedParticipantAddContext(
          chatType: snapshot.chat.type,
          isPublic: snapshot.chat.isPublic == true,
          isReplyThread: snapshot.chat.isReplyThread,
          currentUserId: request.currentUserId,
          messageCount: snapshot.messageCount,
          participantIds: snapshot.participantIds,
          pendingUserIds: request.pendingUserIds
        )

        let action = MentionedParticipantAddPolicy.action(
          for: request.reservedUserIds,
          context: context
        )

        switch action {
          case .none:
            await self?.release(request.reservedUserIds)

          case let .autoAdd(userIds):
            let users = Self.userInfos(for: userIds, from: snapshot.users)
            await self?.autoAdd(users, chatId: snapshot.chat.id, reservedUserIds: request.reservedUserIds)

          case let .prompt(userIds):
            let users = Self.userInfos(for: userIds, from: snapshot.users)
            await self?.prompt(users, reservedUserIds: request.reservedUserIds)
        }
      } catch {
        await self?.fail(request.reservedUserIds, error: error)
      }
    }
  }

  @MainActor
  private func release(_ userIds: Set<Int64>) {
    pendingUserIds.subtract(userIds)
  }

  @MainActor
  private func prompt(_ users: [UserInfo], reservedUserIds: Set<Int64>) {
    release(reservedUserIds)
    toolbarState?.presentMentionParticipantPrompt(users: users)
  }

  @MainActor
  private func fail(_ userIds: Set<Int64>, error: Error) {
    release(userIds)
    log.error("Failed to handle mentioned participants", error: error)
  }

  @MainActor
  private func autoAdd(
    _ users: [UserInfo],
    chatId: Int64,
    reservedUserIds: Set<Int64>
  ) async {
    defer {
      pendingUserIds.subtract(reservedUserIds)
    }

    var addedUsers: [UserInfo] = []

    for user in users {
      do {
        try await Api.realtime.send(
          .addChatParticipant(
            chatID: chatId,
            userID: user.user.id
          )
        )
        addedUsers.append(user)
      } catch {
        log.error("Failed to add mentioned participant", error: error)
      }
    }

    guard !addedUsers.isEmpty else { return }

    ToastCenter.shared.showSuccess(
      Self.addedToastMessage(for: addedUsers),
      actionTitle: "Undo"
    ) { [weak self] in
      self?.remove(addedUsers, chatId: chatId)
    }
  }

  @MainActor
  private func remove(_ users: [UserInfo], chatId: Int64) {
    Task {
      for user in users {
        do {
          try await Api.realtime.send(
            .removeChatParticipant(
              chatID: chatId,
              userID: user.user.id
            )
          )
        } catch {
          log.error("Failed to undo mentioned participant add", error: error)
          ToastCenter.shared.showError("Failed to undo participant add")
          return
        }
      }
    }
  }

  nonisolated private static func snapshot(
    database: AppDatabase,
    peer: InlineKit.Peer,
    chat: InlineKit.Chat?,
    userIds: Set<Int64>
  ) async throws -> Snapshot {
    try await database.reader.read { db in
      let resolvedChat: InlineKit.Chat?
      if let chat {
        resolvedChat = chat
      } else {
        resolvedChat = try Chat.getByPeerId(db: db, peerId: peer)
      }

      guard let chat = resolvedChat else {
        throw MentionedParticipantsAutoAddError.chatNotFound
      }

      let messageCount = try Message
        .filter(Column("chatId") == chat.id)
        .fetchCount(db)

      let participantIds = Set(try ChatParticipant
        .filter(ChatParticipant.Columns.chatId == chat.id)
        .fetchAll(db)
        .map(\.userId))

      let users = try User
        .filter(ids: Array(userIds))
        .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        .asRequest(of: UserInfo.self)
        .fetchAll(db)

      return Snapshot(
        chat: chat,
        messageCount: messageCount,
        participantIds: participantIds,
        users: users
      )
    }
  }

  nonisolated private static func mentionedUserIds(from entities: MessageEntities?) -> Set<Int64> {
    guard let entities else { return [] }
    return Set(
      entities.entities.compactMap { entity in
        guard entity.type == .mention else { return nil }
        return entity.mention.userID
      }
    ).filter { $0 != 0 }
  }

  nonisolated private static func userInfos(for userIds: [Int64], from users: [UserInfo]) -> [UserInfo] {
    let usersById = Dictionary(uniqueKeysWithValues: users.map { ($0.user.id, $0) })
    return userIds.map { userId in
      if let user = usersById[userId] {
        return user
      }

      return UserInfo(user: User(id: userId, email: nil, firstName: nil))
    }
  }

  nonisolated private static func addedToastMessage(for users: [UserInfo]) -> String {
    switch users.count {
      case 1:
        "Added \(users[0].user.displayName)"
      case 2:
        "Added \(users[0].user.displayName) and \(users[1].user.displayName)"
      case 3:
        "Added \(users[0].user.displayName), \(users[1].user.displayName), and \(users[2].user.displayName)"
      default:
        "Added \(users[0].user.displayName), \(users[1].user.displayName), and \(users.count - 2) others"
    }
  }
}
