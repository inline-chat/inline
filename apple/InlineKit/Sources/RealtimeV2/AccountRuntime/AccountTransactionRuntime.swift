import Foundation

/// Produces a transaction persistence handler for exactly one durable account namespace.
///
/// A production adapter can back each scope with `TransactionQueue/accounts/<account-id>` while
/// callers continue using the existing `TransactionPersistenceHandler` protocol internally.
public protocol AccountTransactionPersistenceFactory: Sendable {
  func makeHandler(
    for scope: AccountPersistenceScope
  ) async throws -> any TransactionPersistenceHandler
}

/// Capability passed to transaction call sites. Both account identity and generation must match.
public struct AccountTransactionSession: Hashable, Sendable {
  public let generation: AccountGeneration
  public let persistenceScope: AccountPersistenceScope
}

public struct AccountTransactionWork: Sendable {
  public let session: AccountTransactionSession
  public let wrapper: TransactionWrapper
}

public enum AccountTransactionDequeueResult: Sendable {
  case ready(AccountTransactionWork)
  case dependencyFailed(AccountTransactionWork)
}

/// Compatibility seam that binds the existing transaction queue to an authenticated generation.
///
/// It is deliberately not wired into `Api.realtime`: this spike makes lifecycle rules testable
/// before changing singleton ownership. Account transitions are serialized, stale capabilities are
/// rejected at every suspension boundary, owned execution is cancelled and joined, and persistence
/// is drained before the next account becomes active.
public actor AccountTransactionRuntime {
  private struct ActiveSession: Sendable {
    let capability: AccountTransactionSession
    let transactions: Transactions
    let persistence: AccountTransactionPersistenceGate
  }

  private let supervisor: AccountGenerationSupervisor
  private var activeSession: ActiveSession?
  private var transitionInProgress = false
  private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

  public init(supervisor: AccountGenerationSupervisor = AccountGenerationSupervisor()) {
    self.supervisor = supervisor
  }

  /// Begin a new account generation and synchronously recover only that account's durable queue.
  public func begin(
    accountID: Int64,
    persistenceFactory: any AccountTransactionPersistenceFactory,
    blockerResolver: (any TransactionBlockerResolver)? = nil
  ) async throws -> AccountTransactionSession {
    await acquireTransition()
    defer { releaseTransition() }

    // Reject old capabilities before waiting for their children and persistence cleanup.
    activeSession = nil
    let generation = await supervisor.begin(accountID: accountID)
    let scope = AccountPersistenceScope(accountID: accountID)

    do {
      let delegate = try await persistenceFactory.makeHandler(for: scope)
      let persistence = AccountTransactionPersistenceGate(delegate: delegate)
      let capability = AccountTransactionSession(generation: generation, persistenceScope: scope)

      let cleanupRegistered = await supervisor.registerCleanup(
        for: generation,
        label: "transaction-persistence"
      ) {
        await persistence.shutdown()
      }
      guard cleanupRegistered else {
        await persistence.shutdown()
        throw AccountTransactionRuntimeError.staleSession
      }

      let transactions = Transactions(
        persistenceHandler: persistence,
        blockerResolver: blockerResolver,
        loadPersistedTransactionsOnInit: false
      )
      await transactions.loadPersistedTransactions()

      guard await supervisor.isCurrent(generation) else {
        await persistence.shutdown()
        throw AccountTransactionRuntimeError.staleSession
      }

      activeSession = ActiveSession(
        capability: capability,
        transactions: transactions,
        persistence: persistence
      )
      return capability
    } catch {
      await supervisor.logout()
      throw error
    }
  }

  /// Fence the session immediately, then cancel/join execution and drain persistence.
  public func logout() async {
    await acquireTransition()
    defer { releaseTransition() }
    activeSession = nil
    await supervisor.logout()
  }

  /// Queue a mutation only after its account-scoped persistence operation completes.
  @discardableResult
  public func enqueue(
    _ transaction: some Transaction,
    for session: AccountTransactionSession
  ) async throws -> TransactionId? {
    guard let active = activeSession(matching: session) else { return nil }
    let id: TransactionId
    do {
      id = try await active.transactions.enqueueDurably(transaction: transaction)
    } catch {
      guard activeSession(matching: session) != nil,
            await supervisor.isCurrent(session.generation)
      else {
        return nil
      }
      throw error
    }

    // Logout/replacement can enter while persistence suspends. Never return an old capability's
    // success as though it belonged to the replacement account.
    guard activeSession(matching: session) != nil,
          await supervisor.isCurrent(session.generation)
    else {
      return nil
    }
    return id
  }

  public func dequeue(
    for session: AccountTransactionSession
  ) async -> AccountTransactionDequeueResult? {
    guard let active = activeSession(matching: session) else { return nil }
    guard let result = await active.transactions.dequeue() else { return nil }
    guard activeSession(matching: session) != nil,
          await supervisor.isCurrent(session.generation)
    else {
      return nil
    }

    switch result {
    case let .ready(wrapper):
      return .ready(AccountTransactionWork(session: session, wrapper: wrapper))
    case let .failed(wrapper):
      return .dependencyFailed(AccountTransactionWork(session: session, wrapper: wrapper))
    }
  }

  /// Start transaction execution as an owned child of the authenticated generation.
  @discardableResult
  public func startExecution(
    for work: AccountTransactionWork,
    operation: @escaping @Sendable (TransactionWrapper) async -> Void
  ) async -> Bool {
    guard activeSession(matching: work.session) != nil else { return false }
    return await supervisor.startChild(for: work.session.generation) {
      await operation(work.wrapper)
    }
  }

  /// Prepare a callback asynchronously, then perform a non-suspending commit only if still current.
  ///
  /// Existing transaction `apply` methods that suspend need to be split into prepare/commit or made
  /// generation-aware before this seam can safely host them.
  @discardableResult
  public func startCallback<Prepared: Sendable>(
    for session: AccountTransactionSession,
    prepare: @escaping @Sendable () async -> Prepared,
    commit: @escaping @Sendable (Prepared) -> Void
  ) async -> Bool {
    guard activeSession(matching: session) != nil else { return false }
    return await supervisor.startChild(for: session.generation) { [supervisor] in
      let prepared = await prepare()
      _ = await supervisor.commitIfCurrent(session.generation) {
        commit(prepared)
      }
    }
  }

  public func isCurrent(_ session: AccountTransactionSession) async -> Bool {
    guard activeSession(matching: session) != nil else { return false }
    return await supervisor.isCurrent(session.generation)
  }

  private func activeSession(matching capability: AccountTransactionSession) -> ActiveSession? {
    guard activeSession?.capability == capability else { return nil }
    return activeSession
  }

  private func acquireTransition() async {
    while transitionInProgress {
      await withCheckedContinuation { continuation in
        transitionWaiters.append(continuation)
      }
    }
    transitionInProgress = true
  }

  private func releaseTransition() {
    transitionInProgress = false
    guard !transitionWaiters.isEmpty else { return }
    transitionWaiters.removeFirst().resume()
  }
}

