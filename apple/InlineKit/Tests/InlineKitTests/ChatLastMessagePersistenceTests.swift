import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Chat last message persistence")
struct ChatLastMessagePersistenceTests {
  private let chatId: Int64 = 910
  private let userId: Int64 = 1

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedUser(_ db: Database) throws {
    try User(id: userId, email: "user@example.com", firstName: "User", lastName: nil, username: "user")
      .insert(db)
  }

  private func seedChat(_ db: Database, title: String = "Thread") throws {
    try Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: title,
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

  @Test("saves chat when referenced last message is missing")
  func savesChatWithMissingLastMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var chat = Chat(
        id: chatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reply Thread",
        spaceId: nil,
        lastMsgId: 42
      )

      try chat.saveWithValidLastMsg(db)

      let saved = try #require(try Chat.fetchOne(db, id: chatId))
      #expect(saved.lastMsgId == nil)
    }
  }

  @Test("keeps last message when it exists locally")
  func keepsExistingLastMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedChat(db)
      try seedMessage(db, id: 42)

      var chat = Chat(
        id: chatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Reply Thread",
        spaceId: nil,
        lastMsgId: 42
      )

      try chat.saveWithValidLastMsg(db)

      let saved = try #require(try Chat.fetchOne(db, id: chatId))
      #expect(saved.lastMsgId == 42)
    }
  }

  @Test("preserves existing last message when incoming chat omits it")
  func preservesExistingLastMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedChat(db)
      try seedMessage(db, id: 7)

      var chat = Chat(
        id: chatId,
        date: Date(timeIntervalSince1970: 1),
        type: .thread,
        title: "Thread",
        spaceId: nil,
        lastMsgId: 7
      )
      try chat.saveWithValidLastMsg(db)

      var incoming = Chat(
        id: chatId,
        date: Date(timeIntervalSince1970: 2),
        type: .thread,
        title: "Renamed",
        spaceId: nil
      )
      try incoming.saveWithValidLastMsg(db)

      let saved = try #require(try Chat.fetchOne(db, id: chatId))
      #expect(saved.lastMsgId == 7)
      #expect(saved.title == "Renamed")
    }
  }
}
