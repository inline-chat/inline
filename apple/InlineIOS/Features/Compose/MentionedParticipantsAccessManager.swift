import Auth
import GRDB
import InlineKit
import InlineProtocol
import Logger
import UIKit

private enum MentionedParticipantsAccessError: Error {
  case chatNotFound
}

@MainActor
final class MentionedParticipantsAccessManager {
  private struct Request: Sendable {
    let peer: InlineKit.Peer
    let chatId: Int64?
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

  private enum GroupAction {
    case none
    case autoAdd([MentionCompletionItem])
    case prompt([MentionCompletionItem])
  }

  private weak var composeView: ComposeView?
  private let log = Log.scoped("MentionedParticipantsAccess", enableTracing: false)
  private var pendingUserIds: Set<Int64> = []
  private var pendingGroupIds: Set<Int64> = []

  init(composeView: ComposeView) {
    self.composeView = composeView
  }

  func handle(entities: MessageEntities?, peer: InlineKit.Peer, chatId: Int64?) {
    let mentionedUserIds = Self.mentionedUserIds(from: entities)
    let mentionedGroupIds = Self.mentionedGroupIds(from: entities)
    let previousPendingUserIds = pendingUserIds
    let previousPendingGroupIds = pendingGroupIds
    let reservedUserIds = mentionedUserIds.subtracting(previousPendingUserIds)
    let reservedGroupIds = mentionedGroupIds.subtracting(previousPendingGroupIds)
    guard !reservedUserIds.isEmpty || !reservedGroupIds.isEmpty else { return }

    pendingUserIds.formUnion(reservedUserIds)
    pendingGroupIds.formUnion(reservedGroupIds)

    let request = Request(
      peer: peer,
      chatId: chatId,
      currentUserId: Auth.shared.getCurrentUserId(),
      pendingUserIds: previousPendingUserIds,
      reservedUserIds: reservedUserIds,
      pendingGroupIds: previousPendingGroupIds,
      reservedGroupIds: reservedGroupIds
    )
    let database = AppDatabase.shared

    Task.detached(priority: .userInitiated) { [weak self] in
      do {
        let snapshot = try await Self.snapshot(
          database: database,
          peer: request.peer,
          chatId: request.chatId,
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

        let userAction = MentionedParticipantAddPolicy.action(
          for: request.reservedUserIds,
          context: context
        )
        let groupItems = Self.groupItems(
          for: request.reservedGroupIds
            .subtracting(request.pendingGroupIds)
            .subtracting(snapshot.groupParticipantIds),
          from: snapshot.groups
        )
        let groupAction = Self.groupAction(for: groupItems, context: context)

        await self?.apply(
          userAction: userAction,
          groupAction: groupAction,
          snapshot: snapshot,
          reservedUserIds: request.reservedUserIds,
          reservedGroupIds: request.reservedGroupIds
        )
      } catch {
        await self?.fail(
          userIds: request.reservedUserIds,
          groupIds: request.reservedGroupIds,
          error: error
        )
      }
    }
  }

  private func apply(
    userAction: MentionedParticipantAddAction,
    groupAction: GroupAction,
    snapshot: Snapshot,
    reservedUserIds: Set<Int64>,
    reservedGroupIds: Set<Int64>
  ) async {
    var handledUserIds: Set<Int64> = []
    var handledGroupIds: Set<Int64> = []

    switch userAction {
      case .none:
        break
      case let .autoAdd(userIds):
        let items = Self.userItems(for: Self.userInfos(for: userIds, from: snapshot.users))
        await autoAdd(items, chatId: snapshot.chat.id)
        handledUserIds.formUnion(userIds)
      case let .prompt(userIds):
        let items = Self.userItems(for: Self.userInfos(for: userIds, from: snapshot.users))
        prompt(items, chatId: snapshot.chat.id)
        handledUserIds.formUnion(userIds)
    }

    switch groupAction {
      case .none:
        break
      case let .autoAdd(items):
        await autoAdd(items, chatId: snapshot.chat.id)
        handledGroupIds.formUnion(items.compactMap(\.group?.id))
      case let .prompt(items):
        prompt(items, chatId: snapshot.chat.id)
        handledGroupIds.formUnion(items.compactMap(\.group?.id))
    }

    release(
      userIds: reservedUserIds.subtracting(handledUserIds),
      groupIds: reservedGroupIds.subtracting(handledGroupIds)
    )
  }

  private func prompt(_ items: [MentionCompletionItem], chatId: Int64) {
    guard !items.isEmpty else { return }
    guard let composeView, let presenter = composeView.attachmentFlowPresenter() else {
      release(items: items)
      return
    }

    let alert = UIAlertController(
      title: Self.promptTitle(for: items),
      message: Self.promptMessage(for: items),
      preferredStyle: .actionSheet
    )
    alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.autoAdd(items, chatId: chatId)
        self?.release(items: items)
      }
    })
    alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { [weak self] _ in
      self?.release(items: items)
    })

    if let popover = alert.popoverPresentationController {
      popover.sourceView = composeView.sendButton
      popover.sourceRect = composeView.sendButton.bounds
    }

    presenter.present(alert, animated: true)
  }

  private func autoAdd(_ items: [MentionCompletionItem], chatId: Int64) async {
    var addedItems: [MentionCompletionItem] = []

    for item in items {
      do {
        switch item {
          case let .user(user):
            try await Api.realtime.send(
              .addChatParticipant(chatID: chatId, userID: user.userInfo.user.id)
            )
          case let .group(group):
            try await Api.realtime.send(
              .addChatParticipant(chatID: chatId, groupID: group.id)
            )
        }
        addedItems.append(item)
      } catch {
        log.error("Failed to add mentioned participant", error: error)
      }
    }

    guard !addedItems.isEmpty else { return }

    ToastManager.shared.showToast(
      Self.addedToastMessage(for: addedItems),
      type: .success,
      systemImage: "person.badge.plus",
      action: { [weak self] in
        self?.remove(addedItems, chatId: chatId)
      },
      actionTitle: "Undo"
    )
  }

  private func remove(_ items: [MentionCompletionItem], chatId: Int64) {
    Task { @MainActor in
      for item in items {
        do {
          switch item {
            case let .user(user):
              try await Api.realtime.send(
                .removeChatParticipant(chatID: chatId, userID: user.userInfo.user.id)
              )
            case let .group(group):
              try await Api.realtime.send(
                .removeChatParticipant(chatID: chatId, groupID: group.id)
              )
          }
        } catch {
          log.error("Failed to undo mentioned participant add", error: error)
          ToastManager.shared.showToast(
            "Failed to undo participant add",
            type: .error,
            systemImage: "exclamationmark.triangle.fill"
          )
          return
        }
      }
    }
  }

  private func release(userIds: Set<Int64> = [], groupIds: Set<Int64> = []) {
    pendingUserIds.subtract(userIds)
    pendingGroupIds.subtract(groupIds)
  }

  private func release(items: [MentionCompletionItem]) {
    release(
      userIds: Set(items.compactMap(\.userInfo?.user.id)),
      groupIds: Set(items.compactMap(\.group?.id))
    )
  }

  private func fail(userIds: Set<Int64>, groupIds: Set<Int64>, error: Error) {
    release(userIds: userIds, groupIds: groupIds)
    log.error("Failed to handle mentioned participants", error: error)
  }

  nonisolated private static func snapshot(
    database: AppDatabase,
    peer: InlineKit.Peer,
    chatId: Int64?,
    userIds: Set<Int64>,
    groupIds: Set<Int64>
  ) async throws -> Snapshot {
    try await database.reader.read { db in
      let resolvedChat: InlineKit.Chat?
      if let chatId {
        resolvedChat = try Chat.fetchOne(db, id: chatId)
      } else {
        resolvedChat = try Chat.getByPeerId(db: db, peerId: peer)
      }

      guard let chat = resolvedChat else {
        throw MentionedParticipantsAccessError.chatNotFound
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
    ).filter { $0 > 0 }
  }

  nonisolated private static func mentionedGroupIds(from entities: MessageEntities?) -> Set<Int64> {
    guard let entities else { return [] }
    return Set(
      entities.entities.compactMap { entity in
        guard entity.type == .groupMention else { return nil }
        return entity.groupMention.groupID
      }
    ).filter { $0 > 0 }
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

  nonisolated private static func userInfos(for userIds: [Int64], from users: [UserInfo]) -> [UserInfo] {
    let usersById = Dictionary(uniqueKeysWithValues: users.map { ($0.user.id, $0) })
    return userIds.map { userId in
      if let user = usersById[userId] {
        return user
      }

      return UserInfo(user: User(id: userId, email: nil, firstName: nil))
    }
  }

  nonisolated private static func promptTitle(for items: [MentionCompletionItem]) -> String {
    if items.count == 1 {
      return "Add \(items[0].title) to this thread?"
    }

    return "Add mentioned access?"
  }

  nonisolated private static func promptMessage(for items: [MentionCompletionItem]) -> String {
    if items.count == 1 {
      return "They will be able to access this private thread."
    }

    let names = items.prefix(3).map(\.title).joined(separator: ", ")
    if items.count <= 3 {
      return "\(names) will be able to access this private thread."
    }

    return "\(names), and \(items.count - 3) others will be able to access this private thread."
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
