import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Unread Replay Guard")
struct UnreadReplayGuardTests {
  private let chatId: Int64 = 1_000
  private let senderId: Int64 = 99

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedDialog(_ db: Database, readInboxMaxId: Int64?, unreadCount: Int) throws {
    try User(id: senderId, email: nil, firstName: "Sender", lastName: nil, username: nil).insert(db)
    try Chat(
      id: chatId,
      date: Date(timeIntervalSince1970: 1),
      type: .thread,
      title: "Thread",
      spaceId: nil
    ).insert(db)

    try Dialog(
      id: Dialog.getDialogId(peerId: .thread(id: chatId)),
      peerUserId: nil,
      peerThreadId: chatId,
      spaceId: nil,
      unreadCount: unreadCount,
      readInboxMaxId: readInboxMaxId,
      readOutboxMaxId: nil,
      pinned: false,
      draftMessage: nil,
      archived: false,
      chatId: chatId,
      unreadMark: false,
      notificationSettings: nil
    ).insert(db)
  }

  private func makeNewMessageUpdate(messageId: Int64) -> InlineProtocol.UpdateNewMessage {
    var message = InlineProtocol.Message()
    message.id = messageId
    message.chatID = chatId
    message.fromID = senderId
    message.date = 2
    message.out = false
    message.peerID = .with {
      $0.chat.chatID = chatId
    }
    message.message = "msg-\(messageId)"

    var payload = InlineProtocol.UpdateNewMessage()
    payload.message = message
    return payload
  }

  @Test("replayed catch-up message does not increment unread after read cursor")
  func replayedMessageDoesNotIncrementUnread() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, readInboxMaxId: 20, unreadCount: 0)
      let update = makeNewMessageUpdate(messageId: 10)
      try update.apply(db, publishChanges: false, suppressNotifications: true)

      let dialog = try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db)
      #expect(dialog?.unreadCount == 0)
      #expect(dialog?.readInboxMaxId == 20)
    }
  }

  @Test("new incoming message still increments unread above read cursor")
  func newerMessageStillIncrementsUnread() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedDialog(db, readInboxMaxId: 20, unreadCount: 0)
      let update = makeNewMessageUpdate(messageId: 21)
      try update.apply(db, publishChanges: false, suppressNotifications: true)

      let dialog = try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db)
      #expect(dialog?.unreadCount == 1)
    }
  }
}
