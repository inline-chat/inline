import Auth
import Foundation
import GRDB
import RealtimeV2
import Testing
@testable import InlineKit

@Suite("Send retry policy", .timeLimit(.minutes(1)))
struct SendRetryPolicyTests {
  @Test("offline errors wait for the connection without spending an attempt")
  func offlineDoesNotSpendAttempts() async throws {
    let id = UUID().uuidString
    let waits = WaitCounter()
    let actor = TransactionsActor(waitForConnection: { await waits.increment() })
    // maxRetries 0: any spent attempt would fail the transaction.
    await actor.queue(transaction: OfflineThenOnline(id: id, failuresBeforeSuccess: 3))
    try await waitFor { await OfflineProbe.shared.succeeded.contains(id) }
    #expect(await waits.value == 3)
    #expect(await OfflineProbe.shared.failed.contains(id) == false)
  }

  @Test("connection wait returns at once when connecting, and settles when already connected")
  func waitUntilConnected() async throws {
    let reconnect = AsyncStream<RealtimeConnectionState>.makeStream()
    reconnect.continuation.yield(.connecting)
    reconnect.continuation.yield(.connected)
    let clock = ContinuousClock()
    var started = clock.now
    try await TransactionsActor.waitUntilConnected(states: reconnect.stream, settle: .seconds(5))
    #expect(clock.now - started < .seconds(1))

    let alreadyUp = AsyncStream<RealtimeConnectionState>.makeStream()
    alreadyUp.continuation.yield(.updating)
    started = clock.now
    try await TransactionsActor.waitUntilConnected(states: alreadyUp.stream, settle: .milliseconds(50))
    #expect(clock.now - started >= .milliseconds(50))
  }

  @Test("media send backoff grows from 2 s to a 60 s cap and classifies offline errors")
  func backoffAndClassification() {
    #expect(TransactionSendMessage.backoff(afterAttempt: 1) == 2)
    #expect(TransactionSendMessage.backoff(afterAttempt: 2) == 4)
    #expect(TransactionSendMessage.backoff(afterAttempt: 5) == 32)
    #expect(TransactionSendMessage.backoff(afterAttempt: 9) == 60)
    #expect(TransactionSendMessage.isConnectivityError(RealtimeDirectRpcError.notConnected))
    #expect(TransactionSendMessage.isConnectivityError(URLError(.notConnectedToInternet)))
    #expect(!TransactionSendMessage.isConnectivityError(RealtimeDirectRpcError.timeout))

    let send = TransactionSendMessage(text: "x", peerId: .user(id: 2), chatId: 1)
    #expect(!send.shouldRetryOnFail(error: CocoaError(.fileNoSuchFile)))
    #expect(!send.shouldRetryOnFail(error: CancellationError()))
    #expect(send.shouldRetryOnFail(error: URLError(.timedOut)))
  }

  @Test("Retry resumes a failed send under its original identity")
  @MainActor
  func resendKeepsIdentity() async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123")))
    var message = Message(
      messageId: -77, fromId: 1, date: Date(), text: "caption", peerUserId: nil,
      peerThreadId: 1, chatId: 1, out: true, status: .failed
    )
    message.randomId = 77
    message.transactionId = "tx-77"
    let seeded = message
    try await database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 1, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      try seeded.save(db)
    }
    let full = FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
    var resumed: TransactionSendMessage?
    var admittedNew = false
    try await FailedMessageResender.resend(
      full, database: database, auth: auth.handle,
      resume: { resumed = $0; return true }
    ) { _ in admittedNew = true; return true }

    #expect(!admittedNew)
    #expect(resumed?.id == "tx-77")
    #expect(resumed?.randomId == 77)
    let stored = try await database.dbWriter.read { db in
      try Message.fetchOne(db, key: ["messageId": -77, "chatId": 1])
    }
    #expect(stored?.status == .sending)
  }

  @Test("a rejected resume leaves the row failed")
  @MainActor
  func rejectedResumeStaysFailed() async throws {
    let auth = Auth.mocked(authenticated: true)
    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123")))
    var message = Message(
      messageId: -78, fromId: 1, date: Date(), text: "caption", peerUserId: nil,
      peerThreadId: 1, chatId: 1, out: true, status: .failed
    )
    message.randomId = 78
    message.transactionId = "tx-78"
    let seeded = message
    try await database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 1, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      try seeded.save(db)
    }
    let full = FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
    try await FailedMessageResender.resend(full, database: database, auth: auth.handle, resume: { _ in false }) { _ in
      Issue.record("fell back to a new transaction")
      return false
    }
    let stored = try await database.dbWriter.read { db in
      try Message.fetchOne(db, key: ["messageId": -78, "chatId": 1])
    }
    #expect(stored?.status == .failed)
  }
}

private actor WaitCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private struct OfflineThenOnline: InlineKit.Transaction {
  let id: String
  let failuresBeforeSuccess: Int
  var date = Date()
  var config = TransactionConfig(maxRetries: 0, retryDelay: 0, executionTimeout: 0)

  func optimistic() {}
  func execute() async throws {
    let attempt = await OfflineProbe.shared.attempt(id)
    if attempt <= failuresBeforeSuccess { throw RealtimeDirectRpcError.notConnected }
  }

  func didSucceed(result _: Void) async { await OfflineProbe.shared.succeed(id) }
  func shouldRetryOnFail(error _: any Error) -> Bool { false }
  func waitsForConnection(after error: Error) -> Bool { TransactionSendMessage.isConnectivityError(error) }
  func didFail(error _: (any Error)?) async { await OfflineProbe.shared.fail(id) }
  func rollback() async {}
}

private actor OfflineProbe {
  static let shared = OfflineProbe()
  private var attempts: [String: Int] = [:]
  var succeeded: Set<String> = []
  var failed: Set<String> = []
  func attempt(_ id: String) -> Int {
    attempts[id, default: 0] += 1
    return attempts[id]!
  }

  func succeed(_ id: String) { succeeded.insert(id) }
  func fail(_ id: String) { failed.insert(id) }
}

private func waitFor(_ condition: @escaping @Sendable () async -> Bool) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(5)
  while await condition() == false {
    guard clock.now < deadline else { throw WaitTimeout() }
    try await Task.sleep(for: .milliseconds(5))
  }
}

private struct WaitTimeout: Error {}
