import Foundation
import GRDB
import Testing

@testable import InlineKit

@MainActor
@Suite("Full message view model")
struct FullMessageViewModelTests {
  @Test("retargeting observes the requested message immediately")
  func retargetsMessageAndChatWithoutDeferringTheInitialValue() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)

    try queue.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      for chatId: Int64 in [100, 200] {
        try Chat(
          id: chatId,
          date: Date(timeIntervalSince1970: 1),
          type: .thread,
          title: "Thread",
          spaceId: nil
        ).insert(db)

        for messageId: Int64 in [1, 2] {
          var message = Message(
            messageId: messageId,
            fromId: 1,
            date: Date(timeIntervalSince1970: TimeInterval(messageId)),
            text: "\(chatId):\(messageId)",
            peerUserId: nil,
            peerThreadId: chatId,
            chatId: chatId
          )
          try message.saveMessage(db)
        }
      }
    }

    let model = FullMessageViewModel(db: database, messageId: 1, chatId: 100)
    #expect(model.fullMessage?.message.text == "100:1")

    model.fetchMessage(2, chatId: 100)
    #expect(model.fullMessage?.message.text == "100:2")
    #expect(model.messageId == 2)
    #expect(model.chatId == 100)

    model.fetchMessage(1, chatId: 200)
    #expect(model.fullMessage?.message.text == "200:1")
    #expect(model.messageId == 1)
    #expect(model.chatId == 200)

    model.fetchMessage(3, chatId: 200)
    #expect(model.fullMessage == nil)
    #expect(model.messageId == 3)
  }
}
