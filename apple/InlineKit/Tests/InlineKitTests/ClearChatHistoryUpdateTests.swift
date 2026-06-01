import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Clear chat history update")
struct ClearChatHistoryUpdateTests {
  private let userId: Int64 = 1
  private let oldDate = Date(timeIntervalSince1970: 100)
  private let cutoffDate = Date(timeIntervalSince1970: 200)
  private let recentDate = Date(timeIntervalSince1970: 300)

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("peer retention orphans reply threads and deletes pins without materializing message ids")
  func peerRetentionClearsDerivedRowsByPredicate() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedChat(db, id: 101, spaceId: nil, lastMsgId: 1)
      try seedMessage(db, chatId: 101, messageId: 1, date: oldDate, pinned: true)
      try seedMessage(db, chatId: 101, messageId: 2, date: recentDate, pinned: true)
      try PinnedMessage(chatId: 101, messageId: 1, position: 0).insert(db)
      try PinnedMessage(chatId: 101, messageId: 2, position: 1).insert(db)
      try seedChat(db, id: 102, spaceId: nil, parentChatId: 101, parentMessageId: 1)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.peerID = makeThreadPeer(chatId: 101)
      update.beforeDate = Int64(cutoffDate.timeIntervalSince1970)
      update.deleteReplyThreads = false

      let reloadPeers = try update.apply(db, publishChanges: false)

      #expect(reloadPeers == [.thread(id: 101)])
      #expect(try messageIds(db, chatId: 101) == [2])
      #expect(try pinnedMessageIds(db, chatId: 101) == [2])

      let child = try #require(try Chat.fetchOne(db, id: 102))
      #expect(child.parentChatId == 101)
      #expect(child.parentMessageId == nil)

