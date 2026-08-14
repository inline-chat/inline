import Foundation
import GRDB

public struct CommandBarCatalogSnapshot: Sendable {
  public let chats: [HomeChatListItemSnapshot]
  public let knownUsers: [User]
  public let spaces: [Space]

  public init(chats: [HomeChatListItemSnapshot], knownUsers: [User] = [], spaces: [Space]) {
    self.chats = chats
    self.knownUsers = knownUsers
    self.spaces = spaces
  }
}

public extension AppDatabase {
  /// Fetches every local destination needed by CMD+K in one consistent database read.
  func fetchCommandBarCatalogSnapshot() async throws -> CommandBarCatalogSnapshot {
    try await reader.read { db in
      CommandBarCatalogSnapshot(
        chats: try CommandBarChatCatalogSnapshotQuery.fetchAll(db),
        knownUsers: try User.fetchAll(db),
        spaces: try Space.fetchAll(db)
      )
    }
  }

  /// Fetches the compact destination graph needed by CMD+K without hydrating message media,
  /// translations, documents, sender profiles, or other rich chat-list presentation state.
  func fetchCommandBarChatCatalogSnapshots() async throws -> [HomeChatListItemSnapshot] {
    try await reader.read { db in
      try CommandBarChatCatalogSnapshotQuery.fetchAll(db)
    }
  }
}

private enum CommandBarChatCatalogSnapshotQuery {
  static func fetchAll(_ db: Database) throws -> [HomeChatListItemSnapshot] {
    let dialogs = try Dialog
      .applyingChatListVisibilityFilter(Dialog.all())
      .fetchAll(db)
    guard dialogs.isEmpty == false else { return [] }

    let chatIDs = Set(dialogs.compactMap { $0.chatId ?? $0.peerThreadId })
    let chats = try fetch(Chat.self, ids: chatIDs, db: db)
    let chatsByID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })

    let userIDs = Set(dialogs.compactMap(\.peerUserId))
    let users = try fetch(User.self, ids: userIDs, db: db)
    let usersByID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, UserInfo(user: $0)) })

    let spaceIDs = Set(dialogs.compactMap { dialog in
      let chatID = dialog.chatId ?? dialog.peerThreadId
      return dialog.spaceId ?? chatID.flatMap { chatsByID[$0]?.spaceId }
    })
    let spaces = try fetch(Space.self, ids: spaceIDs, db: db)
    let spacesByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
    let lastMessageDates = try lastMessageDatesByChatID(chats: chats, db: db)

    let items = dialogs.compactMap { dialog -> HomeChatItem? in
      guard let chatID = dialog.chatId ?? dialog.peerThreadId,
            let chat = chatsByID[chatID]
      else { return nil }

      let user = dialog.peerUserId.flatMap { usersByID[$0] }
      let spaceID = dialog.spaceId ?? chat.spaceId
      return HomeChatItem(
        dialog: dialog,
        user: user,
        chat: chat,
        lastMessage: nil,
        space: spaceID.flatMap { spacesByID[$0] }
      )
    }

    let titles = try ReplyThreadTitleFallback.titlesByChatId(for: items, db: db)
    let parentTitles = try ReplyThreadTitleFallback.parentTitlesByChatId(for: items, db: db)
    let snapshots = items.map { item in
      HomeChatListItemSnapshot(
        item: item,
        titleOverride: item.chat.flatMap { titles[$0.id] },
        parentTitle: item.chat.flatMap { parentTitles[$0.id] },
        previewOverride: "",
        sortDateOverride: item.chat.flatMap { lastMessageDates[$0.id] ?? $0.date }
      )
    }
    .sorted(by: snapshotPrecedes)

    return snapshots.filter { $0.archived == false } + snapshots.filter(\.archived)
  }

  private static func fetch<Record: FetchableRecord & TableRecord & Identifiable>(
    _ type: Record.Type,
    ids: Set<Int64>,
    db: Database
  ) throws -> [Record] where Record.ID == Int64 {
    guard ids.isEmpty == false else { return [] }
    return try type
      .filter(ids.contains(Column("id")))
      .fetchAll(db)
  }

  private static func lastMessageDatesByChatID(
    chats: [Chat],
    db: Database
  ) throws -> [Int64: Date] {
    let chatIDs = chats.compactMap { $0.lastMsgId == nil ? nil : $0.id }
    guard chatIDs.isEmpty == false else { return [:] }

    var result: [Int64: Date] = [:]
    result.reserveCapacity(chatIDs.count)
    for offset in stride(from: 0, to: chatIDs.count, by: 500) {
      let chunk = Array(chatIDs[offset ..< min(offset + 500, chatIDs.count)])
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
      let rows = try Row.fetchAll(
        db,
        sql: """
        SELECT "chat"."id" AS "chatID", "message"."date" AS "messageDate"
        FROM "chat"
        JOIN "message"
          ON "message"."chatId" = "chat"."id"
          AND "message"."messageId" = "chat"."lastMsgId"
        WHERE "chat"."id" IN (\(placeholders))
        """,
        arguments: StatementArguments(chunk)
      )
      for row in rows {
        let chatID: Int64 = row["chatID"]
        let date: Date = row["messageDate"]
        result[chatID] = date
      }
    }
    return result
  }

  private static func snapshotPrecedes(
    _ lhs: HomeChatListItemSnapshot,
    _ rhs: HomeChatListItemSnapshot
  ) -> Bool {
    if lhs.pinned != rhs.pinned { return lhs.pinned }
    if lhs.pinned, rhs.pinned, lhs.id != rhs.id { return lhs.id > rhs.id }
    if lhs.sortDate != rhs.sortDate { return lhs.sortDate > rhs.sortDate }
    return lhs.id > rhs.id
  }
}
