import Foundation
import InlineProtocol
import Testing

@testable import InlineKit
@testable import RealtimeV2

@Suite("RealtimeV2 transaction lifetime", .serialized)
struct TransactionLifetimeTests {
  @Test("default persistence isolates account directories")
  func defaultPersistenceIsolatesAccounts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-transaction-lifetime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let persistence = DefaultTransactionPersistenceHandler(baseDirectory: root)
    let accountA = TransactionOwner(accountID: 101, generation: 1)
    let accountB = TransactionOwner(accountID: 202, generation: 1)
    let wrapper = TransactionWrapper(
      id: .generate(),
      date: Date(),
      transaction: LifetimeMutation()
    )

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let unscopedLegacyURL = root.appendingPathComponent("legacy.json")
    try Data("unscoped legacy transaction".utf8)
      .write(to: unscopedLegacyURL, options: .atomic)

    try await persistence.saveTransaction(wrapper, for: accountA)

    #expect(try await persistence.loadTransactions(for: accountB).isEmpty)
    #expect(FileManager.default.fileExists(atPath: unscopedLegacyURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: root
          .appendingPathComponent("account-101", isDirectory: true)
          .appendingPathComponent("\(wrapper.id.toString()).json")
          .path
      )
    )
  }

  @Test("serialized persistence cannot resurrect a cancelled mutation")
  func cancellationCannotRaceAheadOfSave() async throws {
    let persistence = DelayedPersistence()
    let owner = TransactionOwner(accountID: 303, generation: 1)
    let transactions = Transactions(persistenceHandler: persistence)
    await transactions.activate(owner: owner)

    let queuedTransactionID = await transactions.queue(transaction: LifetimeMutation(), owner: owner)
    let transactionID = try #require(queuedTransactionID)
    await transactions.cancel(transactionId: transactionID)
    await transactions.waitForPersistence()

    #expect(await persistence.contains(transactionID, for: owner) == false)
  }

  @Test("reset rejects the ending generation and clears durable work")
  func resetClearsOwnerGeneration() async throws {
    let persistence = DelayedPersistence()
    let owner = TransactionOwner(accountID: 404, generation: 1)
    let transactions = Transactions(persistenceHandler: persistence)
    await transactions.activate(owner: owner)

    let queuedTransactionID = await transactions.queue(transaction: LifetimeMutation(), owner: owner)
    let transactionID = try #require(queuedTransactionID)
    await transactions.waitForPersistence()
    #expect(await persistence.contains(transactionID, for: owner))

    await transactions.reset(owner: owner, deletePersisted: true)

    #expect(await persistence.contains(transactionID, for: owner) == false)
    #expect(await transactions.queue(transaction: LifetimeMutation(), owner: owner) == nil)
  }

  @Test("account transition cannot admit or execute the prior owner's work")
  func accountTransitionRejectsPriorOwner() async throws {
    let persistence = DelayedPersistence()
    let accountA = TransactionOwner(accountID: 505, generation: 1)
    let accountB = TransactionOwner(accountID: 606, generation: 2)
    let transactions = Transactions(persistenceHandler: persistence)

    await transactions.activate(owner: accountA)
    let queuedAccountATransactionID = await transactions.queue(transaction: LifetimeMutation(), owner: accountA)
    let accountATransactionID = try #require(queuedAccountATransactionID)
    await transactions.waitForPersistence()
    #expect(await persistence.contains(accountATransactionID, for: accountA))

    await transactions.reset(owner: accountA, deletePersisted: true)
    await transactions.activate(owner: accountB)

    #expect(await persistence.contains(accountATransactionID, for: accountA) == false)
    #expect(await transactions.queue(transaction: LifetimeMutation(), owner: accountA) == nil)

    let queuedAccountBTransactionID = await transactions.queue(transaction: LifetimeMutation(), owner: accountB)
    let accountBTransactionID = try #require(queuedAccountBTransactionID)
    let dequeueResult = await transactions.dequeue()
    let dequeued = try #require(dequeueResult)
    switch dequeued {
    case let .ready(wrapper):
      #expect(wrapper.id == accountBTransactionID)
      #expect(wrapper.id != accountATransactionID)
    case .failed:
      Issue.record("The current account's ready transaction was unexpectedly failed")
    }
  }

  @Test("a response owner mismatch cannot remove current in-flight work")
  func responseOwnerMismatchIsRejectedBeforeRemoval() async throws {
    let accountA = TransactionOwner(accountID: 707, generation: 1)
    let accountB = TransactionOwner(accountID: 808, generation: 2)
    let transactions = Transactions()

    await transactions.activate(owner: accountA)
    let queuedID = await transactions.queue(transaction: LifetimeMutation(), owner: accountA)
    let transactionID = try #require(queuedID)
    _ = await transactions.dequeue()
    await transactions.running(transactionId: transactionID, rpcMsgId: 99)

    let mismatchedCompletion = await transactions.complete(rpcMsgId: 99, owner: accountB)
    #expect(mismatchedCompletion?.id == nil)
    #expect(await transactions.isInFlight(transactionId: transactionID))

    let validCompletion = await transactions.complete(rpcMsgId: 99, owner: accountA)
    #expect(validCompletion?.id == transactionID)
    #expect(await transactions.isInFlight(transactionId: transactionID) == false)
  }

  @Test("durable mutation is not dequeue-visible before persistence commits")
  func durableAdmissionWaitsForPersistence() async throws {
    let persistence = GatedLifetimePersistence()
    let owner = TransactionOwner(accountID: 909, generation: 1)
    let transactions = Transactions(persistenceHandler: persistence)
    await transactions.activate(owner: owner)

    let transactionID = TransactionId.generate()
    let admission = Task {
      await transactions.enqueue(
        transaction: LifetimeMutation(),
        transactionId: transactionID,
        owner: owner
      )
    }

    await persistence.waitUntilSaveStarted()
    #expect(await transactions.dequeue(owner: owner) == nil)
    #expect(await persistence.contains(transactionID, for: owner) == false)

    await persistence.releaseSave()
    #expect(await admission.value == .accepted)
    #expect(await persistence.contains(transactionID, for: owner))

    let result = await transactions.dequeue(owner: owner)
    guard case let .ready(wrapper)? = result else {
      Issue.record("Persisted mutation was not dequeue-visible after admission")
      return
    }
    #expect(wrapper.id == transactionID)
  }

  @Test("persistence failure rejects durable mutation admission")
  func persistenceFailureRejectsAdmission() async throws {
    let persistence = FailingLifetimePersistence()
    let owner = TransactionOwner(accountID: 910, generation: 1)
    let transactions = Transactions(persistenceHandler: persistence)
    await transactions.activate(owner: owner)

    let transactionID = TransactionId.generate()
    let result = await transactions.enqueue(
      transaction: LifetimeMutation(),
      transactionId: transactionID,
      owner: owner
    )

    #expect(result == .persistenceFailed)
    #expect(await transactions.isInQueue(transactionId: transactionID) == false)
    #expect(await transactions.isInFlight(transactionId: transactionID) == false)
  }

  @Test("owner reset while blocker resolution is suspended cannot resurrect work")
  func resetDuringBlockerResolutionDoesNotResurrectWork() async throws {
    let resolver = GatedBlockerResolver()
    let accountA = TransactionOwner(accountID: 911, generation: 1)
    let accountB = TransactionOwner(accountID: 912, generation: 2)
    let transactions = Transactions(blockerResolver: resolver)
    await transactions.activate(owner: accountA)

    let transactionID = try #require(
      await transactions.queue(transaction: BlockedLifetimeMutation(), owner: accountA)
    )
    let dequeue = Task { await transactions.dequeue(owner: accountA) }
    await resolver.waitUntilResolutionStarted()

    await transactions.reset(owner: accountA, deletePersisted: true)
    await transactions.activate(owner: accountB)
    await resolver.release(.satisfied)

    #expect(await dequeue.value == nil)
    #expect(await transactions.isInQueue(transactionId: transactionID) == false)
    #expect(await transactions.isInFlight(transactionId: transactionID) == false)
  }
}