public enum AccountTransactionRuntimeError: Error, Equatable, Sendable {
  case staleSession
  case persistenceClosed
}

private actor AccountTransactionPersistenceGate: TransactionPersistenceHandler {
  private let delegate: any TransactionPersistenceHandler
  private var acceptingOperations = true
  private var activeOperationCount = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  init(delegate: any TransactionPersistenceHandler) {
    self.delegate = delegate
  }

  func saveTransaction(_ transaction: TransactionWrapper) async throws {
    try beginOperation()
    defer { finishOperation() }
    try Task.checkCancellation()
    try await delegate.saveTransaction(transaction)
  }

  func deleteTransaction(_ transactionId: TransactionId) async throws {
    try beginOperation()
    defer { finishOperation() }
    try Task.checkCancellation()
    try await delegate.deleteTransaction(transactionId)
  }

  func loadTransactions() async throws -> [TransactionWrapper] {
    try beginOperation()
    defer { finishOperation() }
    try Task.checkCancellation()
    return try await delegate.loadTransactions()
  }

  func shutdown() async {
    acceptingOperations = false
    guard activeOperationCount > 0 else { return }
    await withCheckedContinuation { continuation in
      drainWaiters.append(continuation)
    }
  }

  private func beginOperation() throws {
    guard acceptingOperations else {
      throw AccountTransactionRuntimeError.persistenceClosed
    }
    activeOperationCount += 1
  }

  private func finishOperation() {
    activeOperationCount -= 1
    guard activeOperationCount == 0 else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
