import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing
@preconcurrency import UserNotifications

@testable import InlineKit
@testable import Auth

@Suite("Automatic read frontier")
struct AutomaticReadFrontierTests {
  @Test("hole-free coverage advances a positive monotonic marker")
  func holeFreeFrontier() {
    let coverage = makeCoverage(holes: [])

    #expect(coverage.certifiedReadMaxID(after: 10, through: 20) == 20)
    #expect(coverage.certifiedReadMaxID(after: 20, through: 20) == nil)
    #expect(coverage.certifiedReadMaxID(after: 20, through: -1) == nil)
    #expect(MessageHistoryCoverageProjection.unknown.certifiedReadMaxID(after: 10, through: 20) == nil)
  }

  @Test("the first unknown interval caps the automatic marker")
  func holeCapsFrontier() {
    let coverage = makeCoverage(holes: [21 ... 29, 41 ... 49])

    #expect(coverage.certifiedReadMaxID(after: 10, through: 50) == 20)
    #expect(coverage.certifiedReadMaxID(after: 30, through: 50) == 40)
  }

  @Test("unknown history adjacent to or spanning the frontier rejects advancement")
  func adjacentHoleRejectsFrontier() {
    let adjacent = makeCoverage(holes: [11 ... 20])
    let spanning = makeCoverage(holes: [5 ... 20])

    #expect(adjacent.certifiedReadMaxID(after: 10, through: 30) == nil)
    #expect(spanning.certifiedReadMaxID(after: 10, through: 30) == nil)
  }

  @Test("automatic retry delay is jittered and capped")
  func boundedRetryDelay() {
    let firstLow = AutomaticReadRetryPolicy.delaySeconds(failureCount: 1, jitterUnit: 0)
    let firstHigh = AutomaticReadRetryPolicy.delaySeconds(failureCount: 1, jitterUnit: 1)
    let capped = AutomaticReadRetryPolicy.delaySeconds(failureCount: 100, jitterUnit: 1)

    #expect(firstLow >= 0.4)
    // Computing 0.5 * (0.8 + 0.4) can round one ULP above the decimal bound.
    #expect(firstHigh <= 0.6.nextUp)
    #expect(capped == AutomaticReadRetryPolicy.maximumDelaySeconds)
    #expect(AutomaticReadRetryPolicy.shouldRetry(TransactionError2.timeout))
    #expect(!AutomaticReadRetryPolicy.shouldRetry(TransactionError2.invalid))
  }

  @Test("bounded reads encode a concrete marker and disable mark-all optimism")
  func boundedTransactionContract() throws {
    let bounded = ReadMessagesTransaction(peerId: .user(id: 7), maxId: 42)
    #expect(bounded.context.maxId == 42)
    #expect(bounded.context.intentId == nil)
    #expect(bounded.reconnectReplayPolicy == .replaySafe)

    guard case let .readMessages(input)? = bounded.input(from: bounded.context) else {
      Issue.record("Expected readMessages input")
      return
    }
    #expect(input.hasMaxID)
    #expect(input.maxID == 42)

    let markAll = ReadMessagesTransaction(peerId: .user(id: 7), maxId: nil)
    #expect(markAll.context.maxId == nil)
    #expect(markAll.context.intentId != nil)
    #expect(markAll.reconnectReplayPolicy == .neverReplay)
    #expect(markAll.executionKey == MarkAsUnreadTransaction(peerId: .user(id: 7)).executionKey)
    guard case let .readMessages(markAllInput)? = markAll.input(from: markAll.context) else {
      Issue.record("Expected mark-all readMessages input")
      return
    }
    #expect(!markAllInput.hasMaxID)
  }

