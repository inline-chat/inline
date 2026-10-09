import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Message updates preserve unknown history coverage")
struct LiveTailCertificationRegressionTests {
  @Test("a stale ID-only ACK confirms pending identity without certifying unseen messages")
  func staleMessageIdAcknowledgementPreservesCoverage() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try Self.seedKnownPrefix(db)
      var pending = Message(
        messageId: -1,
        randomId: 123,
        fromId: 1,
        date: Date(timeIntervalSince1970: 41),
        text: nil,
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7,
        out: true,
        status: .sending
      )
      pending = try pending.saveMessage(db)
      let originalGlobalId = try #require(pending.globalId)

      // The server committed this send as 41 before disconnect. Messages 42...60
      // then exist remotely, but are absent locally when the dedup/replay ACK arrives.
      let acknowledgement = InlineProtocol.UpdateMessageId.with {
        $0.randomID = 123
        $0.messageID = 41
      }
      try acknowledgement.apply(db, currentUserId: 1)

      let confirmed = try #require(try Message.fetchOne(db, key: ["messageId": 41, "chatId": 7]))
      #expect(confirmed.globalId == originalGlobalId)
      #expect(confirmed.status == .sent)
      #expect(confirmed.randomId == nil)
      #expect(try Message.fetchOne(db, key: ["messageId": -1, "chatId": 7]) == nil)
      #expect(try Message.filter(Message.Columns.chatId == 7).fetchCount(db) == 41)
      try Self.expectUnseenTailRemainsUnknown(db)
    }
  }

  @Test("a new-message prefix from a nonfinal catch-up page does not certify its future tail")
  func catchupPrefixPreservesCoverage() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try Self.seedKnownPrefix(db)
      let update = InlineProtocol.UpdateNewMessage.with {
        $0.message = .with {
          $0.id = 41
          $0.chatID = 7
          $0.fromID = 1
          $0.peerID = .with { $0.chat.chatID = 7 }
          $0.date = 41
          $0.out = true
        }
      }
      // These are the reducer options used for catch-up. The reducer has no
      // final-page/head proof; processing message 41 cannot certify unseen 42...60.
      try update.apply(
        db,
        publishChanges: false,
        suppressNotifications: true,
        materializeMissingReferences: true,
        incrementUnreadCount: false
      )

      #expect(try Message.fetchOne(db, key: ["messageId": 41, "chatId": 7]) != nil)
      #expect(try Message.filter(Message.Columns.chatId == 7).fetchCount(db) == 41)
      try Self.expectUnseenTailRemainsUnknown(db)
    }
  }

  private static func seedKnownPrefix(_ db: Database) throws {
    try User(id: 1, email: nil, firstName: "Fixture").insert(db)
    try Chat(
      id: 7,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Coverage fixture",
      spaceId: nil
    ).insert(db)
    for id in 1 ... 40 {
      var message = Message(
        messageId: Int64(id),
        fromId: 1,
        date: Date(timeIntervalSince1970: Double(id)),
        text: nil,
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7,
        out: true,
        status: .sent
      )
      try message.saveMessage(db)
    }
    // A completed ordinary historical page proved only the known prefix.
    try MessageHistoryCoverageStore.subtractAll(db, chatId: 7, lowerId: 1, upperId: 40)
    try expectUnseenTailRemainsUnknown(db)
  }

  private static func expectUnseenTailRemainsUnknown(_ db: Database) throws {
    for scope in MessageHistoryScope.allCases {
      #expect(try MessageHistoryCoverageStore.intersects(db, chatId: 7, scope: scope, lowerId: 42, upperId: 60))
      #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: scope) == [
        MessageHistoryHole(chatId: 7, scope: scope, lowerId: 41, upperId: MessageHistoryHole.positiveMessageIDMax),
      ])
    }
  }
}
