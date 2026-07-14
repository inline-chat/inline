import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Realtime access cleanup")
struct RealtimeAccessCleanupTests {
  @Test("deleting a chat clears its composite last-message reference first")
  func deletingChatClearsLastMessageReference() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      let userId: Int64 = 10
      let spaceId: Int64 = 20
      let chatId: Int64 = 30
      let messageId: Int64 = 40

      try User(
        id: userId,
        email: nil,
        firstName: "Cleanup",
        lastName: "Test",
        username: nil
      ).insert(db)
      try Space(
        id: spaceId,
        name: "Cleanup Space",
        date: Date(timeIntervalSince1970: 1)
      ).insert(db)
      try Chat(
        id: chatId,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "Private Thread",
        spaceId: spaceId,
        lastMsgId: nil,
        isPublic: false
      ).insert(db)

      var message = Message(
        messageId: messageId,
        fromId: userId,
        date: Date(timeIntervalSince1970: 3),
        text: "last message",
        peerUserId: nil,
        peerThreadId: chatId,
        chatId: chatId
      )
      try message.saveMessage(db)
      try Chat
        .filter(Chat.Columns.id == chatId)
        .updateAll(db, [Chat.Columns.lastMsgId.set(to: messageId)])

      try deleteLocalChatData(db, chatId: chatId)

      #expect(try Chat.fetchOne(db, id: chatId) == nil)
      #expect(try Message.filter(Message.Columns.chatId == chatId).fetchCount(db) == 0)
    }
  }
}
