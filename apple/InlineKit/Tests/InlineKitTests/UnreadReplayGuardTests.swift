import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("Unread Replay Guard")
struct UnreadReplayGuardTests {
  @Test("quiet transcript rows persist and advance history without changing unread")
  func quietTranscriptDoesNotIncrementUnread() throws {
    let dbQueue = try makeInMemoryDB()
    try dbQueue.write { (db: Database) throws in
      try seedDialog(db, readInboxMaxId: 20, unreadCount: 2)
      var update = makeNewMessageUpdate(messageId: 21)
      update.message.countsAsUnread = false
      update.message.serviceMessage.gridTranscript = .with {
        $0.runID = "run-1"
        $0.segmentID = "segment-1"
      }
      try update.apply(db, publishChanges: false, suppressNotifications: true)
      #expect(try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db)?.unreadCount == 2)
      let fetched = try Message.fetchOne(db, key: ["messageId": 21, "chatId": chatId])
      let saved = try #require(fetched)
      #expect(saved.isGridTranscript)
      #expect(!saved.countsAsUnread)
      #expect(try Chat.fetchOne(db, key: chatId)?.lastMsgId == nil)
      // A replay must preserve durable quietness as well as deduplication.
      try update.apply(db, publishChanges: false, suppressNotifications: true)
      #expect(try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db)?.unreadCount == 2)
    }
  }

