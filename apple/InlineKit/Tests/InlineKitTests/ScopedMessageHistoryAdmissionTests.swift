import Foundation
import GRDB
import InlineConfig
@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Scoped history snapshot admission")
struct ScopedMessageHistoryAdmissionTests {
  @Test("legacy file pointers do not give explicit photos or videos file membership")
  func legacyAttachmentPrecedence() {
    let photo = Message(
      messageId: 20,
      fromId: 1,
      date: Date(),
      text: nil,
      peerUserId: nil,
      peerThreadId: 7,
      chatId: 7,
      fileId: "legacy",
      photoId: 10,
      videoId: 11,
      documentId: 12
    )
    #expect(MessageResourceFlags.classify(photo) == .photo)
    #expect(photo.resourceFlags == MessageResourceFlags.photo.rawValue)
    #expect(!MessageHistoryScope.files.matches(photo))

    var video = photo
    video.photoId = nil
    #expect(MessageResourceFlags.classify(video) == .video)
    var sticker = photo
    sticker.isSticker = true
    #expect(MessageResourceFlags.classify(sticker).isEmpty)
  }

  @Test("an authoritative photo to video replacement removes the old photo membership")
  func fullSnapshotReplacesMediaKind() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      _ = try Message.save(db, protocolMessage: message(20, photo: 10), materializeMissingReferences: true)
      var replacement = message(20)
      replacement.rev = 2
      replacement.media.video.video = .with { $0.id = 11 }
      let saved = try Message.save(db, protocolMessage: replacement, authoritativeSnapshot: true)
      #expect(saved.photoId == nil)
      #expect(saved.videoId == 11)
      #expect(saved.resourceFlags == MessageResourceFlags.video.rawValue)
      #expect(!MessageHistoryScope.photos.matches(saved))
      #expect(try Photo.fetchCount(db) == 1)
      #expect(try Video.fetchCount(db) == 1)
    }
  }

  @Test("an explicit local media replacement preserves suppressed link membership")
  func localMediaReplacement() throws {
    let queue = try makeDatabase()
    let database = try AppDatabase(queue)
    var saved = try queue.write { db in
      var source = message(20, photo: 10)
      source.hasLink_p = true
      var saved = try Message.save(db, protocolMessage: source, materializeMissingReferences: true)
      saved.resourceFlags = MessageResourceFlags.photo.rawValue
      try saved.update(db)
      return saved
    }
    let media = MediaHelpers(database: database)
    let video = try media.createLocalVideo()
    let token = try queue.read { try HistoryPageAdmissionToken.capture($0, chatId: 7) }
    try media.attachVideoToMessage(video: video, message: &saved)
    try queue.read { (db: Database) throws in
      let current = try #require(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 20]))
      #expect(current.photoId == nil)
      #expect(current.videoId == video.videoId)
      #expect(current.resourceFlags == MessageResourceFlags.video.rawValue)
      #expect(current.hasLink == true)
      #expect(throws: HistoryPageAdmissionError.self) { try token.validate(db, chatId: 7) }
      #expect(try Photo.fetchCount(db) == 1)
    }
  }

  @Test("a resource page closes its tag without manufacturing transcript coverage")
  func filteredCoverageIsolation() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      var page = InlineProtocol.SearchMessagesResult()
      page.messages = [message(50, photo: 10), message(20, photo: 11)]
      var transaction = SearchMessagesTransaction(peer: .thread(id: 7), queries: [], limit: 2, filter: .filterPhotos)
      transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      page.seq = 0
      try SearchMessagesTransaction.apply(page, context: transaction.context, db: db)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: .photos) == [
        MessageHistoryHole(chatId: 7, scope: .photos, lowerId: 1, upperId: 19),
      ])
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: .media).count == 1)
      #expect(try Message.fetchCount(db) == 2)
    }
  }

  @Test("a filtered absence proof hides stale membership and preserves canonical data and later IDs")
  func filteredNegativeReconciliation() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      _ = try Message.save(db, protocolMessage: message(50, photo: 10), materializeMissingReferences: true)
      let token = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      _ = try Message.save(db, protocolMessage: message(60, photo: 11), materializeMissingReferences: true)
      var transaction = SearchMessagesTransaction(peer: .thread(id: 7), queries: [], filter: .filterPhotos)
      transaction.context.admissionToken = token
      var page = InlineProtocol.SearchMessagesResult()
      page.seq = 0
      try SearchMessagesTransaction.apply(page, context: transaction.context, db: db)
      let stale = try #require(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 50]))
      #expect(stale.photoId == 10)
      #expect(!MessageHistoryScope.photos.matches(stale))
      #expect(try MessageHistoryScope.photos.matches(#require(try Message.fetchOne(
        db,
        key: ["chatId": 7, "messageId": 60]
      ))))
      #expect(try Photo.fetchCount(db) == 2)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
    }
  }

  @Test("ordinary exhaustive absence removes confirmed ghosts and retains outgoing work")
  func ordinaryNegativeReconciliation() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      _ = try Message.save(db, protocolMessage: message(50), materializeMissingReferences: true)
      var pending = Message(
        messageId: 40,
        fromId: 1,
        date: Date(),
        text: "pending",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7,
        status: .sending
      )
      try pending.saveMessage(db)
      var transaction = GetChatHistoryTransaction(peer: .thread(id: 7))
      transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      var page = InlineProtocol.GetChatHistoryResult()
      page.seq = 0
      try GetChatHistoryTransaction.apply(page, context: transaction.context, db: db)
      #expect(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 50]) == nil)
      #expect(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 40])?.status == .sending)
      for scope in MessageHistoryScope.allCases {
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: scope).isEmpty)
      }
    }
  }

  @Test("stale revisions or missing sequence cannot close holes")
  func staleSnapshotRejected() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      var transaction = GetChatHistoryTransaction(peer: .thread(id: 7))
      transaction.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      var page = InlineProtocol.GetChatHistoryResult()
      #expect(throws: HistoryPageAdmissionError.self) {
        try GetChatHistoryTransaction.apply(page, context: transaction.context, db: db)
      }
      page.seq = 0
      try HistoryPageAdmissionToken.advanceRevision(db, chatId: 7)
      #expect(throws: HistoryPageAdmissionError.self) {
        try GetChatHistoryTransaction.apply(page, context: transaction.context, db: db)
      }
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
    }
  }

  @Test("bad order, duplicates, and predicate mismatches roll back the entire raw page")
  func invalidPageRollback() throws {
    for messages in [
      [message(10, photo: 10), message(20, photo: 11)],
      [message(20, photo: 10), message(20, photo: 10)],
      [message(20)],
    ] {
      let queue = try makeDatabase()
      var page = InlineProtocol.SearchMessagesResult()
      page.messages = messages
      var transaction = SearchMessagesTransaction(peer: .thread(id: 7), queries: [], filter: .filterPhotos)
      transaction.context.admissionToken = try queue.read { try HistoryPageAdmissionToken.capture($0, chatId: 7) }
      page.seq = 0
      #expect(throws: HistoryPageAdmissionError.self) {
        try queue.write { db in try SearchMessagesTransaction.apply(page, context: transaction.context, db: db) }
      }
      try queue.read { (db: Database) throws in
        #expect(try Message.fetchCount(db) == 0)
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: .photos).count == 1)
      }
    }
  }

  @Test("full snapshots clear removed photo associations while preserving reusable assets")
  func fullSnapshotClearsAssociation() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      _ = try Message.save(db, protocolMessage: message(20, photo: 10), materializeMissingReferences: true)
      var replacement = message(20)
      replacement.rev = 2
      let saved = try Message.save(db, protocolMessage: replacement, authoritativeSnapshot: true)
      #expect(saved.photoId == nil)
      #expect(saved.resourceFlags == 0)
      #expect(try Photo.fetchCount(db) == 1)
    }
  }

  @Test("unrelated partial updates cannot resurrect a suppressed resource tag")
  func partialUpdatePreservesSuppression() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      _ = try Message.save(db, protocolMessage: message(20, photo: 10), materializeMissingReferences: true)
      try db.execute(sql: "UPDATE message SET resourceFlags = 0 WHERE chatId = 7 AND messageId = 20")
      var partial = message(20)
      partial.rev = 2
      let saved = try Message.save(db, protocolMessage: partial)
      #expect(saved.photoId == 10)
      #expect(saved.resourceFlags == 0)
    }
  }

  @Test("zero around sides and excluded anchors retain unknown coordinates")
  func aroundCoverageBoundaries() {
    let around = GetChatHistoryTransaction(
      peer: .thread(id: 7),
      mode: .historyModeAround,
      anchorID: 50,
      limit: 4,
      beforeLimit: 0,
      afterLimit: 2,
      includeAnchor: false
    )
    #expect(GetChatHistoryTransaction.provenCoverages(context: around.context, messageIDs: [60, 55]) == [51 ... 60])
    #expect(GetChatHistoryTransaction
      .provenCoverages(context: around.context, messageIDs: []) == [51 ... MessageHistoryHole.positiveMessageIDMax])
  }

  @Test("default around pages fill a deleted anchor's slot without declaring a full side exhausted")
  func deletedAroundAnchorUsesDefaultSplit() {
    let around = GetChatHistoryTransaction(
      peer: .thread(id: 7), mode: .historyModeAround, anchorID: 7, limit: 6
    )
    #expect(GetChatHistoryTransaction.provenCoverages(
      context: around.context, messageIDs: [10, 9, 8, 6, 5, 4]
    ) == [4 ... 10])
    #expect(GetChatHistoryTransaction.provenCoverages(
      context: around.context, messageIDs: [10, 9, 8, 7, 6, 5, 4]
    ) == nil)
  }

  @Test("exact lookup removes only absent requested coordinates and never closes holes")
  func exactLookupNegativeAuthority() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      for id in [20, 30, 40] {
        _ = try Message.save(
          db,
          protocolMessage: message(Int64(id)),
          materializeMissingReferences: true
        )
      }
      var query = GetMessagesTransaction(peer: .thread(id: 7), messageIds: [20, 30])
      query.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      var result = InlineProtocol.GetMessagesResult()
      result.messages = [message(30)]
      result.seq = 0
      try GetMessagesTransaction.apply(result, context: query.context, db: db)
      #expect(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 20]) == nil)
      #expect(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 40]) != nil)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
    }
  }

  @Test("uncached deletes fence previously dispatched pages")
  func uncachedDeletionFence() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let token = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      try Message.deleteMessages(db, messageIds: [90], chatId: 7)
      #expect(throws: HistoryPageAdmissionError.self) { try token.validate(db, chatId: 7) }
    }
  }

  @Test(
    "absent-root mutations invalidate a dispatched cold catalog without creating the chat",
    arguments: ["delete", "attachment", "optimistic-edit", "live-edit"]
  )
  func coldCatalogMutationFence(_ mutation: String) throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let dispatchedRemovalRevision = try SyncRemovalRevision.read(db)
      let knownChatToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      switch mutation {
        case "delete":
          try Message.deleteMessages(db, messageIds: [20], chatId: 9)
        case "attachment":
          let update = InlineProtocol.UpdateMessageAttachment.with {
            $0.chatID = 9
            $0.messageID = 20
            $0.attachment.id = 99
          }
          _ = try update.apply(db, publishChanges: false)
        case "optimistic-edit":
          let edit = EditMessageTransaction(messageId: 20, text: "edited", chatId: 9, peerId: .thread(id: 9))
          try edit.applyOptimisticEdit(in: db)
        default:
          let update = InlineProtocol.UpdateEditMessage.with {
            $0.message = message(20)
            $0.message.chatID = 9
            $0.message.peerID = .with { $0.chat.chatID = 9 }
          }
          #expect(try update.apply(db, publishChanges: false, materializeMissingReferences: true) == false)
      }
      #expect(try SyncRemovalRevision.read(db) != dispatchedRemovalRevision)
      #expect(try Chat.fetchOne(db, id: 9) == nil)
      #expect(try Message.fetchCount(db) == 0)
      #expect(throws: HistoryPageAdmissionError.self) { try knownChatToken.validate(db, chatId: 7) }
    }
  }

  @Test("root removal evidence rejects a deleted and recreated chat")
  func recreatedChatFence() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let token = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      try SyncRemovalRevision.advance(db)
      try Chat.deleteOne(db, id: 7)
      try Chat(id: 7, date: Date(), type: .thread, title: nil, spaceId: nil).insert(db)
      #expect(throws: HistoryPageAdmissionError.self) { try token.validate(db, chatId: 7) }
    }
  }

  @Test("recovery admission cannot recreate a root removed between discovery and dispatch")
  func removedRootRecoveryCapture() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let discovered = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      try SyncRemovalRevision.advance(db)
      try Chat.deleteOne(db, id: 7)
      #expect(throws: HistoryPageAdmissionError.self) {
        try HistoryPageAdmissionToken.capture(db, chatId: discovered.chatId)
      }
      #expect(try Chat.fetchCount(db) == 0)
      #expect(try MessageHistoryHole.fetchCount(db) == 0)
      #expect(throws: HistoryPageAdmissionError.self) { try discovered.validate(db, chatId: 7) }

      // Metadata lookup must establish a cold root before a message page can own it.
      let coldID = MessageHistoryHole.positiveMessageIDMax + 1
      #expect(throws: HistoryPageAdmissionError.self) {
        try HistoryPageAdmissionToken.capture(db, peer: .thread(id: coldID))
      }
      #expect(try Chat.fetchCount(db) == 0)
      #expect(try MessageHistoryHole.fetchCount(db) == 0)
    }
  }

  @Test("migration preserves ordinary evidence and initializes fixed resource tags as unknown")
  func coverageMigration() throws {
    let queue = try DatabaseQueue()
    var migrator = AppDatabase.empty().migrator
    migrator.eraseDatabaseOnSchemaChange = false
    try migrator.migrate(queue, upTo: "space profile pictures")
    try queue.write { db in
      try db.execute(sql: "INSERT INTO chat (id, date, type) VALUES (7, 0, 1)")
      try db.execute(sql: "DELETE FROM messageHistoryHole WHERE chatId = 7")
      try db.execute(sql: "INSERT INTO messageHistoryHole VALUES (7, 1, 19)")
    }
    try migrator.migrate(queue)
    try queue.read { (db: Database) throws in
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7) == [
        MessageHistoryHole(chatId: 7, lowerId: 1, upperId: 19),
      ])
      for scope in MessageHistoryScope.allCases where scope != .timeline {
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: scope) == [
          MessageHistoryHole(chatId: 7, scope: scope, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax),
        ])
      }
    }
  }

  @Test("attachment deletion fences an uncached parent and makes its link scope unknown")
  func uncachedAttachmentFence() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      try MessageHistoryCoverageStore.subtract(
        db,
        chatId: 7,
        scope: .links,
        lowerId: 1,
        upperId: MessageHistoryHole.positiveMessageIDMax
      )
      let token = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      let update = InlineProtocol.UpdateMessageAttachment.with {
        $0.chatID = 7
        $0.messageID = 90
        $0.attachment.id = 99
      }
      _ = try update.apply(db, publishChanges: false)
      #expect(throws: HistoryPageAdmissionError.self) { try token.validate(db, chatId: 7) }
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: .links).count == 1)
    }
  }

  @Test("a batch deleting the entire cached tail preserves the chat root")
  func deletesCachedTailBatch() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      for id in [20, 30] {
        _ = try Message.save(
          db,
          protocolMessage: message(Int64(id)),
          materializeMissingReferences: true
        )
      }
      try Chat.filter(Chat.Columns.id == 7).updateAll(db, Chat.Columns.lastMsgId.set(to: 30))
      try Message.deleteMessages(db, messageIds: [30, 20], chatId: 7)
      #expect(try Chat.fetchOne(db, id: 7)?.lastMsgId == nil)
      #expect(try Chat.fetchCount(db) == 1)
      #expect(try Message.fetchCount(db) == 0)
    }
  }

  @Test("last-message promotion follows confirmed IDs despite backdated message dates")
  func backdatedLastPromotion() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      for (id, date) in [(20, 300), (30, 100), (40, 400)] {
        var row = message(Int64(id))
        row.date = Int64(date)
        _ = try Message.save(db, protocolMessage: row, materializeMissingReferences: true)
      }
      try Chat.filter(Chat.Columns.id == 7).updateAll(db, Chat.Columns.lastMsgId.set(to: 40))
      try Message.deleteMessages(db, messageIds: [40], chatId: 7)
      #expect(try Chat.fetchOne(db, id: 7)?.lastMsgId == 30)

      var pending = Message(
        messageId: -1,
        fromId: 1,
        date: Date(timeIntervalSince1970: 500),
        text: "pending",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7,
        status: .sending
      )
      try pending.saveMessage(db)
      try Chat.filter(Chat.Columns.id == 7).updateAll(db, Chat.Columns.lastMsgId.set(to: 30))
      try Message.deleteMessages(db, messageIds: [30], chatId: 7)
      #expect(try Chat.fetchOne(db, id: 7)?.lastMsgId == -1)
    }
  }

  @Test("an exhaustive empty page removes a cached history larger than one delete batch")
  func largeEmptySnapshotDeletion() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      for id in 1 ... 1_201 {
        try db.execute(
          sql: "INSERT INTO message (messageId, chatId, fromId, date, peerThreadId) VALUES (?, 7, 1, ?, 7)",
          arguments: [id, id]
        )
      }
      try Chat.filter(Chat.Columns.id == 7).updateAll(db, Chat.Columns.lastMsgId.set(to: 1_201))
      var query = GetChatHistoryTransaction(peer: .thread(id: 7))
      query.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      var response = InlineProtocol.GetChatHistoryResult()
      response.seq = 0
      try GetChatHistoryTransaction.apply(response, context: query.context, db: db)
      #expect(try Message.fetchCount(db) == 0)
      #expect(try Chat.fetchOne(db, id: 7)?.lastMsgId == nil)
      #expect(try Chat.fetchCount(db) == 1)
      for scope in MessageHistoryScope.allCases {
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: scope).isEmpty)
      }
    }
  }

  @Test("a later lookup inserting an older coordinate fences a dispatched absence proof")
  func laterLookupCannotBeErased() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      _ = try Message.save(db, protocolMessage: message(100), materializeMissingReferences: true)
      var earlier = SearchMessagesTransaction(peer: .thread(id: 7), queries: [], filter: .filterPhotos)
      earlier.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      _ = try Message.save(
        db,
        protocolMessage: message(25, photo: 10),
        materializeMissingReferences: true,
        authoritativeSnapshot: true
      )
      var empty = InlineProtocol.SearchMessagesResult()
      empty.seq = 0
      #expect(throws: HistoryPageAdmissionError.self) {
        try SearchMessagesTransaction.apply(empty, context: earlier.context, db: db)
      }
      #expect(try MessageHistoryScope.photos.matches(#require(try Message.fetchOne(
        db,
        key: ["chatId": 7, "messageId": 25]
      ))))
    }
  }

  @Test("an accepted edit adding a link fences an older filtered absence proof")
  func laterEditCannotBeSuppressed() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      _ = try Message.save(db, protocolMessage: message(25), materializeMissingReferences: true)
      var earlier = SearchMessagesTransaction(peer: .thread(id: 7), queries: [], filter: .filterLinks)
      earlier.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      let edit = InlineProtocol.UpdateEditMessage.with {
        $0.message = message(25)
        $0.message.rev = 2
        $0.message.message = "https://inline.chat"
        $0.message.hasLink_p = true
      }
      _ = try edit.apply(db, publishChanges: false)
      var empty = InlineProtocol.SearchMessagesResult()
      empty.seq = 0
      #expect(throws: HistoryPageAdmissionError.self) {
        try SearchMessagesTransaction.apply(empty, context: earlier.context, db: db)
      }
      #expect(try MessageHistoryScope.links.matches(#require(try Message.fetchOne(
        db,
        key: ["chatId": 7, "messageId": 25]
      ))))
    }
  }

  @Test("confirmed snapshot dates replace stale cached dates before a date clear")
  func authoritativeDateClear() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      var cached = message(20)
      cached.date = 1_000
      _ = try Message.save(db, protocolMessage: cached, materializeMissingReferences: true)
      var full = message(20)
      full.rev = 2
      full.date = 10
      _ = try Message.save(db, protocolMessage: full, authoritativeSnapshot: true)
      let clear = InlineProtocol.UpdateClearChatHistory.with {
        $0.peerID = .with { $0.chat.chatID = 7 }
        $0.beforeDate = 100
      }
      _ = try clear.apply(db, publishChanges: false)
      #expect(try Message.fetchCount(db) == 0)
    }
  }

  @Test("malformed required media photos roll back data and coverage")
  func invalidRequiredSidecarRollback() throws {
    let queue = try makeDatabase()
    var page = InlineProtocol.GetChatHistoryResult()
    var invalid = message(20)
    invalid.media.photo.photo = .with { $0.id = 0 }
    page.messages = [message(30), invalid]
    page.seq = 0
    var query = GetChatHistoryTransaction(peer: .thread(id: 7))
    query.context.admissionToken = try queue.read { try HistoryPageAdmissionToken.capture($0, chatId: 7) }
    #expect(throws: HistoryPageAdmissionError.self) {
      try queue.write { db in try GetChatHistoryTransaction.apply(page, context: query.context, db: db) }
    }
    try queue.read { (db: Database) throws in
      #expect(try Message.fetchCount(db) == 0)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
    }
  }

  @Test("unavailable optional block images preserve text and authoritative history coverage")
  func optionalBlockImageTextFallback() throws {
    let queue = try makeDatabase()
    var page = InlineProtocol.GetChatHistoryResult()
    var optional = message(20)
    optional.message = "Readable fallback"
    optional.blockContent = .with { $0.blocks = [.with { $0.image.ready = .with { $0.id = 0 } }] }
    page.messages = [message(30), optional]
    page.seq = 0
    var query = GetChatHistoryTransaction(peer: .thread(id: 7))
    query.context.admissionToken = try queue.read { try HistoryPageAdmissionToken.capture($0, chatId: 7) }
    try queue.write { db in try GetChatHistoryTransaction.apply(page, context: query.context, db: db) }
    try queue.read { (db: Database) throws in
      #expect(try Message.fetchCount(db) == 2)
      #expect(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 20])?.text == "Readable fallback")
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).isEmpty)
    }
  }

  @Test("optimistic text edits update only link membership and fence old pages", arguments: [false, true])
  func optimisticEditMembership(suppressedMedia: Bool) throws {
    let queue = try makeDatabase()
    try queue.write { db in
      var original = message(20, photo: 10)
      original.message = "https://inline.chat"
      original.hasLink_p = true
      _ = try Message.save(db, protocolMessage: original, materializeMissingReferences: true)
      if suppressedMedia {
        var resources = SearchMessagesTransaction(peer: .thread(id: 7), queries: [], filter: .filterPhotos)
        resources.context.admissionToken = try HistoryPageAdmissionToken.capture(db, chatId: 7)
        let absent = InlineProtocol.SearchMessagesResult.with { $0.seq = 0 }
        try SearchMessagesTransaction.apply(absent, context: resources.context, db: db)
      }
      let token = try HistoryPageAdmissionToken.capture(db, chatId: 7)
      let edit = EditMessageTransaction(messageId: 20, text: "plain text", chatId: 7, peerId: .thread(id: 7))
      try edit.applyOptimisticEdit(in: db)
      let saved = try #require(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 20]))
      #expect(!MessageHistoryScope.links.matches(saved))
      #expect(MessageHistoryScope.photos.matches(saved) == !suppressedMedia)
      #expect(saved.photoId == 10)
      #expect(throws: HistoryPageAdmissionError.self) { try token.validate(db, chatId: 7) }

      let linkedEdit = EditMessageTransaction(
        messageId: 20,
        text: "https://inline.chat",
        chatId: 7,
        peerId: .thread(id: 7)
      )
      try linkedEdit.applyOptimisticEdit(in: db)
      let linked = try #require(try Message.fetchOne(db, key: ["chatId": 7, "messageId": 20]))
      #expect(MessageHistoryScope.links.matches(linked))
      #expect(MessageHistoryScope.photos.matches(linked) == !suppressedMedia)
    }
  }

  @Test("full attachment identity collisions roll back without certifying coverage")
  func attachmentOwnershipRollback() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      let owner = try Message.save(db, protocolMessage: message(30), materializeMissingReferences: true)
      try Attachment(messageId: owner.globalId, externalTaskId: nil, urlPreviewId: nil, attachmentId: 99).insert(db)
    }
    var incoming = message(20)
    incoming.attachments.attachments = [.with {
      $0.id = 99
      $0.externalTask = .with { $0.id = 5
        $0.application = "test"
        $0.assignedUserID = 1
      }
    }]
    var page = InlineProtocol.GetChatHistoryResult()
    page.seq = 0
    page.messages = [incoming]
    var query = GetChatHistoryTransaction(peer: .thread(id: 7))
    query.context.admissionToken = try queue.read { try HistoryPageAdmissionToken.capture($0, chatId: 7) }
    #expect(throws: HistoryPageAdmissionError.self) {
      try queue.write { db in try GetChatHistoryTransaction.apply(page, context: query.context, db: db) }
    }
    try queue.read { (db: Database) throws in
      #expect(try Message.fetchCount(db) == 1)
      #expect(try ExternalTask.fetchCount(db) == 0)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7).count == 1)
    }
  }

  @Test("an unrelated task attachment cannot restore a suppressed stale URL")
  func unrelatedAttachmentPreservesSuppression() throws {
    let queue = try makeDatabase()
    try queue.write { db in
      var original = message(20)
      original.message = "https://inline.chat"
      original.hasLink_p = true
      _ = try Message.save(db, protocolMessage: original, materializeMissingReferences: true)
      try db.execute(sql: "UPDATE message SET resourceFlags = 0 WHERE chatId = 7 AND messageId = 20")
      let update = InlineProtocol.UpdateMessageAttachment.with {
        $0.chatID = 7
        $0.messageID = 20
        $0.attachment = .with {
          $0.id = 99
          $0.externalTask = .with { $0.id = 5
            $0.application = "test"
            $0.assignedUserID = 1
          }
        }
      }
      _ = try update.apply(db, publishChanges: false)
      #expect(try !MessageHistoryScope.links.matches(#require(try Message.fetchOne(
        db,
        key: ["chatId": 7, "messageId": 20]
      ))))
    }
  }

  private func makeDatabase() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 7, date: Date(), type: .thread, title: nil, spaceId: nil).insert(db)
    }
    return queue
  }

  private func message(_ id: Int64, photo: Int64? = nil) -> InlineProtocol.Message {
    .with {
      $0.id = id
      $0.chatID = 7
      $0.fromID = 1
      $0.peerID = .with { $0.chat.chatID = 7 }
      $0.date = 1
      $0.rev = 1
      $0.message = "Message"
      $0.hasLink_p = false
      if let photo {
        $0.media.photo.photo = .with { $0.id = photo }
      }
    }
  }
}

