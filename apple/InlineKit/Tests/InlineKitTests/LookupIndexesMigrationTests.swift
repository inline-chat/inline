import Foundation
import GRDB
@testable import InlineKit
import Testing

@Suite("Lookup indexes and FTS text trigger migration")
struct LookupIndexesMigrationTests {
  private let migration = "lookup indexes and fts text trigger"
  /// The migration registered before this one.
  private let previousMigration = "dialog server read cursor"

  @Test("adds the lookup indexes, drops the duplicated full indexes, and runs after the read cursor")
  func indexes() throws {
    let database = AppDatabase.empty()
    let migrations = database.migrator.migrations
    let index = try #require(migrations.firstIndex(of: migration))
    #expect(migrations.firstIndex(of: previousMigration).map { $0 < index } == true)
    try database.dbWriter.read { db in
      let indexes = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
      for added in ["dialog_chatId_idx", "chat_parent_idx", "chat_peerUserId_idx", "member_spaceId_idx"] {
        #expect(indexes.contains(added), "missing \(added)")
      }
      for dropped in ["attachment_messageId_idx", "file_profileForUserId_idx"] {
        #expect(!indexes.contains(dropped), "still has \(dropped)")
      }
      let trigger = try #require(try String.fetchOne(
        db, sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = '__messageTextFts_au'"
      ))
      #expect(trigger.contains(#"AFTER UPDATE OF "text", "globalId""#))
    }
  }

  @Test("an existing database upgrades with its messages searchable, and only text edits touch the index")
  func upgradeKeepsSearchInSync() throws {
    var migrator = AppDatabase.empty().migrator
    migrator.eraseDatabaseOnSchemaChange = false
    let writer = try DatabaseQueue()
    try migrator.migrate(writer, upTo: previousMigration)
    try writer.write { db in
      try db.execute(sql: """
      INSERT INTO chat (id, date) VALUES (7, '2026-10-08 00:00:00');
      INSERT INTO message (messageId, chatId, peerThreadId, fromId, date, text)
      VALUES (1, 7, 7, NULL, '2026-10-08 00:00:00', 'alpha bravo');
      INSERT INTO message (messageId, chatId, peerThreadId, fromId, date, text)
      VALUES (2, 7, 7, NULL, '2026-10-08 00:00:00', 'charlie delta');
      """)
    }
    try migrator.migrate(writer)

    try writer.write { db in
      func matches(_ term: String) throws -> [Int64] {
        try Int64.fetchAll(
          db,
          sql: "SELECT rowid FROM messageTextFts WHERE messageTextFts MATCH ? ORDER BY rowid",
          arguments: [term]
        )
      }
      let first = try #require(try Int64.fetchOne(db, sql: "SELECT globalId FROM message WHERE messageId = 1"))
      #expect(try matches("alpha") == [first])

      // SQLite traces each trigger program it runs as "-- TRIGGER <name>".
      func firesTextTrigger(_ sql: String) throws -> Bool {
        var statements: [String] = []
        db.trace(options: .statement) { statements.append($0.description) }
        defer { db.trace(options: .statement, nil) }
        try db.execute(sql: sql)
        return statements.contains { $0.contains("__messageTextFts_au") }
      }

      // A status or revision update leaves the index alone and the row stays searchable.
      #expect(try !firesTextTrigger("UPDATE message SET status = 1, rev = rev + 1 WHERE messageId = 1"))
      #expect(try matches("alpha") == [first])

      // A text edit re-indexes.
      #expect(try firesTextTrigger("UPDATE message SET text = 'echo foxtrot' WHERE messageId = 1"))
      #expect(try matches("alpha").isEmpty)
      #expect(try matches("echo") == [first])

      // Inserts and deletes still sync through GRDB's own triggers.
      try db.execute(sql: "DELETE FROM message WHERE messageId = 2")
      #expect(try matches("charlie").isEmpty)
      // With rank 1 the check also compares the index against the message table.
      try db.execute(sql: "INSERT INTO messageTextFts(messageTextFts, rank) VALUES('integrity-check', 1)")
    }
  }

  @Test("chat list and reply-thread lookups use the new indexes")
  func plansUseIndexes() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.read { db in
      func plan(_ sql: String, _ arguments: StatementArguments = []) throws -> String {
        try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
          .map { $0["detail"] as String }
          .joined(separator: " | ")
      }
      let replyThreads = try plan(
        "SELECT * FROM chat WHERE parentChatId = ? AND parentMessageId IN (SELECT value FROM json_each(?))",
        [7, "[1,2]"]
      )
      #expect(replyThreads.contains("chat_parent_idx"), "\(replyThreads)")

      let dialogByChat = try plan("SELECT * FROM dialog WHERE chatId = ?", [7])
      #expect(dialogByChat.contains("dialog_chatId_idx"), "\(dialogByChat)")

      // The dropped full indexes: their partial `IS NOT NULL` twins serve the same lookups.
      for (sql, arguments, index) in [
        ("SELECT * FROM attachment WHERE messageId = ?", [7] as StatementArguments, "attachment_messageId_notnull_idx"),
        ("SELECT * FROM attachment WHERE messageId IN (SELECT value FROM json_each(?))", ["[1,2]"], "attachment_messageId_notnull_idx"),
        (
          "SELECT * FROM message LEFT JOIN attachment ON attachment.messageId = message.globalId WHERE message.chatId = ?",
          [7], "attachment_messageId_notnull_idx"
        ),
        ("SELECT * FROM file WHERE profileForUserId = ?", [7], "file_profileForUserId_notnull_idx"),
        ("SELECT * FROM file WHERE profileForUserId IN (SELECT value FROM json_each(?))", ["[1,2]"], "file_profileForUserId_notnull_idx"),
      ] {
        let detail = try plan(sql, arguments)
        #expect(detail.contains(index), "\(sql): \(detail)")
      }

      // The chat list joins dialogs by chat; without the index SQLite built an automatic one per read.
      var statements: [String] = []
      db.trace(options: .statement) { statements.append($0.expandedDescription) }
      _ = try ChatListDatabaseQuery.fetchSnapshots(
        db, spaceID: nil, includeSpaceChatsInHome: true, translationLanguage: "en"
      )
      db.trace(options: .statement, nil)
      let chatListSQL = try #require(statements.first { $0.contains(#""dialog"."id" AS "dialogID""#) })
      let chatList = try plan(chatListSQL)
      #expect(!chatList.contains("AUTOMATIC"), "\(chatList)")
    }
  }
}
