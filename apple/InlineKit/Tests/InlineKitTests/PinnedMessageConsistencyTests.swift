import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Pinned Message Consistency")
struct PinnedMessageConsistencyTests {
  private let chatId: Int64 = 700
  private let userId: Int64 = 1

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedChat(_ db: Database) throws {
    try User(id: userId, email: "user@example.com", firstName: "User", lastName: nil, username: "user")
      .insert(db)
    try Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Thread",
      spaceId: nil
    ).insert(db)
  }

  private func seedMessage(_ db: Database, id: Int64, pinned: Bool) throws {
    var message = Message(
      messageId: id,
      fromId: userId,
      date: Date(timeIntervalSince1970: TimeInterval(id)),
      text: "message-\(id)",
      peerUserId: nil,
      peerThreadId: chatId,
      chatId: chatId,
      pinned: pinned
    )
    try message.saveMessage(db)
  }

  @Test("replacing pinned list mirrors message pinned flags")
  func replaceAllMirrorsMessagePinnedFlags() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChat(db)
      try seedMessage(db, id: 1, pinned: true)
      try seedMessage(db, id: 2, pinned: false)
      try seedMessage(db, id: 3, pinned: true)

      try PinnedMessage.replaceAll(db, chatId: chatId, messageIds: [2])

      let pinnedIds = try PinnedMessage
        .filter(PinnedMessage.Columns.chatId == chatId)
        .order(PinnedMessage.Columns.position.asc)
        .fetchAll(db)
        .map(\.messageId)
      #expect(pinnedIds == [2])

      let messages = try Message
        .filter(Message.Columns.chatId == chatId)
        .order(Message.Columns.messageId.asc)
        .fetchAll(db)

      #expect(messages.map { $0.pinned == true } == [false, true, false])
    }
  }

  @Test("pin and unpin mirror message pinned flag")
  func pinAndUnpinMirrorMessagePinnedFlag() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChat(db)
      try seedMessage(db, id: 1, pinned: false)

      try PinnedMessage.pin(db, chatId: chatId, messageId: 1)
      var message = try #require(try Message.fetchOne(db, key: ["messageId": 1, "chatId": chatId]))
      #expect(message.pinned == true)
      #expect(try PinnedMessage.isPinned(db, chatId: chatId, messageId: 1))

      try PinnedMessage.unpin(db, chatId: chatId, messageId: 1)
      message = try #require(try Message.fetchOne(db, key: ["messageId": 1, "chatId": chatId]))
      #expect(message.pinned == false)
      #expect(try !PinnedMessage.isPinned(db, chatId: chatId, messageId: 1))
    }
  }

  @Test("protocol message save mirrors existing pinned table row")
  func protocolSaveMirrorsExistingPinnedTableRow() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedChat(db)
      try PinnedMessage.replaceAll(db, chatId: chatId, messageIds: [10])

      var proto = InlineProtocol.Message()
      proto.id = 10
      proto.chatID = chatId
      proto.fromID = userId
      proto.date = 10
      proto.out = false
      proto.peerID = .with {
        $0.chat.chatID = chatId
      }
      proto.message = "pinned later"

      _ = try Message.save(db, protocolMessage: proto, publishChanges: false)

      let message = try #require(try Message.fetchOne(db, key: ["messageId": 10, "chatId": chatId]))
      #expect(message.pinned == true)
    }
  }
}