  @Test("admission revalidates persisted holes instead of stale UI coverage")
  func persistedAdmissionCapsAtCurrentHole() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 10)
      try seedMessage(db, messageID: 50)
      try MessageHistoryHole(chatId: testChatID, lowerId: 21, upperId: 29).insert(db)

      let admission = try AutomaticReadAdmission.resolve(
        db,
        peerId: .thread(id: testChatID),
        chatId: testChatID,
        highestVisibleIncomingID: 50
      )
      #expect(admission == AutomaticReadAdmission(currentReadMaxID: 10, certifiedMaxID: 20))
    }
  }

  @Test("admission rejects missing, outgoing, service, and wrong-peer candidates")
  func admissionRejectsUntrustedCandidates() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 10)
      try seedMessage(db, messageID: 20, out: true)
      try seedMessage(db, messageID: 30, service: true)
      try seedMessage(db, messageID: 40)

      let peer = InlineKit.Peer.thread(id: testChatID)
      #expect(try AutomaticReadAdmission.resolve(
        db,
        peerId: peer,
        chatId: testChatID,
        highestVisibleIncomingID: 999
      ) == nil)
      #expect(try AutomaticReadAdmission.resolve(
        db,
        peerId: peer,
        chatId: testChatID,
        highestVisibleIncomingID: 20
      ) == nil)
      #expect(try AutomaticReadAdmission.resolve(
        db,
        peerId: peer,
        chatId: testChatID,
        highestVisibleIncomingID: 30
      ) == nil)
      #expect(try AutomaticReadAdmission.resolve(
        db,
        peerId: .user(id: testSenderID),
        chatId: testChatID,
        highestVisibleIncomingID: 40
      ) == nil)
      #expect(try AutomaticReadAdmission.resolve(
        db,
        peerId: peer,
        chatId: testChatID,
        highestVisibleIncomingID: -1
      ) == nil)
    }
  }

  @Test("retained reads lose admission after coverage invalidation or a later unread intent")
  func retainedAdmissionRechecksCurrentProjection() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 10)
      try seedMessage(db, messageID: 50)
      let demand = AutomaticReadDemand(maxID: 50, highestVisibleIncomingID: 50, unreadMark: false)
      let peer = InlineKit.Peer.thread(id: testChatID)
      #expect(try AutomaticReadAdmission.stillAdmits(db, peerId: peer, chatId: testChatID, demand: demand))

      try MessageHistoryHole(chatId: testChatID, lowerId: 21, upperId: 29).insert(db)
      #expect(try !AutomaticReadAdmission.stillAdmits(db, peerId: peer, chatId: testChatID, demand: demand))
      try MessageHistoryCoverageStore.subtract(db, chatId: testChatID, lowerId: 21, upperId: 29)
      try markUnreadUpdate(true).apply(db)
      #expect(try !AutomaticReadAdmission.stillAdmits(db, peerId: peer, chatId: testChatID, demand: demand))
    }
  }

  @Test("reading lowers the count by the stored messages the server counts, and moves the cursor here")
  func localReadLowersCount() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 10, unreadCount: 5, unreadMark: true, serverReadMaxID: 10)
      for id: Int64 in [11, 13, 14, 15, 16] { try seedMessage(db, messageID: id) }
      try seedMessage(db, messageID: 12, service: true)
      try Chat.filter(Chat.Columns.id == testChatID).updateAll(db, Chat.Columns.lastMsgId.set(to: 16))
      let peer = InlineKit.Peer.thread(id: testChatID)

      #expect(try Dialog.applyLocalRead(db, peerId: peer, through: 13) == .advanced(throughId: 13))
      var dialog = try #require(try Dialog.get(peerId: peer).fetchOne(db))
      // 11 and 13; the service row was never counted.
      #expect(dialog.unreadCount == 3)
      #expect(dialog.readInboxMaxId == 13)
      #expect(dialog.unreadMark == false)
      #expect(try Dialog.pendingReadMaxId(db, dialogId: dialog.id) == 13)

      #expect(try Dialog.applyLocalRead(db, peerId: peer, through: 12) == .unchanged)
      // Through the chat's last message everything is read.
      #expect(try Dialog.applyLocalRead(db, peerId: peer, through: 16) == .advanced(throughId: 16))
      dialog = try #require(try Dialog.get(peerId: peer).fetchOne(db))
      #expect(dialog.unreadCount == 0)

      try Dialog.confirmServerRead(db, dialogId: dialog.id, through: 16)
      #expect(try Dialog.pendingReadMaxId(db, dialogId: dialog.id) == nil)
      #expect(try Dialog.pendingReadPeers(db).isEmpty)
    }
  }

  @Test("reading to the end takes the chat's last message, and clears a mark on its own")
  func localReadToEnd() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 10, unreadCount: 2, serverReadMaxID: 10)
      try seedMessage(db, messageID: 30)
      try Chat.filter(Chat.Columns.id == testChatID).updateAll(db, Chat.Columns.lastMsgId.set(to: 30))
      let peer = InlineKit.Peer.thread(id: testChatID)

      #expect(try Dialog.applyLocalReadToEnd(db, peerId: peer) == .advanced(throughId: 30))
      #expect(try Dialog.pendingReadPeers(db) == [peer])
      #expect(try Dialog.applyLocalReadToEnd(db, peerId: peer) == .unchanged)

      try Dialog.confirmServerRead(db, dialogId: Dialog.getDialogId(peerId: peer), through: 30)
      try markUnreadUpdate(true).apply(db)
      #expect(try Dialog.applyLocalReadToEnd(db, peerId: peer) == .clearedMark)
      #expect(try Dialog.get(peerId: peer).fetchOne(db)?.unreadMark == false)
    }
  }

  @Test("a server read behind a read made here confirms it without undoing it")
  func olderServerReadKeepsLocalRead() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 40, unreadCount: 8, serverReadMaxID: 40)
      try seedMessage(db, messageID: 60)
      try Chat.filter(Chat.Columns.id == testChatID).updateAll(db, Chat.Columns.lastMsgId.set(to: 60))
      let peer = InlineKit.Peer.thread(id: testChatID)
      // The reader reached the bottom while an earlier scroll read was still on its way.
      _ = try Dialog.applyLocalReadToEnd(db, peerId: peer)

      try readUpdate(maxID: 50, unreadCount: 3).apply(db)
      var dialog = try #require(try Dialog.get(peerId: peer).fetchOne(db))
      #expect(dialog.readInboxMaxId == 60)
      #expect(dialog.unreadCount == 0)
      #expect(dialog.serverReadInboxMaxId == 50)
      #expect(try Dialog.pendingReadMaxId(db, dialogId: dialog.id) == 60)

      // A server dialog from before the read keeps it too.
      try InlineProtocol.Dialog.with {
        $0.peer = .with { $0.chat.chatID = testChatID }
        $0.chatID = testChatID
        $0.readMaxID = 50
        $0.unreadCount = 3
        $0.unreadMark = true
      }.saveFull(db)
      dialog = try #require(try Dialog.get(peerId: peer).fetchOne(db))
      #expect(dialog.readInboxMaxId == 60)
      #expect(dialog.unreadCount == 0)
      #expect(dialog.unreadMark == false)

      try readUpdate(maxID: 60, unreadCount: 0).apply(db)
      #expect(try Dialog.pendingReadMaxId(db, dialogId: dialog.id) == nil)
    }
  }

  @Test("another device reading further moves the cursor and takes its count")
  func newerServerReadApplies() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 40, unreadCount: 8, serverReadMaxID: 40)
      try readUpdate(maxID: 55, unreadCount: 2).apply(db)
      let dialog = try #require(try Dialog.get(peerId: .thread(id: testChatID)).fetchOne(db))
      #expect(dialog.readInboxMaxId == 55)
      #expect(dialog.serverReadInboxMaxId == 55)
      #expect(dialog.unreadCount == 2)
      #expect(try Dialog.pendingReadPeers(db).isEmpty)
    }
  }

  @Test("read updates cannot regress the frontier or erase a later mark-unread")
  func readUpdateOrderingIsMonotonic() throws {
    let queue = try makeDatabase()
    try queue.write { (db: Database) throws in
      try seedThread(db, readMaxID: 50, unreadCount: 3, unreadMark: true)

      try readUpdate(maxID: 40, unreadCount: 0).apply(db)
      var dialog = try #require(try Dialog.get(peerId: .thread(id: testChatID)).fetchOne(db))
      #expect(dialog.readInboxMaxId == 50)
      #expect(dialog.unreadCount == 3)
      #expect(dialog.unreadMark == true)

      try readUpdate(maxID: 50, unreadCount: 0).apply(db)
      dialog = try #require(try Dialog.get(peerId: .thread(id: testChatID)).fetchOne(db))
      #expect(dialog.unreadCount == 3)
      #expect(dialog.unreadMark == true)

      try readUpdate(maxID: 60, unreadCount: 1).apply(db)
      dialog = try #require(try Dialog.get(peerId: .thread(id: testChatID)).fetchOne(db))
      #expect(dialog.readInboxMaxId == 60)
      #expect(dialog.unreadCount == 1)
      #expect(dialog.unreadMark == false)

      try markUnreadUpdate(true).apply(db)
      try readUpdate(maxID: 60, unreadCount: 0).apply(db)
      dialog = try #require(try Dialog.get(peerId: .thread(id: testChatID)).fetchOne(db))
      #expect(dialog.unreadMark == true)
    }
  }

  @Test("notification cleanup rejects another account's payload")
  func notificationCleanupIsAccountScoped() {
    let content = UNMutableNotificationContent()
    content.threadIdentifier = "chat_\(testChatID)"
    content.userInfo = [
      "messageId": "20",
      "recipientUserId": "99",
    ]

    #expect(!NotificationCleanup.shouldRemove(
      content: content,
      threadId: "chat_\(testChatID)",
      upToMessageId: 20,
      recipientUserID: 1
    ))
    #expect(NotificationCleanup.shouldRemove(
      content: content,
      threadId: "chat_\(testChatID)",
      upToMessageId: 20,
      recipientUserID: 99
    ))
  }
}