private actor DelayedPersistence: TransactionPersistenceHandler {
  private var storage: [TransactionOwner: [TransactionId: TransactionWrapper]] = [:]

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    try await Task.sleep(for: .milliseconds(50))
    storage[owner, default: [:]][transaction.id] = transaction
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {
    storage[owner]?.removeValue(forKey: transactionId)
  }

  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] {
    storage[owner].map { Array($0.values) } ?? []
  }

  func deleteAllTransactions(for owner: TransactionOwner) async throws {
    storage.removeValue(forKey: owner)
  }

  func contains(_ transactionId: TransactionId, for owner: TransactionOwner) -> Bool {
    storage[owner]?[transactionId] != nil
  }
}

private actor GatedLifetimePersistence: TransactionPersistenceHandler {
  private var storage: [TransactionOwner: [TransactionId: TransactionWrapper]] = [:]
  private var saveStarted = false
  private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var saveReleased = false
  private var saveReleaseWaiters: [CheckedContinuation<Void, Never>] = []

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    saveStarted = true
    for waiter in saveStartWaiters { waiter.resume() }
    saveStartWaiters.removeAll()
    if !saveReleased {
      await withCheckedContinuation { continuation in
        saveReleaseWaiters.append(continuation)
      }
    }
    storage[owner, default: [:]][transaction.id] = transaction
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {
    storage[owner]?.removeValue(forKey: transactionId)
  }

  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] {
    storage[owner].map { Array($0.values) } ?? []
  }

  func deleteAllTransactions(for owner: TransactionOwner) async throws {
    storage.removeValue(forKey: owner)
  }

  func waitUntilSaveStarted() async {
    guard !saveStarted else { return }
    await withCheckedContinuation { continuation in
      saveStartWaiters.append(continuation)
    }
  }

  func releaseSave() {
    saveReleased = true
    for waiter in saveReleaseWaiters { waiter.resume() }
    saveReleaseWaiters.removeAll()
  }

  func contains(_ transactionId: TransactionId, for owner: TransactionOwner) -> Bool {
    storage[owner]?[transactionId] != nil
  }
}

