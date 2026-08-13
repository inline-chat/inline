import Foundation
import Testing

@testable import InlineKit

@Suite("Legacy transaction lifetime", .serialized)
struct LegacyTransactionLifetimeTests {
  @Test("worker pool is bounded and clear joins active work")
  func workerPoolIsBoundedAndClearJoins() async {
    let probe = LegacyTransactionProbe.shared
    await probe.reset()

    let actor = TransactionsActor()
    await actor.setCompletionHandler { _ in
      Task { await probe.recordCompletion() }
    }

    for index in 0 ..< 6 {
      await actor.queue(transaction: LegacyLifetimeTransaction(id: "bounded-\(index)"))
    }

    let filledPool = await waitForLegacyTransactionCondition {
      await probe.startedCount() == 4
    }
    #expect(filledPool)
    #expect(await probe.maximumActiveCount() == 4)

    await actor.clearAll()

    let allCompletionsDelivered = await waitForLegacyTransactionCondition {
      await probe.completionCount() == 6
    }

    #expect(await probe.activeCount() == 0)
    #expect(await probe.rollbackCount() == 6)
    #expect(allCompletionsDelivered)
  }

  @Test("clear rejects a mutation whose submission arrives late")
  func clearRejectsLateSubmission() async {
    let transactionID = "clear-vs-submit-\(UUID().uuidString)"
    let actor = TransactionsActor()
    let cache = InMemoryTransactionsCache()
    let submissionGate = LegacySubmissionGate()
    let transactions = Transactions(
      actor: actor,
      cache: cache,
      beforeActorSubmission: {
        try await submissionGate.waitUntilReleased()
      }
    )

    transactions.mutate(
      transaction: .mockMessage(
        MockMessageTransaction(id: transactionID, text: "must not cross clear")
      )
    )

    #expect(await submissionGate.waitUntilBlocked())
    #expect(cache.transactions.contains { $0.transaction.id == transactionID })
    #expect(MockMessageCache.shared.messages.contains { $0.id == transactionID })

    await transactions.clearAllAndWait()
    submissionGate.release()

    // A late task must not repopulate either the actor or the durable cache after
    // the clear barrier returns.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(cache.transactions.contains { $0.transaction.id == transactionID } == false)
    #expect(MockMessageCache.shared.messages.contains { $0.id == transactionID } == false)
  }

  @Test("unknown cancellation markers are bounded and still reject late work")
  func unknownCancellationMarkersAreBounded() async {
    let actor = TransactionsActor()
    for index in 0 ..< 10_000 {
      await actor.cancel(transactionId: "never-arrives-\(index)")
    }

    #expect(await actor.cancelMarkerCount == 4_096)

    let probe = LegacyTransactionProbe.shared
    await probe.reset()
    let lateTransactionID = "arrives-after-cancel"
    await actor.cancel(transactionId: lateTransactionID)
    await actor.queue(transaction: LegacyLifetimeTransaction(id: lateTransactionID))

    let rejected = await waitForLegacyTransactionCondition {
      await probe.rollbackCount() == 1
    }
    #expect(rejected)
    #expect(await probe.startedCount() == 0)
    #expect(await actor.cancelMarkerCount <= 4_096)
  }

  @Test("unscoped legacy persistence is quarantined instead of replayed")
  func unscopedLegacyPersistenceIsQuarantined() throws {
    let stateFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-transactions-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: stateFileURL) }

    let persisted = PersistedTransaction(
      transaction: .mockMessage(
        MockMessageTransaction(id: "account-a", text: "must not replay under account B")
      ),
      order: 1,
      date: Date()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let originalData = try encoder.encode([persisted])
    try originalData.write(to: stateFileURL, options: .atomic)

    let cache = TransactionsCache(stateFileURL: stateFileURL)
    #expect(cache.transactions.isEmpty)

    try cache.add(
      transaction: .mockMessage(
        MockMessageTransaction(id: "account-b", text: "runtime-only")
      )
    )
    #expect(cache.transactions.map(\.transaction.id) == ["account-b"])
    #expect(try Data(contentsOf: stateFileURL) == originalData)
  }
}

private final class InMemoryTransactionsCache: @unchecked Sendable, TransactionsCaching {
  private let lock = NSLock()
  private var storage: [PersistedTransaction] = []
  private var nextOrder = 0

  var transactions: [PersistedTransaction] {
    lock.withLock { storage }
  }

  func add(transaction: TransactionType) throws {
    try lock.withLock {
      guard storage.contains(where: { $0.transaction.id == transaction.id }) == false else {
        throw TransactionError.duplicate
      }
      nextOrder += 1
      storage.append(PersistedTransaction(transaction: transaction, order: nextOrder, date: Date()))
    }
  }

  func remove(transactionId: String) {
    lock.withLock {
      storage.removeAll { $0.transaction.id == transactionId }
    }
  }

  func clearAll() {
    lock.withLock {
      storage.removeAll()
    }
  }
}

private final class LegacySubmissionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var blocked = false
  private var released = false

  func waitUntilReleased() async throws {
    lock.withLock {
      blocked = true
    }

    while lock.withLock({ released }) == false {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  func waitUntilBlocked() async -> Bool {
    await waitForLegacyTransactionCondition {
      self.lock.withLock { self.blocked }
    }
  }

  func release() {
    lock.withLock {
      released = true
    }
  }
}

private struct LegacyLifetimeTransaction: Transaction {
  typealias R = Void

  let id: String
  var date: Date
  var config: TransactionConfig

  init(id: String) {
    self.id = id
    date = Date()
    config = .noRetry
  }

  func execute() async throws {
    await LegacyTransactionProbe.shared.begin()
    do {
      try await Task.sleep(for: .seconds(30))
      await LegacyTransactionProbe.shared.end()
    } catch {
      await LegacyTransactionProbe.shared.end()
      throw error
    }
  }

  func optimistic() {}
  func didSucceed(result _: Void) async {}
  func shouldRetryOnFail(error _: any Error) -> Bool { false }
  func didFail(error _: (any Error)?) async {}

  func rollback() async {
    await LegacyTransactionProbe.shared.recordRollback()
  }
}

private actor LegacyTransactionProbe {
  static let shared = LegacyTransactionProbe()

  private var active = 0
  private var maximumActive = 0
  private var started = 0
  private var rollbacks = 0
  private var completions = 0

  func reset() {
    active = 0
    maximumActive = 0
    started = 0
    rollbacks = 0
    completions = 0
  }

  func begin() {
    active += 1
    started += 1
    maximumActive = max(maximumActive, active)
  }

  func end() {
    active = max(0, active - 1)
  }

  func recordRollback() {
    rollbacks += 1
  }

  func recordCompletion() {
    completions += 1
  }

  func activeCount() -> Int { active }
  func maximumActiveCount() -> Int { maximumActive }
  func startedCount() -> Int { started }
  func rollbackCount() -> Int { rollbacks }
  func completionCount() -> Int { completions }
}

private func waitForLegacyTransactionCondition(
  timeout: Duration = .seconds(15),
  pollInterval: Duration = .milliseconds(10),
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while await condition() == false {
    if clock.now >= deadline { return false }
    try? await clock.sleep(for: pollInterval)
  }
  return true
}