@Suite("History request canonical DM preparation")
struct HistoryRequestCanonicalDMPreparationTests {
  @Test("known raw DM coordinates prepare a canonical request without changing the requested messages")
  func knownRawDMPreparation() async throws {
    let chatID: Int64 = 1_900_000_007
    let userID: Int64 = 1_900_000_055
    try await seedKnownDM(chatID: chatID, userID: userID)

    let request = GetMessagesTransaction(peer: .thread(id: chatID), messageIds: [20, 30])
    let prepared = try await request.preparingForDispatch()
    let query = try #require(prepared as? GetMessagesTransaction)
    #expect(query.context.peer == .user(id: userID))
    #expect(query.historyReadChatID == chatID)
    #expect(query.context.admissionToken?.chatId == chatID)
    #expect(query.historyReadBucket == .chat(peer: .with { $0.user.userID = userID }))
    #expect(query.context.messageIds == [20, 30])
    guard case let .getMessages(input)? = query.input(from: query.context) else {
      Issue.record("Expected getMessages input")
      return
    }
    #expect(input.messageIds == [20, 30])
    guard case let .user(peer)? = input.peerID.type else {
      Issue.record("Expected the canonical user input peer")
      return
    }
    #expect(peer.userID == userID)
  }

  @Test("known raw DM transcript preparation preserves numeric around-page arguments")
  func knownRawDMHistoryPreparation() async throws {
    let chatID: Int64 = 1_900_000_008
    let userID: Int64 = 1_900_000_056
    try await seedKnownDM(chatID: chatID, userID: userID)
    let request = GetChatHistoryTransaction(
      peer: .thread(id: chatID), mode: .historyModeAround, anchorID: 25,
      limit: 5, beforeLimit: 2, afterLimit: 3, includeAnchor: false
    )
    let prepared = try await request.preparingForDispatch()
    let query = try #require(prepared as? GetChatHistoryTransaction)
    #expect(query.context.peer == .user(id: userID))
    #expect(query.historyReadChatID == chatID)
    #expect(query.context.admissionToken?.chatId == chatID)
    #expect(query.historyReadBucket == .chat(peer: .with { $0.user.userID = userID }))
    guard case let .getChatHistory(input)? = query.input(from: query.context) else {
      Issue.record("Expected getChatHistory input")
      return
    }
    #expect(input.mode == .historyModeAround)
    #expect(input.anchorID == 25)
    #expect(input.limit == 5)
    #expect(input.beforeLimit == 2)
    #expect(input.afterLimit == 3)
    #expect(input.hasIncludeAnchor && !input.includeAnchor)
    guard case let .user(peer)? = input.peerID.type else {
      Issue.record("Expected the canonical user input peer")
      return
    }
    #expect(peer.userID == userID)
  }

