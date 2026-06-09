import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Message Child Persistence")
struct MessageChildPersistenceTests {
  private let chatId: Int64 = 880
  private let userId: Int64 = 1

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedChat(_ db: Database) throws {
    try User(id: userId, email: "child@example.com", firstName: "Child", lastName: nil, username: "child")
      .insert(db)
    try Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Child Persistence",
      spaceId: nil
    ).insert(db)
  }

  private func seedMessage(_ db: Database, id: Int64) throws {
    var message = Message(
      messageId: id,
      fromId: userId,
      date: Date(timeIntervalSince1970: TimeInterval(id)),
      text: "message-\(id)",
      peerUserId: nil,
      peerThreadId: chatId,
      chatId: chatId
    )
    try message.saveMessage(db)
  }

  @Test("reaction save skips missing parent message")
  func reactionSaveSkipsMissingParentMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChat(db)

      var reaction = InlineProtocol.Reaction()
      reaction.messageID = 404
      reaction.chatID = chatId
      reaction.userID = userId
      reaction.emoji = "+1"
      reaction.date = 1

      let saved = try Reaction.save(db, protocolMessage: reaction)

      #expect(saved == false)
      #expect(try Reaction.fetchCount(db) == 0)
    }
  }

  @Test("protocol message saves embedded reactions after parent message")
  func protocolMessageSavesEmbeddedReactionsAfterParentMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChat(db)

      var proto = InlineProtocol.Message()
      proto.id = 10
      proto.chatID = chatId
      proto.fromID = userId
      proto.date = 10
      proto.peerID = .with {
        $0.chat.chatID = chatId
      }
      proto.message = "hello"
      proto.reactions = .with {
        $0.reactions = [
          .with {
            $0.messageID = 10
            $0.chatID = chatId
            $0.userID = userId
            $0.emoji = "+1"
            $0.date = 11
          },
        ]
      }

      _ = try Message.save(db, protocolMessage: proto, publishChanges: false)

      #expect(try Message.fetchCount(db) == 1)
      #expect(try Reaction.fetchCount(db) == 1)
    }
  }

  @Test("translation save skips missing parent message")
  func translationSaveSkipsMissingParentMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChat(db)

      var translation = InlineProtocol.MessageTranslation()
      translation.messageID = 404
      translation.language = "en"
      translation.translation = "missing"
      translation.date = 1
      translation.msgRev = 1

      let saved = try Translation.save(db, protocolTranslation: translation, chatId: chatId)

      #expect(saved == nil)
      #expect(try Translation.fetchCount(db) == 0)
    }
  }

  @Test("translation save persists when parent message exists")
  func translationSavePersistsWhenParentMessageExists() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChat(db)
      try seedMessage(db, id: 12)

      var translation = InlineProtocol.MessageTranslation()
      translation.messageID = 12
      translation.language = "en"
      translation.translation = "translated"
      translation.date = 1
      translation.msgRev = 1

      let saved = try Translation.save(db, protocolTranslation: translation, chatId: chatId)

      #expect(saved?.translation == "translated")
      #expect(try Translation.fetchCount(db) == 1)
    }
  }
}
