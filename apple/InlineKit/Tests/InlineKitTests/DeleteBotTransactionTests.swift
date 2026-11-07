@testable import Auth
import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Confirmed bot deletion")
struct DeleteBotTransactionTests {
  @Test("A confirmed deletion drops the bot's cached DM so it leaves mentions and the sidebar")
  func confirmedDeletionRemovesDirectChat() async throws {
    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "test-only")))
    let ownerID: Int64 = 7_700_001
    let botID: Int64 = 7_700_002
    let chatID: Int64 = 7_700_010
    let initial = AuthSnapshot(status: .authenticatedV3(userId: ownerID), didHydrate: true)
    let cache = AuthSnapshotCache(initial: initial)
    let auth = AuthHandle(
      cache: cache,
      store: AuthStore(cache: cache, mocked: true, namespace: UUID().uuidString, readSnapshot: { _, _, _ in initial })
    )
    let dialogID = Dialog.getDialogId(peerId: .user(id: botID))

    try await database.dbWriter.write { db in
      var bot = User(id: botID, email: nil, firstName: "Yung Tuzz Test", username: "yungtuzz_bot")
      bot.bot = true
      try bot.insert(db)
      let chat = Chat(
        id: chatID,
        date: .init(timeIntervalSince1970: 1),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: botID
      )
      try chat.insert(db)
      try Dialog(optimisticForChat: chat).insert(db)
    }

    let transaction = DeleteBotTransaction(botUserId: botID, database: database, auth: auth)
    let prepared = try #require(try await transaction.preparingForDispatch() as? DeleteBotTransaction)
    try await prepared.apply(.deleteBot(.init()))

    try await database.reader.read { (db: Database) throws in
      #expect(try Dialog.fetchOne(db, key: dialogID) == nil)
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
    }
    // Repeating the confirmation is harmless.
    try await prepared.apply(.deleteBot(.init()))
  }
}
