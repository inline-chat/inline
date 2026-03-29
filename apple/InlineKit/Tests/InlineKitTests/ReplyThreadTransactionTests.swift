import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Reply thread transactions")
struct ReplyThreadTransactionTests {
  private let childChatId: Int64 = 41
  private let parentChatId: Int64 = 7
  private let parentMessageId: Int64 = 99
  private let senderId: Int64 = 123

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedParentContext(_ db: Database) throws {
    try User(
      id: senderId,
      email: nil,
      firstName: "Sender",
      lastName: nil,
      username: nil
    ).insert(db)

    try Chat(
      id: parentChatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Parent Thread",
      spaceId: nil
    ).insert(db)
  }

  private func makeChildChat() -> InlineProtocol.Chat {
    .with {
      $0.id = childChatId
      $0.date = 2
      $0.title = "Reply Thread"
      $0.peerID = .with {
        $0.chat.chatID = childChatId
      }
      $0.parentChatID = parentChatId
      $0.parentMessageID = parentMessageId
    }
  }

  private func makeChildDialog() -> InlineProtocol.Dialog {
    .with {
      $0.peer = .with {
        $0.chat.chatID = childChatId
      }
      $0.chatID = childChatId
      $0.unreadCount = 0
      $0.pinned = false
      $0.archived = false
      $0.unreadMark = false
    }
  }

  private func makeAnchorMessage() -> InlineProtocol.Message {
    .with {
      $0.id = parentMessageId
      $0.chatID = parentChatId
      $0.fromID = senderId
      $0.date = 3
      $0.peerID = .with {
        $0.chat.chatID = parentChatId
      }
      $0.message = "anchor"
    }
  }

  @Test("GetChatTransaction saves anchorMessage into the parent chat")
  func getChatSavesAnchorMessage() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedParentContext(db)

      let response = InlineProtocol.GetChatResult.with {
        $0.chat = makeChildChat()
        $0.dialog = makeChildDialog()
        $0.anchorMessage = makeAnchorMessage()
      }

      try GetChatTransaction.persist(response, in: db)

      let childChat = try Chat.fetchOne(db, id: childChatId)
      let dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: .thread(id: childChatId)))
      let anchorMessage = try Message.fetchOne(
        db,
        key: ["messageId": parentMessageId, "chatId": parentChatId]
      )

      #expect(childChat?.parentChatId == parentChatId)
      #expect(childChat?.parentMessageId == parentMessageId)
      #expect(dialog?.chatId == childChatId)
      #expect(anchorMessage?.text == "anchor")
    }
  }

  @Test("GetChatTransaction still saves reply thread chat and anchorMessage when dialog is omitted")
  func getChatWithoutDialogStillPersistsReplyThreadContext() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedParentContext(db)

      let response = InlineProtocol.GetChatResult.with {
        $0.chat = makeChildChat()
        $0.anchorMessage = makeAnchorMessage()
      }

      try GetChatTransaction.persist(response, in: db)

      let childChat = try Chat.fetchOne(db, id: childChatId)
      let dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: .thread(id: childChatId)))
      let anchorMessage = try Message.fetchOne(
        db,
        key: ["messageId": parentMessageId, "chatId": parentChatId]
      )

      #expect(childChat?.parentChatId == parentChatId)
      #expect(childChat?.parentMessageId == parentMessageId)
      #expect(dialog == nil)
      #expect(anchorMessage?.text == "anchor")
    }
  }

  @Test("GetChatTransaction creates a placeholder parent chat so anchorMessage is available on first load")
  func getChatCreatesPlaceholderParentChatWhenMissing() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try User(
        id: senderId,
        email: nil,
        firstName: "Sender",
        lastName: nil,
        username: nil
      ).insert(db)

      let response = InlineProtocol.GetChatResult.with {
        $0.chat = makeChildChat()
        $0.dialog = makeChildDialog()
        $0.anchorMessage = makeAnchorMessage()
      }

      try GetChatTransaction.persist(response, in: db)

      let placeholderParentChat = try Chat.fetchOne(db, id: parentChatId)
      let anchorMessage = try Message.fetchOne(
        db,
        key: ["messageId": parentMessageId, "chatId": parentChatId]
      )

      #expect(placeholderParentChat != nil)
      #expect(anchorMessage?.text == "anchor")
    }
  }

  @Test("CreateSubthreadTransaction saves chat, dialog, and anchorMessage")
  func createSubthreadSavesReturnedEntities() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedParentContext(db)

      let response = InlineProtocol.CreateSubthreadResult.with {
        $0.chat = makeChildChat()
        $0.dialog = makeChildDialog()
        $0.anchorMessage = makeAnchorMessage()
      }

      try CreateSubthreadTransaction.persist(response, in: db)

      let childChat = try Chat.fetchOne(db, id: childChatId)
      let dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: .thread(id: childChatId)))
      let anchorMessage = try Message.fetchOne(
        db,
        key: ["messageId": parentMessageId, "chatId": parentChatId]
      )

      #expect(childChat?.parentChatId == parentChatId)
      #expect(childChat?.parentMessageId == parentMessageId)
      #expect(dialog?.chatId == childChatId)
      #expect(anchorMessage?.text == "anchor")
    }
  }
}
