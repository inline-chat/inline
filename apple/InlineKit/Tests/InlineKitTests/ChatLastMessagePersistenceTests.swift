import Foundation
import GRDB
import InlineProtocol
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

  private func makeThreadPeer() -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatId }
  }

  private func makeThreadChat(lastMsgId: Int64?) -> InlineProtocol.Chat {
    var chat = InlineProtocol.Chat()
    chat.id = chatId
    chat.title = "Thread"
    chat.date = 1
    chat.peerID = makeThreadPeer()
    if let lastMsgId {
      chat.lastMsgID = lastMsgId
    }
    return chat
  }

  private func makeThreadDialog() -> InlineProtocol.Dialog {
    var dialog = InlineProtocol.Dialog()
    dialog.peer = makeThreadPeer()
    dialog.chatID = chatId
    return dialog
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

  @Test("chatOpen update does not persist a missing last message reference")
  func chatOpenUpdateIgnoresMissingLastMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var update = InlineProtocol.UpdateChatOpen()
      update.chat = makeThreadChat(lastMsgId: 42)
      update.dialog = makeThreadDialog()

      try update.apply(db)
    }

    try dbQueue.read { db in
      let savedChat = try #require(try Chat.fetchOne(db, id: chatId))
      let savedDialog = try #require(try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db))

      #expect(savedChat.lastMsgId == nil)
      #expect(savedDialog.chatId == chatId)
    }
  }

  @Test("newChat update does not persist a missing last message reference")
  func newChatUpdateIgnoresMissingLastMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var update = InlineProtocol.UpdateNewChat()
      update.chat = makeThreadChat(lastMsgId: 42)

      try update.apply(db)
    }

    try dbQueue.read { db in
      let savedChat = try #require(try Chat.fetchOne(db, id: chatId))
      let savedDialog = try #require(try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db))

      #expect(savedChat.lastMsgId == nil)
      #expect(savedDialog.chatId == chatId)
    }
  }

  @Test("chatMoved update does not persist a missing last message reference")
  func chatMovedUpdateIgnoresMissingLastMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var update = InlineProtocol.UpdateChatMoved()
      update.chat = makeThreadChat(lastMsgId: 42)
      update.oldSpaceID = 1
      update.newSpaceID = 2

      try update.apply(db)
    }

    try dbQueue.read { db in
      let savedChat = try #require(try Chat.fetchOne(db, id: chatId))
      let savedDialog = try #require(try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db))

      #expect(savedChat.lastMsgId == nil)
      #expect(savedDialog.chatId == chatId)
    }
  }
}