  @Test("transcripts stay out of sidebar activity during history and chat-tail deletion")
  func transcriptActivityHistoryAndDeletion() throws {
    let queue = try makeInMemoryDB()
    try queue.write { (db: Database) throws in
      try seedDialog(db, readInboxMaxId: 20, unreadCount: 0)
      let earlier = makeNewMessageUpdate(messageId: 1)
      try earlier.apply(db, publishChanges: false, suppressNotifications: true)
      var transcript = makeNewMessageUpdate(messageId: 2)
      transcript.message.date = 5
      transcript.message.serviceMessage.gridTranscript = .init()
      transcript.message.countsAsUnread = false
      try transcript.apply(db, publishChanges: false, suppressNotifications: true)
      #expect(try Chat.fetchOne(db, key: chatId)?.lastMsgId == 1)
      var later = makeNewMessageUpdate(messageId: 3)
      later.message.date = 4
      try later.apply(db, publishChanges: false, suppressNotifications: true)
      try Chat.updateLastMsgIds(db, messages: [Message(from: earlier.message), Message(from: transcript.message)])
      #expect(try Chat.fetchOne(db, key: chatId)?.lastMsgId == 3)

      let deletion = InlineProtocol.UpdateDeleteMessages.with {
        $0.peerID.chat.chatID = chatId
        $0.messageIds = [3]
      }
      try deletion.apply(db, publishChanges: false)
      #expect(try Chat.fetchOne(db, key: chatId)?.lastMsgId == 1)
      #expect(try Message.filter(Message.Columns.chatId == chatId && Message.Columns.messageId == 1)
        .fetchOne(db)?.date == Date(timeIntervalSince1970: 2))
      try Message.deleteMessages(db, messageIds: [1], chatId: chatId)
      #expect(try Chat.fetchOne(db, key: chatId)?.lastMsgId == nil)
      #expect(try Message.fetchCount(db) == 1)
    }
  }

  private let chatId: Int64 = 1_000
  private let senderId: Int64 = 99

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
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

  private func makeNewMessageUpdate(
    messageId: Int64,
    forwardThreadId: Int64? = nil,
    forwardUserId: Int64? = nil
  ) -> InlineProtocol.UpdateNewMessage {
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

    if let forwardThreadId {
      var header = InlineProtocol.MessageFwdHeader()
      header.fromPeerID = .with {
        $0.chat.chatID = forwardThreadId
      }
      header.fromID = forwardUserId ?? senderId
      header.fromMessageID = 1
      message.fwdFrom = header
    }

    var payload = InlineProtocol.UpdateNewMessage()
    payload.message = message
    return payload
  }

  private func makeProtocolChat(id: Int64, parentChatId: Int64? = nil) -> InlineProtocol.Chat {
    var chat = InlineProtocol.Chat()
    chat.id = id
    chat.date = 1
    chat.peerID = .with {
      $0.chat.chatID = id
    }
    if let parentChatId {
      chat.parentChatID = parentChatId
      chat.parentMessageID = 1
    }
    return chat
  }

  @Test("replayed catch-up message does not increment unread after read cursor")
  func replayedMessageDoesNotIncrementUnread() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { (db: Database) throws in
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

    try dbQueue.write { (db: Database) throws in
      try seedDialog(db, readInboxMaxId: 20, unreadCount: 0)
      let update = makeNewMessageUpdate(messageId: 21)
      try update.apply(db, publishChanges: false, suppressNotifications: true)

      let dialog = try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db)
      #expect(dialog?.unreadCount == 1)
    }
  }

  @Test("sync catch-up message does not increment sidecar unread total")
  func catchupMessageDoesNotIncrementSidecarUnreadTotal() async throws {
    let dbQueue = try makeInMemoryDB()
    let engine = UpdatesEngine(database: try AppDatabase(dbQueue))

    try await dbQueue.write { (db: Database) throws in
      try seedDialog(db, readInboxMaxId: nil, unreadCount: 1)
    }

    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 2
    update.update = .newMessage(makeNewMessageUpdate(messageId: 1))
    let applied = await engine.applyBatch(updates: [update], source: .syncCatchup)

    #expect(applied.succeeded)
    #expect(applied.appliedCount == 1)
    try await dbQueue.read { (db: Database) throws in
      let dialog = try Dialog.get(peerId: .thread(id: chatId)).fetchOne(db)
      #expect(dialog?.unreadCount == 1)

      let message = try Message.fetchOne(db, key: ["messageId": 1, "chatId": chatId])
      #expect(message != nil)
    }
  }

  @Test("thread message materializes missing local chat references")
  func threadMessageMaterializesMissingChatReferences() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { (db: Database) throws in
      let update = makeNewMessageUpdate(messageId: 1)
      try update.apply(
        db,
        publishChanges: false,
        suppressNotifications: true,
        materializeMissingReferences: true
      )

      let chat = try #require(try Chat.fetchOne(db, id: chatId))
      #expect(chat.type == .thread)
      #expect(chat.lastMsgId == 1)

      let sender = try User.fetchOne(db, id: senderId)
      #expect(sender != nil)

      let message = try Message.fetchOne(db, key: ["messageId": 1, "chatId": chatId])
      #expect(message?.peerThreadId == chatId)
    }
  }

  @Test("live thread message keeps missing chat strict")
  func liveThreadMessageKeepsMissingChatStrict() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { (db: Database) throws in
      let update = makeNewMessageUpdate(messageId: 1)
      var didThrow = false

      do {
        try update.apply(db, publishChanges: false, suppressNotifications: true)
      } catch {
        didThrow = true
      }

      #expect(didThrow)
      let chat = try Chat.fetchOne(db, id: chatId)
      #expect(chat == nil)
    }
  }

  @Test("updates engine live message materializes missing chat references")
  func updatesEngineLiveMessageMaterializesMissingChatReferences() async throws {
    let dbQueue = try makeInMemoryDB()
    let engine = UpdatesEngine(database: try AppDatabase(dbQueue))

    var update = InlineProtocol.Update()
    update.update = .newMessage(makeNewMessageUpdate(messageId: 1))
    let applied = await engine.applyBatch(updates: [update], source: .realtime)

    #expect(applied.succeeded)
    #expect(applied.appliedCount == 1)
    try await dbQueue.read { (db: Database) throws in
      let chat = try #require(try Chat.fetchOne(db, id: chatId))
      #expect(chat.type == .thread)
      let sender = try User.fetchOne(db, id: senderId)
      #expect(sender != nil)
      let message = try Message.fetchOne(db, key: ["messageId": 1, "chatId": chatId])
      #expect(message != nil)
    }
  }

  @Test("catch-up message materializes missing forwarded references")
  func catchupMessageMaterializesMissingForwardedReferences() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { (db: Database) throws in
      let forwardThreadId: Int64 = 2_000
      let forwardUserId: Int64 = 101
      let update = makeNewMessageUpdate(
        messageId: 1,
        forwardThreadId: forwardThreadId,
        forwardUserId: forwardUserId
      )

      try update.apply(
        db,
        publishChanges: false,
        suppressNotifications: true,
        materializeMissingReferences: true
      )

      let forwardChat = try Chat.fetchOne(db, id: forwardThreadId)
      #expect(forwardChat?.type == .thread)

      let forwardUser = try User.fetchOne(db, id: forwardUserId)
      #expect(forwardUser != nil)

      let message = try Message.fetchOne(db, key: ["messageId": 1, "chatId": chatId])
      #expect(message?.forwardFromPeerThreadId == forwardThreadId)
      #expect(message?.forwardFromUserId == forwardUserId)
    }
  }

  @Test("sidecar chats keep in-batch parent before child")
  func sidecarChatsKeepInBatchParentBeforeChild() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { (db: Database) throws in
      let parent = makeProtocolChat(id: 2_000)
      let child = makeProtocolChat(id: 2_001, parentChatId: 2_000)

      let chats = try preparedSidecarChats([child, parent], db: db)

      #expect(chats.map(\.id) == [2_000, 2_001])
      #expect(chats.last?.parentChatId == 2_000)
      #expect(chats.last?.parentMessageId == 1)
    }
  }

  @Test("sidecar chat clears absent parent reference")
  func sidecarChatClearsAbsentParentReference() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { (db: Database) throws in
      let child = makeProtocolChat(id: 2_001, parentChatId: 2_000)

      let chats = try preparedSidecarChats([child], db: db)

      #expect(chats.map(\.id) == [2_001])
      #expect(chats.first?.parentChatId == nil)
      #expect(chats.first?.parentMessageId == nil)
    }
  }

  @Test("chatSkipPts applies as a catch-up no-op")
  func chatSkipPtsAppliesAsCatchupNoop() async throws {
    let dbQueue = try makeInMemoryDB()
    let engine = UpdatesEngine(database: try AppDatabase(dbQueue))

    var payload = InlineProtocol.UpdateChatSkipPts()
    payload.chatID = chatId
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .chatSkipPts(payload)
    let applied = await engine.applyBatch(updates: [update], source: .syncCatchup)

    #expect(applied.succeeded)
    #expect(applied.appliedCount == 1)
    try await dbQueue.read { (db: Database) throws -> Void in
      #expect(try Message.fetchCount(db) == 0)
    }
  }
}