      let parent = try #require(try Chat.fetchOne(db, id: 101))
      #expect(parent.lastMsgId == 2)
    }
  }

  @Test("space reply deletion stays inside space and detaches retained descendants")
  func spaceReplyDeletionKeepsCrossSpaceDescendants() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedSpace(db, id: 10)
      try seedSpace(db, id: 20)
      try seedChat(db, id: 201, spaceId: 10, lastMsgId: 1)
      try seedMessage(db, chatId: 201, messageId: 1, date: oldDate)
      try seedChat(db, id: 202, spaceId: 10, lastMsgId: 1, parentChatId: 201, parentMessageId: 1)
      try seedMessage(db, chatId: 202, messageId: 1, date: oldDate)
      try seedChat(db, id: 203, spaceId: 20, parentChatId: 202, parentMessageId: 1)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.spaceID = 10
      update.deleteReplyThreads = true

      let reloadPeers = try update.apply(db, publishChanges: false)

      #expect(Set(reloadPeers) == Set([.thread(id: 201), .thread(id: 202), .thread(id: 203)]))
      #expect(try Chat.fetchOne(db, id: 202) == nil)

      let retained = try #require(try Chat.fetchOne(db, id: 203))
      #expect(retained.parentChatId == nil)
      #expect(retained.parentMessageId == nil)
      #expect(retained.spaceId == 20)
    }
  }

  @Test("peer full reply deletion does not require cached parent messages")
  func peerFullReplyDeletionUsesChatAnchorsWhenParentMessageIsMissing() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedChat(db, id: 301, spaceId: nil)
      try seedChat(db, id: 302, spaceId: nil, parentChatId: 301, parentMessageId: 10)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.peerID = makeThreadPeer(chatId: 301)
      update.deleteReplyThreads = true

      _ = try update.apply(db, publishChanges: false)

      #expect(try Chat.fetchOne(db, id: 302) == nil)
    }
  }

  @Test("peer retention applies server-side orphaned thread ids")
  func peerRetentionUsesServerSideEffectIdsWhenParentMessageIsMissing() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedChat(db, id: 601, spaceId: nil)
      try seedChat(db, id: 602, spaceId: nil, parentChatId: 601, parentMessageId: 10)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.peerID = makeThreadPeer(chatId: 601)
      update.beforeDate = Int64(cutoffDate.timeIntervalSince1970)
      update.deleteReplyThreads = false
      update.orphanedChatIds = [602]

      let reloadPeers = try update.apply(db, publishChanges: false)

      let retained = try #require(try Chat.fetchOne(db, id: 602))
      #expect(retained.parentChatId == 601)
      #expect(retained.parentMessageId == nil)
      #expect(Set(reloadPeers) == Set([.thread(id: 601), .thread(id: 602)]))
    }
  }

  @Test("space full reply deletion does not require cached parent messages")
  func spaceFullReplyDeletionUsesChatAnchorsWhenParentMessageIsMissing() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedSpace(db, id: 30)
      try seedChat(db, id: 401, spaceId: 30)
      try seedChat(db, id: 402, spaceId: 30, parentChatId: 401, parentMessageId: 10)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.spaceID = 30
      update.deleteReplyThreads = true

      _ = try update.apply(db, publishChanges: false)

      #expect(try Chat.fetchOne(db, id: 402) == nil)
    }
  }

  @Test("space full clear detaches external reply threads without cached parent messages")
  func spaceFullClearDetachesExternalReplyThreadsWhenParentMessageIsMissing() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedSpace(db, id: 40)
      try seedSpace(db, id: 50)
      try seedChat(db, id: 501, spaceId: 40)
      try seedChat(db, id: 502, spaceId: 50, parentChatId: 501, parentMessageId: 10)
      try seedMessage(db, chatId: 502, messageId: 1, date: oldDate)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.spaceID = 40
      update.deleteReplyThreads = true

      let reloadPeers = try update.apply(db, publishChanges: false)

      let retained = try #require(try Chat.fetchOne(db, id: 502))
      #expect(retained.parentChatId == nil)
      #expect(retained.parentMessageId == nil)
      #expect(try messageIds(db, chatId: 502) == [1])
      #expect(Set(reloadPeers) == Set([.thread(id: 501), .thread(id: 502)]))
    }
  }

  @Test("space retention applies server-side deleted thread ids")
  func spaceRetentionUsesServerDeletedThreadIdsWhenParentMessageIsMissing() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedSpace(db, id: 70)
      try seedChat(db, id: 701, spaceId: 70)
      try seedChat(db, id: 702, spaceId: 70, parentChatId: 701, parentMessageId: 10)
      try seedMessage(db, chatId: 702, messageId: 1, date: oldDate)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.spaceID = 70
      update.beforeDate = Int64(cutoffDate.timeIntervalSince1970)
      update.deleteReplyThreads = true
      update.deletedChatIds = [702]

      let reloadPeers = try update.apply(db, publishChanges: false)

      #expect(try Chat.fetchOne(db, id: 702) == nil)
      #expect(Set(reloadPeers) == Set([.thread(id: 701), .thread(id: 702)]))
    }
  }

  @Test("space retention applies server-side detached external thread ids")
  func spaceRetentionUsesServerDetachedThreadIdsWhenParentMessageIsMissing() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try seedUser(db)
      try seedSpace(db, id: 80)
      try seedSpace(db, id: 90)
      try seedChat(db, id: 801, spaceId: 80)
      try seedChat(db, id: 902, spaceId: 90, parentChatId: 801, parentMessageId: 10)

      var update = InlineProtocol.UpdateClearChatHistory()
      update.spaceID = 80
      update.beforeDate = Int64(cutoffDate.timeIntervalSince1970)
      update.deleteReplyThreads = false
      update.detachedChatIds = [902]

      let reloadPeers = try update.apply(db, publishChanges: false)

      let retained = try #require(try Chat.fetchOne(db, id: 902))
      #expect(retained.parentChatId == nil)
      #expect(retained.parentMessageId == nil)
      #expect(Set(reloadPeers) == Set([.thread(id: 801), .thread(id: 902)]))
    }
  }

  private func seedUser(_ db: Database) throws {
    try User(id: userId, email: "history@example.com", firstName: "History", lastName: nil, username: "history")
      .insert(db)
  }

  private func seedSpace(_ db: Database, id: Int64) throws {
    try Space(id: id, name: "Space \(id)", date: oldDate).insert(db)
  }

  private func seedChat(
    _ db: Database,
    id: Int64,
    spaceId: Int64?,
    lastMsgId: Int64? = nil,
    parentChatId: Int64? = nil,
    parentMessageId: Int64? = nil
  ) throws {
    try Chat(
      id: id,
      date: oldDate,
      type: .thread,
      title: "Chat \(id)",
      spaceId: spaceId,
      lastMsgId: lastMsgId,
      parentChatId: parentChatId,
      parentMessageId: parentMessageId
    ).insert(db)
  }

  private func seedMessage(
    _ db: Database,
    chatId: Int64,
    messageId: Int64,
    date: Date,
    pinned: Bool = false
  ) throws {
    var message = Message(
      messageId: messageId,
      fromId: userId,
      date: date,
      text: "Message \(messageId)",
      peerUserId: nil,
      peerThreadId: chatId,
      chatId: chatId,
      pinned: pinned
    )
    try message.saveMessage(db)
  }

  private func makeThreadPeer(chatId: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatId }
  }

  private func messageIds(_ db: Database, chatId: Int64) throws -> [Int64] {
    try Message
      .filter(Message.Columns.chatId == chatId)
      .order(Message.Columns.messageId.asc)
      .select(Message.Columns.messageId)
      .asRequest(of: Int64.self)
      .fetchAll(db)
  }

  private func pinnedMessageIds(_ db: Database, chatId: Int64) throws -> [Int64] {
    try PinnedMessage
      .filter(PinnedMessage.Columns.chatId == chatId)
      .order(PinnedMessage.Columns.messageId.asc)
      .select(PinnedMessage.Columns.messageId)
      .asRequest(of: Int64.self)
      .fetchAll(db)
  }
}
