import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Cancelled sends")
struct CancelledSendsTests {
  @Test("A cancelled send lands once, in the chat it was cancelled in")
  func landsOnce() {
    let sends = CancelledSends()
    sends.record(randomId: 7, chatId: 3, peerId: .thread(id: 3))

    #expect(sends.land(randomId: 8, messageId: 100) == nil)
    #expect(sends.land(randomId: 7, messageId: 100)?.chatId == 3)
    #expect(sends.land(randomId: 7, messageId: 100) == nil)
    #expect(sends.isLanded(chatId: 3, messageId: 100))
    #expect(!sends.isLanded(chatId: 4, messageId: 100))
  }

  @Test("A send cancelled after dispatch doesn't come back when the server confirms it")
  @MainActor
  func confirmedCancelledSendStaysGone() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let randomID = Int64.random(in: 1_000_000 ... Int64.max)
    let messageID = Int64.random(in: 1_000 ... 1_000_000)
    try await database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 1, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Chat", spaceId: nil).insert(db)
      var pending = Message(messageId: -5, randomId: randomID, fromId: 1, date: Date(timeIntervalSince1970: 1_000),
                            text: nil, peerUserId: nil, peerThreadId: 1, chatId: 1, out: true, status: .sending)
      try pending.saveMessage(db)
    }

    CancelledSends.shared.record(randomId: randomID, chatId: 1, peerId: .thread(id: 1))

    let remaining = try await database.dbWriter.write { db in
      try InlineProtocol.UpdateMessageId.with { $0.randomID = randomID; $0.messageID = messageID }
        .apply(db, currentUserId: 1)
      try InlineProtocol.UpdateNewMessage.with {
        $0.message = .with {
          $0.id = messageID; $0.chatID = 1; $0.fromID = 1
          $0.peerID = .with { $0.chat.chatID = 1 }
          $0.date = 1_000; $0.out = true
        }
      }.apply(db, publishChanges: false, suppressNotifications: true)
      return try Message.filter(Column("chatId") == 1).fetchCount(db)
    }

    #expect(remaining == 0)
  }
}
