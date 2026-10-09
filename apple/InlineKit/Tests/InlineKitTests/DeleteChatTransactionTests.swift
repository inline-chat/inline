@testable import Auth
import Foundation
import GRDB
import InlineConfig
@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Confirmed chat deletion", .serialized)
struct DeleteChatTransactionTests {
  @Test("Pending and rejected deletions retain the complete local chat", arguments: ["failure", "cancel", "unknown"])
  func pendingDeletionPreservesCache(outcome: String) async throws {
    // Exercise the singleton used by the original optimistic deletion too.
    try #require(TestProcess.isRunning)
    try #require(!AppDatabase.shared.isPersistent)
    let fixture = try DeleteChatFixture(database: .shared)
    try await fixture.seed()
    defer { fixture.cleanup() }
    let transaction = fixture.transaction

    await transaction.optimistic()
    try await fixture.expectIntact()
    switch outcome {
      case "failure": await transaction.failed(error: .rejectedBeforeExecution)
      case "cancel": await transaction.cancelled()
      default: await transaction.commitOutcomeUnknown()
    }
    try await fixture.expectIntact()
  }

  @Test("Confirmed deletion removes only its peer and is idempotent", arguments: [false, true])
  func confirmedDeletion(privateChat: Bool) async throws {
    let fixture = try DeleteChatFixture(privateChat: privateChat)
    try await fixture.seed()
    let transaction = try await fixture.prepared()
    await transaction.optimistic()
    try await fixture.expectIntact()

    try await transaction.apply(.deleteChat(.init()))
    let revision = try await fixture.expectDeleted()
    #expect(revision == fixture.initialRevision + 1)
    try await transaction.apply(.deleteChat(.init()))
    #expect(try await fixture.database.reader.read { try SyncRemovalRevision.read($0) } == revision)
  }

  @Test("Confirmed caller cleanup uses its captured writer and is idempotent", arguments: [false, true])
  func confirmedCallerCleanup(privateChat: Bool) async throws {
    let fixture = try DeleteChatFixture(privateChat: privateChat)
    try await fixture.seed()
    let token = try fixture.auth.beginAccountMutation()
    try await Chat.deleteFromLocalDatabase(
      peerId: fixture.peer, databaseWriter: fixture.database.dbWriter, auth: fixture.auth, accountToken: token
    )
    let revision = try await fixture.expectDeleted()
    #expect(revision == fixture.initialRevision + 1)
    try await Chat.deleteFromLocalDatabase(
      peerId: fixture.peer, databaseWriter: fixture.database.dbWriter, auth: fixture.auth, accountToken: token
    )
    #expect(try await fixture.database.reader.read { try SyncRemovalRevision.read($0) } == revision)
  }

  @Test("Caller cleanup rejects another login generation", arguments: [false, true])
  func staleCallerCleanup(sameAccount: Bool) async throws {
    let fixture = try DeleteChatFixture()
    try await fixture.seed()
    let token = try fixture.auth.beginAccountMutation()
    fixture.cache.update(AuthSnapshot(status: .unauthenticated, didHydrate: true))
    fixture.cache.update(AuthSnapshot(
      status: .authenticatedV3(userId: sameAccount ? fixture.userID : fixture.userID + 1), didHydrate: true
    ))
    await #expect(throws: (any Error).self) {
      try await Chat.deleteFromLocalDatabase(
        peerId: fixture.peer, databaseWriter: fixture.database.dbWriter, auth: fixture.auth, accountToken: token
      )
    }
    try await fixture.expectIntact()
  }

  @Test("Invalid or unprepared results cannot delete local data")
  func invalidResultPreservesCache() async throws {
    let fixture = try DeleteChatFixture()
    try await fixture.seed()
    let prepared = try await fixture.prepared()
    for result: RpcResult.OneOf_Result? in [nil, .getChat(.init())] {
      await #expect(throws: TransactionExecutionError.self) { try await prepared.apply(result) }
      try await fixture.expectIntact()
    }
    await #expect(throws: TransactionExecutionError.self) {
      try await fixture.transaction.apply(.deleteChat(.init()))
    }
    try await fixture.expectIntact()
  }

  @Test("A local write failure rolls back messages, draft and removal revision")
  func databaseFailureIsAtomic() async throws {
    let fixture = try DeleteChatFixture()
    try await fixture.seed()
    let prepared = try await fixture.prepared()
    try await fixture.database.dbWriter.write { db in
      try db.execute(sql: """
      CREATE TRIGGER reject_chat_delete BEFORE DELETE ON chat
      WHEN OLD.id = \(fixture.chatID)
      BEGIN SELECT RAISE(ABORT, 'delete fixture'); END
      """)
    }
    await #expect(throws: TransactionExecutionError.self) { try await prepared.apply(.deleteChat(.init())) }
    try await fixture.expectIntact()
  }

  @Test("A stale response cannot delete another login generation's cache", arguments: [false, true])
  func accountTransitionRejectsDeletion(sameAccount: Bool) async throws {
    let fixture = try DeleteChatFixture()
    try await fixture.seed()
    let prepared = try await fixture.prepared()
    fixture.cache.update(AuthSnapshot(status: .unauthenticated, didHydrate: true))
    fixture.cache.update(AuthSnapshot(
      status: .authenticatedV3(userId: sameAccount ? fixture.userID : fixture.userID + 1), didHydrate: true
    ))
    await #expect(throws: TransactionExecutionError.self) { try await prepared.apply(.deleteChat(.init())) }
    try await fixture.expectIntact()
  }

  @Test("Persisted deletions retain their context, RPC and execution lane")
  func persistenceCompatibility() async throws {
    let fixture = try DeleteChatFixture()
    let prepared = try await fixture.prepared()
    let data = try JSONEncoder().encode(prepared)
    let restored = try JSONDecoder().decode(DeleteChatTransaction.self, from: data)
    #expect(restored.context.peerId == prepared.context.peerId)
    #expect(restored.input(from: restored.context) == prepared.input(from: prepared.context))
    #expect(restored.executionKey == prepared.executionKey)
    #expect(restored.effectiveReconnectReplayPolicy == .neverReplay)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["context"])
    let context = try #require(object["context"] as? [String: Any])
    #expect(Set(context.keys) == ["peerId"])
  }
}

