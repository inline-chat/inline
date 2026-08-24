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
    let pendingGroupIds: Set<Int64>
    let reservedGroupIds: Set<Int64>
  }

  private struct Snapshot: Sendable {
    let chat: InlineKit.Chat
    let messageCount: Int
    let participantIds: Set<Int64>
    let groupParticipantIds: Set<Int64>
    let users: [UserInfo]
    let groups: [InlineKit.UserGroup]
  }

  private let dependencies: AppDependencies
  private weak var toolbarState: ChatToolbarState?
  private let log = Log.scoped("MentionedParticipantsAutoAdd", enableTracing: false)

  private var pendingUserIds: Set<Int64> = []
  private var pendingGroupIds: Set<Int64> = []

  init(dependencies: AppDependencies, toolbarState: ChatToolbarState?) {
    self.dependencies = dependencies
    self.toolbarState = toolbarState
  }

  func handle(
    entities: MessageEntities?,
    peer: InlineKit.Peer,
    chat: InlineKit.Chat?,
    completion: @escaping @MainActor @Sendable () -> Void
  ) {
    let mentionedUserIds = Self.mentionedUserIds(from: entities)
    let mentionedGroupIds = Self.mentionedGroupIds(from: entities)
    let previousPendingUserIds = pendingUserIds
    let previousPendingGroupIds = pendingGroupIds
    let reservedUserIds = mentionedUserIds.subtracting(previousPendingUserIds)
    let reservedGroupIds = mentionedGroupIds.subtracting(previousPendingGroupIds)
    guard !reservedUserIds.isEmpty || !reservedGroupIds.isEmpty else {
      completion()
      return
    }

    pendingUserIds.formUnion(reservedUserIds)
    pendingGroupIds.formUnion(reservedGroupIds)

    let request = Request(
      peer: peer,
      chat: chat,
      currentUserId: dependencies.auth.currentUserId,
      pendingUserIds: previousPendingUserIds,
      reservedUserIds: reservedUserIds,
      pendingGroupIds: previousPendingGroupIds,
      reservedGroupIds: reservedGroupIds
    )
    let database = dependencies.database

    Task.detached(priority: .userInitiated) { [weak self] in
      do {
        let snapshot = try await Self.snapshot(
          database: database,
          peer: request.peer,
          chat: request.chat,
          userIds: request.reservedUserIds,
          groupIds: request.reservedGroupIds
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
        let groupItems = Self.groupItems(
          for: request.reservedGroupIds.subtracting(snapshot.groupParticipantIds),
          from: snapshot.groups
        )
        let groupAction = Self.groupAction(for: groupItems, context: context)

        var releasedUserIds = request.reservedUserIds
        var releasedGroupIds = request.reservedGroupIds
        var promptItems: [MentionCompletionItem] = []
        switch action {
          case .none:
            break

          case let .autoAdd(userIds):
            let users = Self.userInfos(for: userIds, from: snapshot.users)
            await self?.autoAdd(Self.userItems(for: users), chatId: snapshot.chat.id)
            releasedUserIds.subtract(userIds)

          case let .prompt(userIds):
            let users = Self.userInfos(for: userIds, from: snapshot.users)
            promptItems.append(contentsOf: Self.userItems(for: users))
            releasedUserIds.subtract(userIds)
        }

        switch groupAction {
          case .none:
            break
          case let .autoAdd(items):
            await self?.autoAdd(items, chatId: snapshot.chat.id)
            releasedGroupIds.subtract(items.compactMap(\.group?.id))
          case let .prompt(items):
            promptItems.append(contentsOf: items)
            releasedGroupIds.subtract(items.compactMap(\.group?.id))
        }

        await self?.release(userIds: releasedUserIds, groupIds: releasedGroupIds)
        await completion()
        if !promptItems.isEmpty {
          await self?.prompt(promptItems)
        }
      } catch {
        await self?.fail(userIds: request.reservedUserIds, groupIds: request.reservedGroupIds, error: error)
        await completion()
      }
    }
  }

  @MainActor
  private func release(userIds: Set<Int64> = [], groupIds: Set<Int64> = []) {
    pendingUserIds.subtract(userIds)
    pendingGroupIds.subtract(groupIds)
  }

  @MainActor
  private func prompt(_ items: [MentionCompletionItem]) {
    toolbarState?.presentMentionParticipantPrompt(items: items)
  }

  @MainActor
  private func fail(userIds: Set<Int64>, groupIds: Set<Int64>, error: Error) {
    release(userIds: userIds, groupIds: groupIds)
    log.error("Failed to handle mentioned participants", error: error)
  }

  @MainActor
  private func autoAdd(
    _ items: [MentionCompletionItem],
    chatId: Int64
  ) async {
    var addedItems: [MentionCompletionItem] = []

    for item in items {
      do {
        switch item {
          case let .user(user):
            try await Api.realtime.send(
              .addChatParticipant(
                chatID: chatId,
                userID: user.userInfo.user.id
              )
            )
          case let .group(group):
            try await Api.realtime.send(
              .addChatParticipant(
                chatID: chatId,
                groupID: group.id
              )
            )
        }
        addedItems.append(item)
      } catch {
        log.error("Failed to add mentioned participant", error: error)
      }
    }

    guard !addedItems.isEmpty else { return }

    ToastCenter.shared.showSuccess(
      Self.addedToastMessage(for: addedItems),
      actionTitle: "Undo"
    ) { [weak self] in
      self?.remove(addedItems, chatId: chatId)
    }
  }

  @MainActor
  private func remove(_ items: [MentionCompletionItem], chatId: Int64) {
    Task {
      for item in items {
        do {
          switch item {
            case let .user(user):
              try await Api.realtime.send(
                .removeChatParticipant(
                  chatID: chatId,
                  userID: user.userInfo.user.id
                )
              )
            case let .group(group):
              try await Api.realtime.send(
                .removeChatParticipant(
                  chatID: chatId,
                  groupID: group.id
                )
              )
          }
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
    userIds: Set<Int64>,
    groupIds: Set<Int64>
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

      let groupParticipantIds = Set(try ChatParticipantGroup
        .filter(ChatParticipantGroup.Columns.chatId == chat.id)
        .fetchAll(db)
        .map(\.groupId))

      let users = try User
        .filter(ids: Array(userIds))
        .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        .asRequest(of: UserInfo.self)
        .fetchAll(db)

      let groups = try InlineKit.UserGroup
        .filter(Array(groupIds).contains(InlineKit.UserGroup.Columns.id))
        .fetchAll(db)

      return Snapshot(
        chat: chat,
        messageCount: messageCount,
        participantIds: participantIds,
        groupParticipantIds: groupParticipantIds,
        users: users,
        groups: groups
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

  nonisolated private static func mentionedGroupIds(from entities: MessageEntities?) -> Set<Int64> {
    guard let entities else { return [] }
    return Set(
      entities.entities.compactMap { entity in
        guard entity.type == .groupMention else { return nil }
        return entity.groupMention.groupID
      }
    ).filter { $0 != 0 }
  }

  nonisolated private static func userItems(for users: [UserInfo]) -> [MentionCompletionItem] {
    users.map {
      .user(MentionCompletionUser(userInfo: $0, source: .participant))
    }
  }

  nonisolated private static func groupItems(
    for groupIds: Set<Int64>,
    from groups: [InlineKit.UserGroup]
  ) -> [MentionCompletionItem] {
    let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    return groupIds.sorted().compactMap { groupId in
      groupsById[groupId].map(MentionCompletionItem.group)
    }
  }

  private enum GroupAction {
    case none
    case autoAdd([MentionCompletionItem])
    case prompt([MentionCompletionItem])
  }

  nonisolated private static func groupAction(
    for items: [MentionCompletionItem],
    context: MentionedParticipantAddContext,
    autoAddMessageLimit: Int = MentionedParticipantAddPolicy.defaultAutoAddMessageLimit
  ) -> GroupAction {
    guard !items.isEmpty else { return .none }
    guard context.chatType == .thread else { return .none }
    guard !context.isPublic else { return .none }
    guard context.currentUserId != nil else { return .none }

    if context.isReplyThread || context.messageCount < autoAddMessageLimit {
      return .autoAdd(items)
    }

    return .prompt(items)
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

  nonisolated private static func addedToastMessage(for items: [MentionCompletionItem]) -> String {
    switch items.count {
      case 1:
        "Added \(items[0].title)"
      case 2:
        "Added \(items[0].title) and \(items[1].title)"
      case 3:
        "Added \(items[0].title), \(items[1].title), and \(items[2].title)"
      default:
        "Added \(items[0].title), \(items[1].title), and \(items.count - 2) others"
    }
  }
}
