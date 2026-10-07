import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Catalog history admission fences")
struct GetChatsHistoryFenceTests {
  @Test(
    "a live space clear fences a previously dispatched catalog for an uncached chat",
    arguments: [false, true]
  )
  func liveSpaceClearColdCatalogFence(hasCachedChat: Bool) throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try Space(id: 4, name: "Space", date: Date(timeIntervalSince1970: 1)).insert(db)
      if hasCachedChat {
        try Chat(id: 11, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Warm", spaceId: 4).insert(db)
        var warm = Message(
          messageId: 70,
          fromId: 1,
          date: Date(timeIntervalSince1970: 1),
          text: "old",
          peerUserId: nil,
          peerThreadId: 11,
          chatId: 11
        )
        try warm.saveMessage(db)
        try Chat.filter(Chat.Columns.id == 11).updateAll(db, Chat.Columns.lastMsgId.set(to: 70))
      }
      let revision = try SyncRemovalRevision.read(db)
      let dispatched = GetChatsTransaction.Context(expectedRemovalRevision: revision)
      var staleCatalog = page()
      staleCatalog.chats[0].spaceID = 4
      let clear = InlineProtocol.UpdateClearChatHistory.with { $0.spaceID = 4 }
      _ = try clear.apply(db, publishChanges: false)
      #expect(try SyncRemovalRevision.read(db) > revision)

      let imported = try GetChatsTransaction.applyCatalog(
        staleCatalog, context: dispatched, allowedChatIDs: [10], in: db
      )
      #expect(try Chat.fetchOne(db, id: 10)?.spaceId == 4)
      #expect(try Chat.fetchOne(db, id: 10)?.lastMsgId == nil)
      #expect(try Message.fetchCount(db) == 0)
      #expect(try Int64
        .fetchOne(db, sql: "SELECT seq FROM sync_bucket_state WHERE bucketType = 1 AND entityId = -10") == nil)
      #expect(imported.seededStates.isEmpty)
      for scope in MessageHistoryScope.allCases {
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 10, scope: scope).count == 1)
      }
    }
  }

  @Test("a compatibility peer clear of an absent root fences cold catalog bootstrap")
  func missingPeerClearColdCatalogFence() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      let revision = try SyncRemovalRevision.read(db)
      let dispatched = GetChatsTransaction.Context(expectedRemovalRevision: revision)
      let clear = InlineProtocol.UpdateClearChatHistory.with { $0.peerID.chat.chatID = 10 }
      _ = try clear.apply(db, publishChanges: false)
      #expect(try Chat.fetchOne(db, id: 10) == nil)
      #expect(try SyncRemovalRevision.read(db) > revision)

      let imported = try GetChatsTransaction.applyCatalog(
        page(), context: dispatched, allowedChatIDs: [10], in: db
      )
      #expect(try Chat.fetchOne(db, id: 10)?.lastMsgId == nil)
      #expect(try Message.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
    }
  }

  @Test("unprepared catalog reads import metadata without messages or child cursors")
  func metadataOnlyDefault() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let imported = try GetChatsTransaction.applyCatalog(page(), context: .init(), in: db)
      #expect(try Chat.fetchOne(db, id: 10) != nil)
      #expect(try Message.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
      #expect(try DbBucketState.fetchCount(db) == 0)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 10).count == 1)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 10, scope: .media).count == 1)
    }
  }

  @Test("a truly cold coherent catalog installs only its last-message preview and sequence")
  func coldCatalogPreview() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      var result = page()
      var unrelated = result.messages[0]
      unrelated.id = 49
      unrelated.message = "unrequested older body"
      result.messages.append(unrelated)
      let imported = try GetChatsTransaction.applyCatalog(
        result, context: context, allowedChatIDs: [10], in: db
      )
      let bucket = BucketKey.chat(peer: .with { $0.chat.chatID = 10 })
      #expect(try Chat.fetchOne(db, id: 10)?.lastMsgId == 50)
      #expect(try Message.fetchAll(db).map(\.messageId) == [50])
      #expect(try Message.fetchOne(db, key: ["chatId": 10, "messageId": 50])?.text == "snapshot")
      #expect(imported.seededStates[bucket]?.seq == 10)
      #expect(try Int64
        .fetchOne(db, sql: "SELECT seq FROM sync_bucket_state WHERE bucketType = 1 AND entityId = -10") == 10)
      for scope in MessageHistoryScope.allCases {
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 10, scope: scope) == [
          MessageHistoryHole(chatId: 10, scope: scope, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax),
        ])
      }
    }
  }

  @Test("cold cursor rejection rolls back its model preview and acknowledgements")
  func coldCatalogCursorFailureIsAtomic() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      try db.execute(sql: """
        CREATE TRIGGER reject_cold_cursor BEFORE INSERT ON sync_bucket_state
        WHEN NEW.bucketType = 1 AND NEW.entityId = -10
        BEGIN SELECT RAISE(ABORT, 'reject cold cursor'); END;
        """)
      var result = page()
      result.chats[0].acknowledgements.cursors = [.with {
        $0.chatID = 10
        $0.userID = 1
        $0.maxID = 50
        $0.revision = 1
      }]
      let imported = try GetChatsTransaction.applyCatalog(
        result, context: context, allowedChatIDs: [10], in: db
      )
      #expect(imported.failures == [.init(phase: .chatCursors, count: 1)])
      #expect(imported.seededStates.isEmpty)
      #expect(try Chat.fetchOne(db, id: 10) == nil)
      #expect(try Message.fetchCount(db) == 0)
      #expect(try Acknowledgement.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchCount(db) == 0)
    }
  }

  @Test("cold bootstrap requires both its dispatch removal fence and history permission", arguments: [false, true])
  func coldCatalogAdmissionFence(removalChanged: Bool) throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      if removalChanged {
        try SyncRemovalRevision.advance(db)
      }
      let imported = try GetChatsTransaction.applyCatalog(
        page(), context: context, allowedChatIDs: removalChanged ? [10] : [], in: db
      )
      #expect(try Chat.fetchOne(db, id: 10) != nil)
      #expect(try Message.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
    }
  }

  @Test(
    "an unavailable or invalid cold last-message snapshot cannot install a cursor",
    arguments: ["missing-body", "duplicate-body", "wrong-peer", "missing-user", "no-sequence"]
  )
  func invalidColdCatalogBody(reason: String) throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      var result = page()
      switch reason {
        case "missing-body": result.messages = []
        case "duplicate-body": result.messages.append(result.messages[0])
        case "wrong-peer": result.messages[0].peerID.chat.chatID = 99
        case "missing-user": result.messages[0].fromID = 999
        case "no-sequence": result.chats[0].clearSeq()
        default: Issue.record("Unknown fixture")
      }
      let imported = try GetChatsTransaction.applyCatalog(
        result, context: context, allowedChatIDs: [10], in: db
      )
      #expect(try Chat.fetchOne(db, id: 10) != nil)
      #expect(try Chat.fetchOne(db, id: 10)?.lastMsgId == nil)
      #expect(try Message.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 10, scope: .media).count == 1)
    }
  }

  @Test("a local deletion after dispatch cannot be resurrected by the chat catalog")
  func dispatchRevisionFence() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      try Chat(id: 10, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Cached", spaceId: nil).insert(db)
      var cached = Message(
        messageId: 50,
        fromId: 1,
        date: Date(timeIntervalSince1970: 1),
        text: "cached",
        peerUserId: nil,
        peerThreadId: 10,
        chatId: 10
      )
      try cached.saveMessage(db)
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      try Message.deleteMessages(db, messageIds: [50], chatId: 10)
      let imported = try GetChatsTransaction.applyCatalog(page(), context: context, allowedChatIDs: [10], in: db)
      #expect(try Message.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
      #expect(try Int64.fetchOne(db, sql: "SELECT historyAdmissionRevision FROM chat WHERE id = 10") == 1)
    }
  }

  @Test("pending destructive intent permits catalog metadata but blocks canonical bootstrap")
  func pendingIntentFence() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      let imported = try GetChatsTransaction.applyCatalog(page(), context: context, allowedChatIDs: [], in: db)
      #expect(try Chat.fetchOne(db, id: 10)?.title == "Catalog")
      #expect(try Message.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
      #expect(try DbBucketState.fetchCount(db) == 0)
    }
  }

  @Test("removal during dispatch blocks message and child cursor import")
  func removalFence() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      try SyncRemovalRevision.advance(db)
      let imported = try GetChatsTransaction.applyCatalog(page(), context: context, allowedChatIDs: [10], in: db)
      #expect(try Message.fetchCount(db) == 0)
      #expect(imported.seededStates.isEmpty)
    }
  }

  @Test("ordinary catalog cannot import new message 12 ahead of a pending clear at 11")
  func catalogCannotRunAheadOfClear() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedCachedFile(db)
      let bucket = BucketKey.chat(peer: .with { $0.chat.chatID = 10 })
      _ = try GRDBSyncStorage.seedSnapshotBucketState(
        for: bucket, seq: 10, in: db
      )
      // The catalog encoder can observe message 12 independently of an older
      // clear at sequence 11 that this chat's replay has not consumed yet.
      var ahead = page()
      ahead.chats[0].seq = 12
      ahead.chats[0].lastMsgID = 12
      ahead.messages[0].id = 12
      ahead.messages[0].message = "new after clear"
      let context = try GetChatsTransaction.Context(expectedRemovalRevision: SyncRemovalRevision.read(db))
      let imported = try GetChatsTransaction.applyCatalog(ahead, context: context, allowedChatIDs: [10], in: db)
      #expect(try Message.fetchOne(db, key: ["chatId": 10, "messageId": 12]) == nil)
      #expect(try Message.fetchOne(db, key: ["chatId": 10, "messageId": 50])?.fileId == "legacy-cached-file")
      #expect(try File.fetchOne(db, id: "legacy-cached-file")?.localPath == "cached-file.txt")
      #expect(try Chat.fetchOne(db, id: 10)?.lastMsgId == 50)
      #expect(imported.seededStates.isEmpty)
      #expect(try Int64
        .fetchOne(db, sql: "SELECT seq FROM sync_bucket_state WHERE bucketType = 1 AND entityId = -10") == 10)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 10) == [
        MessageHistoryHole(chatId: 10, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax),
      ])
    }
  }

  private func seedCachedFile(_ db: Database) throws {
    var chat = Chat(id: 10, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Cached", spaceId: nil)
    try chat.insert(db)
    try File(
      id: "legacy-cached-file", fileUniqueId: "cached-file-unique-id",
      fileType: .document, fileName: "cached-file.txt", uploading: false,
      fileSize: 42, temporaryUrl: nil, temporaryUrlExpiresAt: nil,
      width: nil, height: nil, localPath: "cached-file.txt", mimeType: "text/plain"
    ).insert(db)
    var cached = Message(
      messageId: 50, fromId: 1, date: Date(timeIntervalSince1970: 1), text: "cached file",
      peerUserId: nil, peerThreadId: 10, chatId: 10, fileId: "legacy-cached-file"
    )
    cached.resourceFlags = MessageResourceFlags.file.rawValue
    try cached.saveMessage(db)
    chat.lastMsgId = 50
    try chat.save(db)
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 1, email: "catalog@example.com", firstName: "Catalog").insert(db)
    }
    return queue
  }

  private func page() -> InlineProtocol.GetChatsResult {
    .with {
      $0.chats = [.with {
        $0.id = 10
        $0.title = "Catalog"
        $0.date = 1
        $0.seq = 10
        $0.peerID.chat.chatID = 10
        $0.lastMsgID = 50
      }]
      $0.messages = [.with {
        $0.id = 50
        $0.chatID = 10
        $0.fromID = 1
        $0.date = 1
        $0.peerID.chat.chatID = 10
        $0.message = "snapshot"
      }]
    }
  }
}
