import Foundation
import GRDB
import InlineProtocol
import Logger

extension InlineProtocol.UpdateClearChatHistory {
  @discardableResult
  func apply(_ db: Database) throws -> [Peer] {
    try apply(db, publishChanges: true)
  }

  @discardableResult
  func apply(_ db: Database, publishChanges: Bool) throws -> [Peer] {
    switch target {
      case let .peerID(peerID):
        return try applyPeer(db, peer: peerID.toPeer(), publishChanges: publishChanges)
      case let .spaceID(spaceID):
        return try applySpace(db, spaceId: spaceID, publishChanges: publishChanges)
      case nil:
        Log.shared.error("Clear history update missing target")
        return []
    }
  }

  private func applyPeer(_ db: Database, peer: Peer, publishChanges: Bool) throws -> [Peer] {
    guard let chat = try Chat.getByPeerId(db: db, peerId: peer) else {
      Log.shared.error("Failed to find chat for peer \(peer)")
      return []
    }

    let cutoffDate = hasBeforeDate ? Date(timeIntervalSince1970: TimeInterval(beforeDate)) : nil

    try Chat
      .filter(Chat.Columns.id == chat.id)
      .updateAll(db, [Chat.Columns.lastMsgId.set(to: nil)])

    if let cutoffDate {
      if deleteReplyThreads {
        try deleteReplyThreadsForClearedMessages(db, parentChatId: chat.id, cutoffDate: cutoffDate)
      } else {
        try orphanReplyThreadsForClearedMessages(db, parentChatId: chat.id, cutoffDate: cutoffDate)
      }

      try deletePinnedMessagesForClearedMessages(db, chatId: chat.id, cutoffDate: cutoffDate)
      try Message
        .filter(Message.Columns.chatId == chat.id)
        .filter(Message.Columns.date < cutoffDate)
        .deleteAll(db)
    } else {
      if deleteReplyThreads {
        try deleteReplyThreadsForClearedMessages(db, parentChatId: chat.id, cutoffDate: nil)
      } else {
        try Chat
          .filter(Chat.Columns.parentChatId == chat.id)
          .filter(Chat.Columns.parentMessageId != nil)
          .updateAll(db, [Chat.Columns.parentMessageId.set(to: nil)])
      }

      try PinnedMessage
        .filter(PinnedMessage.Columns.chatId == chat.id)
        .deleteAll(db)

      try Message
        .filter(Message.Columns.chatId == chat.id)
        .deleteAll(db)
    }

    let latestMessage = try Message
      .filter(Message.Columns.chatId == chat.id)
      .order(Message.Columns.messageId.desc)
      .fetchOne(db)

    var updatedChat = chat
    updatedChat.lastMsgId = latestMessage?.messageId
    try updatedChat.save(db)

    if var dialog = try Dialog.get(peerId: peer).fetchOne(db) {
      let readInboxMaxId = dialog.readInboxMaxId ?? 0
      let unreadCount = try Message
        .filter(Message.Columns.chatId == chat.id)
        .filter(Message.Columns.messageId > readInboxMaxId)
        .filter(Message.Columns.out == false)
        .fetchCount(db)

      dialog.unreadCount = unreadCount
      try dialog.update(db)
    }

    let sideEffectPeers = try applyServerSideEffects(db)
    let reloadPeers = uniquePeers([peer] + sideEffectPeers)

    if publishChanges {
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          for reloadPeer in reloadPeers {
            MessagesPublisher.shared.messagesReload(peer: reloadPeer, animated: false)
          }
        }
      }
    }

    return reloadPeers
  }

  private func applySpace(_ db: Database, spaceId: Int64, publishChanges: Bool) throws -> [Peer] {
    let affectedChatIds = try Chat
      .filter(Chat.Columns.spaceId == spaceId)
      .select(Chat.Columns.id)
      .asRequest(of: Int64.self)
      .fetchAll(db)

    let cutoffDate = hasBeforeDate ? Date(timeIntervalSince1970: TimeInterval(beforeDate)) : nil

    let detachedExternalChatIds = try detachExternalReplyThreadsForClearedSpaceMessages(
      db,
      spaceId: spaceId,
      cutoffDate: cutoffDate
    )

    if deleteReplyThreads {
      try deleteReplyThreadsForClearedSpaceMessages(db, spaceId: spaceId, cutoffDate: cutoffDate)
    } else {
      try orphanReplyThreadsForClearedSpaceMessages(db, spaceId: spaceId, cutoffDate: cutoffDate)
    }

    try Chat
      .filter(Chat.Columns.spaceId == spaceId)
      .updateAll(db, [Chat.Columns.lastMsgId.set(to: nil)])

    if let cutoffDate {
      let cutoffArguments: StatementArguments = [spaceId, cutoffDate]

      try db.execute(
        sql: """
        DELETE FROM pinnedMessage
        WHERE chatId IN (SELECT id FROM chat WHERE spaceId = ?)
          AND messageId IN (
            SELECT messageId FROM message
            WHERE message.chatId = pinnedMessage.chatId
              AND date < ?
          )
        """,
        arguments: cutoffArguments
      )

      try db.execute(
        sql: """
        DELETE FROM message
        WHERE chatId IN (SELECT id FROM chat WHERE spaceId = ?)
          AND date < ?
        """,
        arguments: cutoffArguments
      )
    } else {
      try db.execute(
        sql: """
        DELETE FROM pinnedMessage
        WHERE chatId IN (SELECT id FROM chat WHERE spaceId = ?)
        """,
        arguments: [spaceId]
      )

      try db.execute(
        sql: """
        DELETE FROM message
        WHERE chatId IN (SELECT id FROM chat WHERE spaceId = ?)
        """,
        arguments: [spaceId]
      )
    }

    try refreshSpaceLastMessageIds(db, spaceId: spaceId)
    try refreshSpaceUnreadCounts(db, spaceId: spaceId)

    let sideEffectPeers = try applyServerSideEffects(db)
    let reloadPeers = uniquePeers(
      (affectedChatIds + detachedExternalChatIds).map { .thread(id: $0) } + sideEffectPeers
    )

    if publishChanges {
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          for reloadPeer in reloadPeers {
            MessagesPublisher.shared.messagesReload(peer: reloadPeer, animated: false)
          }
        }
      }
    }

    return reloadPeers
  }

  private func applyServerSideEffects(_ db: Database) throws -> [Peer] {
    let deletedIds = uniqueIds(deletedChatIds)
    let deletedSet = Set(deletedIds)

    for chatId in deletedIds {
      try deleteLocalChat(db, chatId: chatId)
    }

    let orphanedIds = uniqueIds(orphanedChatIds).filter { !deletedSet.contains($0) }
    if !orphanedIds.isEmpty {
      try Chat
        .filter(orphanedIds.contains(Column("id")))
        .updateAll(db, [Chat.Columns.parentMessageId.set(to: nil)])
    }

    let detachedIds = uniqueIds(detachedChatIds).filter { !deletedSet.contains($0) }
    if !detachedIds.isEmpty {
      try Chat
        .filter(detachedIds.contains(Column("id")))
        .updateAll(db, [
          Chat.Columns.parentChatId.set(to: nil),
          Chat.Columns.parentMessageId.set(to: nil),
        ])
    }

    return uniqueIds(deletedIds + orphanedIds + detachedIds).map { .thread(id: $0) }
  }

  private func deleteReplyThreadsForClearedMessages(
    _ db: Database,
    parentChatId: Int64,
    cutoffDate: Date?
  ) throws {
    let anchorClause: String
    let arguments: StatementArguments
    if let cutoffDate {
      anchorClause = """
        AND EXISTS (
          SELECT 1
          FROM message m
          WHERE m.chatId = c.parentChatId
            AND m.messageId = c.parentMessageId
            AND m.date < ?
        )
      """
      arguments = [parentChatId, cutoffDate]
    } else {
      anchorClause = ""
      arguments = [parentChatId]
    }

    let rows = try Row.fetchAll(
      db,
      sql: """
      WITH RECURSIVE threads(chatId, depth) AS (
        SELECT c.id, 1
        FROM chat c
        WHERE c.parentChatId = ?
          AND c.parentMessageId IS NOT NULL
          \(anchorClause)

        UNION ALL

        SELECT c.id, threads.depth + 1
        FROM chat c
        JOIN threads ON c.parentChatId = threads.chatId
      )
      SELECT chatId
      FROM threads
      GROUP BY chatId
      ORDER BY max(depth) DESC, chatId DESC
      """,
      arguments: arguments
    )

    for row in rows {
      let chatId: Int64 = row["chatId"]
      try deleteLocalChat(db, chatId: chatId)
    }
  }

  private func orphanReplyThreadsForClearedMessages(
    _ db: Database,
    parentChatId: Int64,
    cutoffDate: Date?
  ) throws {
    if let cutoffDate {
      try db.execute(
        sql: """
        UPDATE chat
        SET parentMessageId = NULL
        WHERE parentChatId = ?
          AND parentMessageId IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM message m
            WHERE m.chatId = ?
              AND m.messageId = chat.parentMessageId
              AND m.date < ?
          )
        """,
        arguments: [parentChatId, parentChatId, cutoffDate]
      )
    } else {
      try Chat
        .filter(Chat.Columns.parentChatId == parentChatId)
        .filter(Chat.Columns.parentMessageId != nil)
        .updateAll(db, [Chat.Columns.parentMessageId.set(to: nil)])
    }
  }

  private func deletePinnedMessagesForClearedMessages(
    _ db: Database,
    chatId: Int64,
    cutoffDate: Date
  ) throws {
    try db.execute(
      sql: """
      DELETE FROM pinnedMessage
      WHERE chatId = ?
        AND EXISTS (
          SELECT 1
          FROM message m
          WHERE m.chatId = pinnedMessage.chatId
            AND m.messageId = pinnedMessage.messageId
            AND m.date < ?
        )
      """,
      arguments: [chatId, cutoffDate]
    )
  }

  private func deleteReplyThreadsForClearedSpaceMessages(
    _ db: Database,
    spaceId: Int64,
    cutoffDate: Date?
  ) throws {
    let anchorClause: String
    let arguments: StatementArguments
    if let cutoffDate {
      anchorClause = """
          AND EXISTS (
            SELECT 1
            FROM message m
            WHERE m.chatId = c.parentChatId
              AND m.messageId = c.parentMessageId
              AND m.date < ?
          )
      """
      arguments = [spaceId, spaceId, cutoffDate, spaceId]
    } else {
      anchorClause = ""
      arguments = [spaceId, spaceId, spaceId]
    }

    let rows = try Row.fetchAll(
      db,
      sql: """
      WITH RECURSIVE threads(chatId, depth) AS (
        SELECT c.id, 1
        FROM chat c
        WHERE c.spaceId = ?
          AND EXISTS (
            SELECT 1
            FROM chat parent
            WHERE parent.id = c.parentChatId
              AND parent.spaceId = ?
          )
          AND c.parentMessageId IS NOT NULL
          \(anchorClause)

        UNION ALL

        SELECT c.id, threads.depth + 1
        FROM chat c
        JOIN threads ON c.parentChatId = threads.chatId
        WHERE c.spaceId = ?
      )
      SELECT chatId
      FROM threads
      GROUP BY chatId
      ORDER BY max(depth) DESC, chatId DESC
      """,
      arguments: arguments
    )

    for row in rows {
      let chatId: Int64 = row["chatId"]
      try deleteLocalChat(db, chatId: chatId)
    }
  }

  private func orphanReplyThreadsForClearedSpaceMessages(
    _ db: Database,
    spaceId: Int64,
    cutoffDate: Date?
  ) throws {
    if let cutoffDate {
      let arguments: StatementArguments = [spaceId, spaceId, cutoffDate]

      try db.execute(
        sql: """
        UPDATE chat
        SET parentMessageId = NULL
        WHERE spaceId = ?
          AND parentMessageId IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM chat parent
            WHERE parent.id = chat.parentChatId
              AND parent.spaceId = ?
          )
          AND EXISTS (
            SELECT 1
            FROM message m
            WHERE m.chatId = chat.parentChatId
              AND m.messageId = chat.parentMessageId
              AND m.date < ?
          )
        """,
        arguments: arguments
      )
    } else {
      let arguments: StatementArguments = [spaceId, spaceId]

      try db.execute(
        sql: """
        UPDATE chat
        SET parentMessageId = NULL
        WHERE spaceId = ?
          AND parentMessageId IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM chat parent
            WHERE parent.id = chat.parentChatId
              AND parent.spaceId = ?
          )
        """,
        arguments: arguments
      )
    }
  }

  private func detachExternalReplyThreadsForClearedSpaceMessages(
    _ db: Database,
    spaceId: Int64,
    cutoffDate: Date?
  ) throws -> [Int64] {
    let selectSQL: String
    let arguments: StatementArguments

    if let cutoffDate {
      selectSQL = """
      SELECT chat.id
      FROM chat
      WHERE parentChatId IS NOT NULL
        AND parentMessageId IS NOT NULL
        AND (spaceId IS NULL OR spaceId != ?)
        AND EXISTS (
          SELECT 1
          FROM chat parent
          WHERE parent.id = chat.parentChatId
            AND parent.spaceId = ?
        )
        AND EXISTS (
          SELECT 1
          FROM message m
          WHERE m.chatId = chat.parentChatId
            AND m.messageId = chat.parentMessageId
            AND m.date < ?
        )
      """
      arguments = [spaceId, spaceId, cutoffDate]
    } else {
      selectSQL = """
      SELECT chat.id
      FROM chat
      WHERE parentChatId IS NOT NULL
        AND parentMessageId IS NOT NULL
        AND (spaceId IS NULL OR spaceId != ?)
        AND EXISTS (
          SELECT 1
          FROM chat parent
          WHERE parent.id = chat.parentChatId
            AND parent.spaceId = ?
        )
      """
      arguments = [spaceId, spaceId]
    }

    let chatIds = try Int64.fetchAll(db, sql: selectSQL, arguments: arguments)
    if chatIds.isEmpty {
      return []
    }

    if cutoffDate != nil {
      try db.execute(
        sql: """
        UPDATE chat
        SET parentChatId = NULL,
            parentMessageId = NULL
        WHERE parentChatId IS NOT NULL
          AND parentMessageId IS NOT NULL
          AND (spaceId IS NULL OR spaceId != ?)
          AND EXISTS (
            SELECT 1
            FROM chat parent
            WHERE parent.id = chat.parentChatId
              AND parent.spaceId = ?
          )
          AND EXISTS (
            SELECT 1
            FROM message m
            WHERE m.chatId = chat.parentChatId
              AND m.messageId = chat.parentMessageId
              AND m.date < ?
          )
        """,
        arguments: arguments
      )
    } else {
      try db.execute(
        sql: """
        UPDATE chat
        SET parentChatId = NULL,
            parentMessageId = NULL
        WHERE parentChatId IS NOT NULL
          AND parentMessageId IS NOT NULL
          AND (spaceId IS NULL OR spaceId != ?)
          AND EXISTS (
            SELECT 1
            FROM chat parent
            WHERE parent.id = chat.parentChatId
              AND parent.spaceId = ?
          )
        """,
        arguments: arguments
      )
    }

    return chatIds
  }

  private func deleteLocalChat(_ db: Database, chatId: Int64) throws {
    try Chat
      .filter(Chat.Columns.parentChatId == chatId)
      .updateAll(db, [
        Chat.Columns.parentChatId.set(to: nil),
        Chat.Columns.parentMessageId.set(to: nil),
      ])
    try Chat
      .filter(Chat.Columns.id == chatId)
      .updateAll(db, [Chat.Columns.lastMsgId.set(to: nil)])
    try Message.filter(Message.Columns.chatId == chatId).deleteAll(db)
    try Dialog.filter(Dialog.Columns.peerThreadId == chatId).deleteAll(db)
    try Dialog.filter(Dialog.Columns.chatId == chatId).deleteAll(db)
    try Chat.filter(Chat.Columns.id == chatId).deleteAll(db)
    try deleteChatSyncBucket(db, chatId: chatId)
  }

  private func refreshSpaceLastMessageIds(_ db: Database, spaceId: Int64) throws {
    try db.execute(
      sql: """
      UPDATE chat
      SET lastMsgId = (
        SELECT messageId
        FROM message
        WHERE message.chatId = chat.id
        ORDER BY messageId DESC
        LIMIT 1
      )
      WHERE spaceId = ?
      """,
      arguments: [spaceId]
    )
  }

  private func refreshSpaceUnreadCounts(_ db: Database, spaceId: Int64) throws {
    try db.execute(
      sql: """
      UPDATE dialog
      SET unreadCount = (
        SELECT COUNT(*)
        FROM message m
        WHERE m.chatId = dialog.chatId
          AND m.messageId > COALESCE(dialog.readInboxMaxId, 0)
          AND m.out = 0
      )
      WHERE chatId IN (SELECT id FROM chat WHERE spaceId = ?)
      """,
      arguments: [spaceId]
    )
  }

  private func uniqueIds(_ ids: [Int64]) -> [Int64] {
    var seen = Set<Int64>()
    return ids.filter { seen.insert($0).inserted }
  }

  private func uniquePeers(_ peers: [Peer]) -> [Peer] {
    var result: [Peer] = []
    for peer in peers where !result.contains(peer) {
      result.append(peer)
    }
    return result
  }
}
