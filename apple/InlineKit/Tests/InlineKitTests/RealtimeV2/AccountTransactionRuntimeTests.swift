import Foundation
import Synchronization
import Testing

@testable import InlineProtocol
@testable import RealtimeV2

private actor AccountTransactionProbe {
  private var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }

  func snapshot() -> [String] {
    events
  }
}

private actor AsyncBarrier {
  private var started = false
  private var released = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func suspendUntilReleased() async {
    started = true
    let waiters = startedWaiters
    startedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    guard !released else { return }
    await withCheckedContinuation { continuation in
      releaseWaiters.append(continuation)
    }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startedWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    let waiters = releaseWaiters
    releaseWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private actor ScopedMemoryPersistenceFactory: AccountTransactionPersistenceFactory {
  private var storage: [AccountPersistenceScope: [TransactionId: TransactionWrapper]] = [:]
  private let saveBarrier: AsyncBarrier?
  private let saveError: AccountRuntimePersistenceTestError?

  init(
    saveBarrier: AsyncBarrier? = nil,
    saveError: AccountRuntimePersistenceTestError? = nil
  ) {
    self.saveBarrier = saveBarrier
    self.saveError = saveError
  }

  func makeHandler(
    for scope: AccountPersistenceScope
  ) async throws -> any TransactionPersistenceHandler {
    ScopedMemoryPersistenceHandler(factory: self, scope: scope)
  }

  func save(_ transaction: TransactionWrapper, in scope: AccountPersistenceScope) async throws {
    if let saveBarrier {
      await saveBarrier.suspendUntilReleased()
    }
    if let saveError {
      throw saveError
    }
    storage[scope, default: [:]][transaction.id] = transaction
  }

  func delete(_ transactionID: TransactionId, in scope: AccountPersistenceScope) {
    storage[scope]?[transactionID] = nil
  }

  func load(from scope: AccountPersistenceScope) -> [TransactionWrapper] {
    Array(storage[scope, default: [:]].values)
  }

  func count(in scope: AccountPersistenceScope) -> Int {
    storage[scope, default: [:]].count
  }
}

private struct ScopedMemoryPersistenceHandler: TransactionPersistenceHandler {
  let factory: ScopedMemoryPersistenceFactory
  let scope: AccountPersistenceScope

  func saveTransaction(_ transaction: TransactionWrapper) async throws {
    try await factory.save(transaction, in: scope)
  }

  func deleteTransaction(_ transactionId: TransactionId) async throws {
    await factory.delete(transactionId, in: scope)
  }

  func loadTransactions() async throws -> [TransactionWrapper] {
    await factory.load(from: scope)
  }
}

private struct AccountRuntimeTestTransaction: Transaction {
  typealias Context = String

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = .sendMessage
  var type: TransactionKindType = .mutation()
  var context: String

  func input(from _: String) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private enum AccountRuntimePersistenceTestError: Error {
  case saveFailed
}

@Suite("Account-scoped transaction runtime")
struct AccountTransactionRuntimeTests {
  @Test("replacement cancels and joins account A execution before account B activates")
  func replacementDrainsExecution() async throws {
    let runtime = AccountTransactionRuntime()
    let persistence = ScopedMemoryPersistenceFactory()
    let probe = AccountTransactionProbe()
    let started = AsyncStream.makeStream(of: Void.self)
    let accountA = try await runtime.begin(accountID: 10, persistenceFactory: persistence)
    let id = try await runtime.enqueue(AccountRuntimeTestTransaction(context: "account-a"), for: accountA)
    #expect(id != nil)

    let dequeued = await runtime.dequeue(for: accountA)
    guard case let .ready(work)? = dequeued else {
      Issue.record("Expected account A transaction work")
      return
    }

    let accepted = await runtime.startExecution(for: work) { _ in
      await probe.record("a-started")
      started.continuation.yield()
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        await probe.record("a-cancelled")
      }
      await probe.record("a-ended")
    }
    #expect(accepted)

    var startedIterator = started.stream.makeAsyncIterator()
    _ = await startedIterator.next()
    let accountB = try await runtime.begin(accountID: 20, persistenceFactory: persistence)

    #expect(await probe.snapshot() == ["a-started", "a-cancelled", "a-ended"])
    #expect(await runtime.isCurrent(accountA) == false)
    #expect(await runtime.isCurrent(accountB))
    #expect(await runtime.startExecution(for: work) { _ in } == false)
  }

  @Test("stale callback prepared by account A cannot commit after replacement")
  func staleCallbackIsRejectedAtCommit() async throws {
    let runtime = AccountTransactionRuntime()
    let persistence = ScopedMemoryPersistenceFactory()
    let commits = Mutex<[String]>([])
    let preparationStarted = AsyncStream.makeStream(of: Void.self)
    let accountA = try await runtime.begin(accountID: 10, persistenceFactory: persistence)

    let accepted = await runtime.startCallback(for: accountA) {
      preparationStarted.continuation.yield()
      try? await Task.sleep(for: .seconds(30))
      return "account-a-callback"
    } commit: { value in
      commits.withLock { $0.append(value) }
    }
    #expect(accepted)

    var startedIterator = preparationStarted.stream.makeAsyncIterator()
    _ = await startedIterator.next()
    _ = try await runtime.begin(accountID: 20, persistenceFactory: persistence)

    #expect(commits.withLock { $0 }.isEmpty)
    #expect(
      await runtime.startCallback(for: accountA, prepare: { "late" }, commit: { _ in }) == false
    )
  }

  @Test("replacement waits for account A persistence and never writes into account B")
  func replacementDrainsPersistence() async throws {
    let barrier = AsyncBarrier()
    let persistence = ScopedMemoryPersistenceFactory(saveBarrier: barrier)
    let runtime = AccountTransactionRuntime()
    let accountA = try await runtime.begin(accountID: 10, persistenceFactory: persistence)
    let replacementCompleted = Mutex(false)

    let enqueueTask = Task {
      try await runtime.enqueue(AccountRuntimeTestTransaction(context: "durable-a"), for: accountA)
    }
    await barrier.waitUntilStarted()

    let replacementTask = Task {
      let accountB = try await runtime.begin(accountID: 20, persistenceFactory: persistence)
      replacementCompleted.withLock { $0 = true }
      return accountB
    }

    for _ in 0 ..< 100 {
      guard await runtime.isCurrent(accountA) else { break }
      await Task.yield()
    }
    #expect(await runtime.isCurrent(accountA) == false)
    #expect(replacementCompleted.withLock { $0 } == false)

    await barrier.release()
    let accountB = try await replacementTask.value
    let staleResult = try await enqueueTask.value

    #expect(staleResult == nil)
    #expect(replacementCompleted.withLock { $0 })
    #expect(await persistence.count(in: accountA.persistenceScope) == 1)
    #expect(await persistence.count(in: accountB.persistenceScope) == 0)
  }

  @Test("relaunch recovers durable work only for the same account")
  func relaunchPersistenceIsAccountScoped() async throws {
    let persistence = ScopedMemoryPersistenceFactory()
    let firstRuntime = AccountTransactionRuntime()
    let firstAccountA = try await firstRuntime.begin(accountID: 10, persistenceFactory: persistence)
    let originalID = try await firstRuntime.enqueue(
      AccountRuntimeTestTransaction(context: "survive-relaunch"),
      for: firstAccountA
    )
    #expect(originalID != nil)
    await firstRuntime.logout()

    let secondRuntime = AccountTransactionRuntime()
    let accountB = try await secondRuntime.begin(accountID: 20, persistenceFactory: persistence)
    #expect(await secondRuntime.dequeue(for: accountB) == nil)
    await secondRuntime.logout()

    let relaunchedAccountA = try await secondRuntime.begin(accountID: 10, persistenceFactory: persistence)
    let recovered = await secondRuntime.dequeue(for: relaunchedAccountA)
    guard case let .ready(work)? = recovered else {
      Issue.record("Expected account A durable transaction after relaunch")
      return
    }
    #expect(work.wrapper.id == originalID)
    #expect(work.wrapper.transaction.context as? String == "survive-relaunch")
  }

  @Test("durable mutation cannot be dequeued until its save succeeds")
  func persistencePrecedesQueuePublication() async throws {
    let barrier = AsyncBarrier()
    let persistence = ScopedMemoryPersistenceFactory(saveBarrier: barrier)
    let runtime = AccountTransactionRuntime()
    let account = try await runtime.begin(accountID: 10, persistenceFactory: persistence)

    let enqueueTask = Task {
      try await runtime.enqueue(AccountRuntimeTestTransaction(context: "publish-after-save"), for: account)
    }
    await barrier.waitUntilStarted()

    #expect(await runtime.dequeue(for: account) == nil)
    #expect(await persistence.count(in: account.persistenceScope) == 0)

    await barrier.release()
    let transactionID = try await enqueueTask.value
    guard case let .ready(work)? = await runtime.dequeue(for: account) else {
      Issue.record("Expected durable mutation after its save completed")
      return
    }
    #expect(work.wrapper.id == transactionID)
    #expect(await persistence.count(in: account.persistenceScope) == 1)
  }

  @Test("failed durable save never publishes executable work and propagates the error")
  func persistenceFailureNeverPublishes() async throws {
    let barrier = AsyncBarrier()
    let persistence = ScopedMemoryPersistenceFactory(
      saveBarrier: barrier,
      saveError: .saveFailed
    )
    let runtime = AccountTransactionRuntime()
    let account = try await runtime.begin(accountID: 10, persistenceFactory: persistence)
    let enqueueTask = Task {
      try await runtime.enqueue(AccountRuntimeTestTransaction(context: "must-not-queue"), for: account)
    }
    await barrier.waitUntilStarted()

    #expect(await runtime.dequeue(for: account) == nil)
    await barrier.release()
    await #expect(throws: AccountRuntimePersistenceTestError.saveFailed) {
      try await enqueueTask.value
    }
    #expect(await runtime.dequeue(for: account) == nil)
    #expect(await persistence.count(in: account.persistenceScope) == 0)
  }
}