private func makeCoverage(holes: [ClosedRange<Int64>]) -> MessageHistoryCoverageProjection {
  MessageHistoryCoverageProjection(
    messages: [],
    holes: holes.map {
      MessageHistoryHole(chatId: 1, lowerId: $0.lowerBound, upperId: $0.upperBound)
    },
    olderCandidateMessageID: nil,
    newerCandidateMessageID: nil
  )
}

private let testChatID: Int64 = 700
private let testSenderID: Int64 = 701

private func makeDatabase() throws -> DatabaseQueue {
  let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
  _ = try AppDatabase(queue)
  return queue
}

private func seedThread(
  _ db: Database,
  readMaxID: Int64,
  unreadCount: Int = 5,
  unreadMark: Bool = false,
  serverReadMaxID: Int64? = nil
) throws {
  try User(
    id: testSenderID,
    email: "automatic-read@example.com",
    firstName: "Automatic"
  ).insert(db)
  try Chat(
    id: testChatID,
    date: Date(timeIntervalSince1970: 1),
    type: .thread,
    title: "Automatic Read",
    spaceId: nil
  ).insert(db)
  try Dialog(
    id: Dialog.getDialogId(peerId: .thread(id: testChatID)),
    peerUserId: nil,
    peerThreadId: testChatID,
    spaceId: nil,
    unreadCount: unreadCount,
    readInboxMaxId: readMaxID,
    readOutboxMaxId: nil,
    pinned: false,
    draftMessage: nil,
    archived: false,
    chatId: testChatID,
    unreadMark: unreadMark,
    notificationSettings: nil,
    serverReadInboxMaxId: serverReadMaxID
  ).insert(db)
  // These fixtures start from a certified history; individual tests add the
  // exact unknown intervals they exercise after the new-chat trigger ran.
  try MessageHistoryCoverageStore.subtract(
    db, chatId: testChatID, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax
  )
}