  @Test("known raw DM resource preparation preserves filter and numeric cursor")
  func knownRawDMResourcePreparation() async throws {
    let chatID: Int64 = 1_900_000_009
    let userID: Int64 = 1_900_000_057
    try await seedKnownDM(chatID: chatID, userID: userID)
    let request = SearchMessagesTransaction(
      peer: .thread(id: chatID), queries: [], offsetID: 77, limit: 25, filter: .filterPhotos
    )
    let prepared = try await request.preparingForDispatch()
    let query = try #require(prepared as? SearchMessagesTransaction)
    #expect(query.context.peer == .user(id: userID))
    #expect(query.historyReadChatID == chatID)
    #expect(query.context.admissionToken?.chatId == chatID)
    #expect(query.historyReadBucket == .chat(peer: .with { $0.user.userID = userID }))
    guard case let .searchMessages(input)? = query.input(from: query.context) else {
      Issue.record("Expected searchMessages input")
      return
    }
    #expect(input.queries.isEmpty)
    #expect(input.offsetID == 77)
    #expect(input.limit == 25)
    #expect(input.filter == .filterPhotos)
    guard case let .user(peer)? = input.peerID.type else {
      Issue.record("Expected the canonical user input peer")
      return
    }
    #expect(peer.userID == userID)
  }

  private func seedKnownDM(chatID: Int64, userID: Int64) async throws {
    // These intentionally exercise the singleton-bound production entry points.
    // Require the runner boundary before the singleton can open a user store.
    try #require(TestProcess.isRunning)
    let database = AppDatabase.shared
    try #require(!database.isPersistent)
    try await database.dbWriter.write { db in
      try User(id: userID, email: nil, firstName: "History fixture").insert(db)
      try Chat(
        id: chatID,
        date: Date(timeIntervalSince1970: 0),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: userID
      ).insert(db)
    }
  }
}
