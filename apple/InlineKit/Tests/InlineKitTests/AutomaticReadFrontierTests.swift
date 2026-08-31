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

  @Test("coalescing keeps one in-flight marker and the highest pending marker")
  func monotonicCoalescing() {
    var state = AutomaticReadCoalescingState()

    #expect(state.enqueue(30) == 30)
    #expect(state.enqueue(20) == nil)
    #expect(state.enqueue(40) == nil)
    #expect(state.enqueue(35) == nil)
    #expect(state.inFlightMaxID == 30)
    #expect(state.pendingMaxID == 40)

    #expect(state.succeed(30) == 40)
    #expect(state.inFlightMaxID == 40)
    #expect(state.succeed(40) == nil)
    #expect(state.highestSuccessfulMaxID == 40)
    #expect(state.enqueue(40) == nil)
  }

  @Test("a failed marker remains owned and a higher pending marker supersedes its retry")
  func failedMarkerRemainsOwned() {
    var state = AutomaticReadCoalescingState()

    #expect(state.enqueue(50) == 50)
    #expect(state.retryTarget(afterFailureOf: 50) == 50)
    #expect(state.owns(50))
    #expect(state.enqueue(60) == nil)
    #expect(state.retryTarget(afterFailureOf: 50) == 60)
    #expect(state.owns(60))
    #expect(state.enqueue(59) == nil)
  }

  @Test("coalescing retains the visible source when a hole caps its concrete marker")
  func retainedDemandKeepsVisibleCandidate() {
    var state = AutomaticReadCoalescingState()
    #expect(state.enqueue(20, highestVisibleIncomingID: 50) == 20)
    #expect(state.inFlight?.highestVisibleIncomingID == 50)
    #expect(state.enqueue(60, highestVisibleIncomingID: 80) == nil)
    #expect(state.retryTarget(afterFailureOf: 20) == 60)
    #expect(state.inFlight?.highestVisibleIncomingID == 80)
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

  @Test("mark-unread cancels a suspended read submission and rejects pre-cancel visibility work")
  func explicitUnreadCancelsRetainedTask() async throws {
    let auth = Auth.mocked(authenticated: true)
    let owner = try auth.handle.beginAccountMutation()
    let gate = UnreadManager.VisibleReadGate(auth: auth.handle)
    let probe = AutomaticReadSuspensionProbe()
    let requestedAt = ContinuousClock.now
    let started = try await gate.enqueue(
      owner: owner, dialogId: 7,
      admission: .init(currentReadMaxID: 10, certifiedMaxID: 20),
      highestVisibleIncomingID: 20, requestedAt: requestedAt
    ) { _, _ in
      await probe.suspend()
      await probe.complete(cancelled: Task.isCancelled)
    }
    #expect(started)
    await probe.waitUntilSuspended()
    try await gate.cancel(owner: owner, dialogId: 7, at: ContinuousClock.now)
    await probe.release()
    #expect(await probe.waitUntilCompleted())

    let staleStarted = try await gate.enqueue(
      owner: owner, dialogId: 7,
      admission: .init(currentReadMaxID: 10, certifiedMaxID: 20),
      highestVisibleIncomingID: 20, requestedAt: requestedAt
    ) { _, _ in Issue.record("Pre-cancel visibility must not be submitted") }
    #expect(!staleStarted)
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

private actor AutomaticReadSuspensionProbe {
  private var suspended = false
  private var completion: Bool?
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var suspension: CheckedContinuation<Void, Never>?
  private var completionWaiter: CheckedContinuation<Bool, Never>?

  func suspend() async {
    suspended = true
    startedWaiter?.resume()
    startedWaiter = nil
    await withCheckedContinuation { suspension = $0 }
  }

  func waitUntilSuspended() async {
    guard !suspended else { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }

  func release() {
    suspension?.resume()
    suspension = nil
  }

  func complete(cancelled: Bool) {
    completion = cancelled
    completionWaiter?.resume(returning: cancelled)
    completionWaiter = nil
  }

  func waitUntilCompleted() async -> Bool {
    if let completion { return completion }
    return await withCheckedContinuation { completionWaiter = $0 }
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
  unreadMark: Bool = false
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
    notificationSettings: nil
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