private func seedMessage(
  _ db: Database,
  messageID: Int64,
  out: Bool = false,
  service: Bool = false
) throws {
  let contentPayload: Client_MessageContentPayload? = service ? .with {
    $0.serviceMessage = .with {
      $0.pinnedMessage = .with { $0.messageID = 1 }
    }
  } : nil
  try Message(
    messageId: messageID,
    fromId: testSenderID,
    date: Date(timeIntervalSince1970: TimeInterval(messageID)),
    text: "message-\(messageID)",
    peerUserId: nil,
    peerThreadId: testChatID,
    chatId: testChatID,
    out: out,
    contentPayload: contentPayload
  ).insert(db)
}

private func readUpdate(maxID: Int64, unreadCount: Int32) -> InlineProtocol.UpdateReadMaxId {
  var update = InlineProtocol.UpdateReadMaxId()
  update.peerID = .with { $0.chat.chatID = testChatID }
  update.readMaxID = maxID
  update.unreadCount = unreadCount
  return update
}

private func markUnreadUpdate(_ unread: Bool) -> InlineProtocol.UpdateMarkAsUnread {
  var update = InlineProtocol.UpdateMarkAsUnread()
  update.peerID = .with { $0.chat.chatID = testChatID }
  update.unreadMark = unread
  return update
}