private struct DeleteChatFixture: Sendable {
  let database: AppDatabase
  let cache: AuthSnapshotCache
  let auth: AuthHandle
  let chatID: Int64
  let privateChat: Bool
  var userID: Int64 {
    chatID + 2
  }

  var siblingID: Int64 {
    chatID + 1
  }

  var peer: InlineKit.Peer {
    privateChat ? .user(id: userID) : .thread(id: chatID)
  }

  var dialogID: Int64 {
    Dialog.getDialogId(peerId: peer)
  }

  private(set) var initialRevision: Int64 = 0

  init(database suppliedDatabase: AppDatabase? = nil, privateChat: Bool = false) throws {
    database = try suppliedDatabase ??
      AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "test-only")))
    chatID = Int64.random(in: 8_100_000 ... 8_900_000)
    self.privateChat = privateChat
    let initial = AuthSnapshot(status: .authenticatedV3(userId: chatID + 2), didHydrate: true)
    cache = AuthSnapshotCache(initial: initial)
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: UUID().uuidString,
      readSnapshot: { _, _, _ in initial }
    )
    auth = AuthHandle(cache: cache, store: store)
    initialRevision = try database.reader.read { try SyncRemovalRevision.read($0) }
  }

  var transaction: DeleteChatTransaction {
    DeleteChatTransaction(peerId: peer, database: database, auth: auth)
  }

  func prepared() async throws -> DeleteChatTransaction {
    try #require(try await transaction.preparingForDispatch() as? DeleteChatTransaction)
  }

  func seed() async throws {
    try await database.dbWriter.write { db in
      try User(id: userID, email: nil, firstName: "Delete fixture").insert(db)
      var chat = Chat(
        id: chatID,
        date: .init(timeIntervalSince1970: 1),
        type: privateChat ? .privateChat : .thread,
        title: "Cached chat",
        spaceId: nil,
        peerUserId: privateChat ? userID : nil
      )
      try chat.insert(db)
      try Chat(id: siblingID, date: .init(timeIntervalSince1970: 1), type: .thread, title: "Sibling", spaceId: nil)
        .insert(db)
      for id: Int64 in [chatID, siblingID] {
        var message = InlineKit.Message(
          messageId: 20,
          fromId: userID,
          date: .init(timeIntervalSince1970: 2),
          text: "Cached message",
          peerUserId: privateChat && id == chatID ? userID : nil,
          peerThreadId: privateChat && id == chatID ? nil : id,
          chatId: id
        )
        try message.saveMessage(db)
      }
      chat.lastMsgId = 20
      try chat.update(db)
      var dialog = Dialog(optimisticForChat: chat)
      dialog.draftMessage = .with { $0.text = "Unsent instructions" }
      try dialog.insert(db)
      try MessageHistoryCoverageStore.subtract(db, chatId: chatID, lowerId: 1, upperId: 20)
      for id in [chatID, siblingID] {
        try DbBucketState(bucketType: 1, entityId: -id, date: 2, seq: 5).insert(db)
      }
    }
  }

  func expectDeleted() async throws -> Int64 {
    try await database.reader.read { db in
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
      #expect(try Dialog.fetchOne(db, key: dialogID) == nil)
      #expect(try Message.filter(Column("chatId") == chatID).fetchCount(db) == 0)
      #expect(try MessageHistoryHole.filter(Column("chatId") == chatID).fetchCount(db) == 0)
      #expect(try Chat.fetchOne(db, id: siblingID) != nil)
      #expect(try Message.filter(Column("chatId") == siblingID).fetchCount(db) == 1)
      #expect(try User.fetchOne(db, id: userID) != nil)
      #expect(try DbBucketState.filter(Column("entityId") == -chatID).fetchCount(db) == 0)
      #expect(try DbBucketState.filter(Column("entityId") == -siblingID).fetchCount(db) == 1)
      return try SyncRemovalRevision.read(db)
    }
  }

  func expectIntact() async throws {
    try await database.reader.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID)?.lastMsgId == 20)
      #expect(try Dialog.fetchOne(db, key: dialogID)?.draftMessage?.text == "Unsent instructions")
      #expect(try Message.filter(Column("chatId") == chatID).fetchCount(db) == 1)
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: chatID) == [
        MessageHistoryHole(chatId: chatID, lowerId: 21, upperId: MessageHistoryHole.positiveMessageIDMax),
      ])
      #expect(try SyncRemovalRevision.read(db) == initialRevision)
      #expect(try DbBucketState.filter(Column("entityId") == -chatID).fetchCount(db) == 1)
    }
  }

  func cleanup() {
    try? database.dbWriter.write { db in
      try db.execute(sql: "UPDATE chat SET lastMsgId = NULL WHERE id IN (?, ?)", arguments: [chatID, siblingID])
      try Message.filter([chatID, siblingID].contains(Column("chatId"))).deleteAll(db)
      try Dialog.deleteOne(db, key: dialogID)
      try Chat.filter([chatID, siblingID].contains(Column("id"))).deleteAll(db)
      try DbBucketState.filter([-chatID, -siblingID].contains(Column("entityId"))).deleteAll(db)
      try User.deleteOne(db, key: userID)
    }
  }
}