private actor FailingLifetimePersistence: TransactionPersistenceHandler {
  struct SaveFailure: Error {}

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    throw SaveFailure()
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {}
  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] { [] }
  func deleteAllTransactions(for owner: TransactionOwner) async throws {}
}

private actor GatedBlockerResolver: TransactionBlockerResolver {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var result: TransactionBlockerState?
  private var resultWaiters: [CheckedContinuation<TransactionBlockerState, Never>] = []

  func state(for blocker: TransactionBlocker) async -> TransactionBlockerState {
    started = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters.removeAll()
    if let result { return result }
    return await withCheckedContinuation { continuation in
      resultWaiters.append(continuation)
    }
  }

  func waitUntilResolutionStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release(_ result: TransactionBlockerState) {
    self.result = result
    for waiter in resultWaiters { waiter.resume(returning: result) }
    resultWaiters.removeAll()
  }
}

private struct LifetimeMutation: Transaction2, Codable {
  struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = .UNRECOGNIZED(9_999_980)
  var type: TransactionKindType = .mutation()
  var context = Context()

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private struct BlockedLifetimeMutation: Transaction2, Codable {
  struct Context: Sendable, Codable {}

  enum CodingKeys: String, CodingKey { case context }

  var method: InlineProtocol.Method = .UNRECOGNIZED(9_999_979)
  var type: TransactionKindType = .query()
  var context = Context()
  var blockers: [TransactionBlocker] { [.chatCreated(chatId: 1)] }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}
