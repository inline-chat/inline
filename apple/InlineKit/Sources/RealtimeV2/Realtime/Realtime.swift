import AsyncAlgorithms
import Auth
import Combine
import Foundation
import InlineProtocol
import Logger

public enum RealtimeDirectRpcError: Error {
  case notAuthorized
  case notConnected
  case timeout
  case commitOutcomeUnknown
  case capacityExceeded
  case rpcError(errorCode: InlineProtocol.RpcError.Code, message: String?, code: Int)
  case unknown(Error)
}

private final class TransactionSendCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var completed = false

  func requestCancellation() -> Bool {
    lock.withLock {
      guard !completed else { return false }
      cancelled = true
      return true
    }
  }

  func isCancellationRequested() -> Bool {
    lock.withLock { cancelled }
  }

  func finish() {
    lock.withLock { completed = true }
  }
}

private struct PendingTransactionContinuation {
  let continuation: CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>
  let cancellationState: TransactionSendCancellationState
}

private enum TransactionDispatchOutcome {
  case dispatched
  case deferred
}

private enum TransactionDispatchPreparationError: Error {
  case persistenceUnavailable
}

struct RealtimeConnectionLifecycleEdge: Sendable, Equatable {
  let connectionLost: Bool
  let connectionOpened: Bool

  init(
    previousState: ConnectionState,
    previousSessionID: UInt64,
    snapshot: ConnectionSnapshot
  ) {
    let sessionChanged = snapshot.sessionID != previousSessionID
    connectionLost = previousState == .open && (snapshot.state != .open || sessionChanged)
    connectionOpened = snapshot.state == .open && (previousState != .open || sessionChanged)
  }
}

private struct RealtimeTransactionDiagnosticCounters {
  var windowSaturations = 0
  var ephemeralSuperseded = 0
  var ephemeralExpired = 0
  var capacityRejections = 0

  var isEmpty: Bool {
    windowSaturations == 0
      && ephemeralSuperseded == 0
      && ephemeralExpired == 0
      && capacityRejections == 0
  }
}

/// This root actor manages the connection, sync, transactions, queries, etc.
///
/// later we will rename the main module to `Realtime`
public actor RealtimeV2 {
  // MARK: - Core Components

  private var auth: AuthHandle
  private let authDiagnosticSnapshots: AsyncStream<AuthSnapshot>
  private var session: ProtocolSession
  private var connectionManager: ConnectionManager
  private var sync: Sync
  private var transactions: Transactions

  // Public
  public nonisolated let stateObject: RealtimeState

  // MARK: - Private Properties

  private let log = Log.scoped("RealtimeV2", level: .debug)
  private var cancellables = Set<AnyCancellable>()
  private var tasks: Set<Task<Void, Never>> = []
  private var authAdapter: AuthConnectionAdapter?
  private var lifecycleAdapter: LifecycleConnectionAdapter?
  private var networkAdapter: NetworkConnectionAdapter?
  private let maxLimitedRpcErrorRetries = 2
  /// Keep application transactions below the carrier's 64-request ceiling so
  /// sync, probes, and direct control RPCs retain admission capacity.
  private let maximumOutstandingTransactions = 32
  private let transactionDiagnosticInterval: TimeInterval = 60
  private var transactionDiagnosticCounters = RealtimeTransactionDiagnosticCounters()
  private var lastTransactionDiagnosticAt = Date.distantPast
  private var lastTransactionWarningDiagnosticAt = Date.distantPast

  // Connection state channel for cross-task consumption and the latest cached state
  private var connectionStateContinuations: [UUID: AsyncStream<RealtimeConnectionState>.Continuation] = [:]
  private var gridEventContinuations: [UUID: AsyncStream<InlineProtocol.GridEvent>.Continuation] = [:]
  private var transportConnectionState: RealtimeConnectionState = .connecting
  private var currentConnectionState: RealtimeConnectionState = .connecting
  private var syncActivityInProgress = false
  private var lastSnapshotState: ConnectionState = .stopped
  private var lastSnapshotSessionID: UInt64 = 0
  private var didNotifyConnectionInitFailure = false
  private var didNotifyAuthInvalidated = false
  private let authRecoveryDiagnostics = RealtimeAuthRecoveryDiagnostics()
  private let authObservationProbe = AuthObservationProbe()
  private var authRecoverySequence: UInt64 = 0
  private var authRecoveryTask: Task<Void, Never>?
  private var transactionOwner: TransactionOwner?
  private var transactionGeneration: UInt64 = 0
  private var transactionOwnerTransitionTask: Task<Void, Never>?
  private var transactionOwnerTransitionID: UUID?
  private var acceptsTransactions: Bool
  private var transactionRetryTask: Task<Void, Never>?
  private var transactionOperationsInProgress = 0
  private var transactionDrainWaiters: [CheckedContinuation<Void, Never>] = []

  // Transaction execution
  private var transactionContinuations: [TransactionId: PendingTransactionContinuation] = [:]

  // MARK: - Initialization

  public init(
    transport: Transport,
    auth: AuthHandle,
    applyUpdates: ApplyUpdates,
    syncStorage: SyncStorage,
    persistenceHandler: TransactionPersistenceHandler? = nil,
    blockerResolver: (any TransactionBlockerResolver)? = nil,
  ) {
    self.auth = auth
    acceptsTransactions = auth.userId() != nil
    authDiagnosticSnapshots = auth.snapshots
    session = ProtocolSession(transport: transport, auth: auth)
    #if canImport(UIKit)
    let initiallyAppActive = false
    #else
    let initiallyAppActive = true
    #endif
    let initialConstraints = ConnectionConstraints(
      // Realtime handshake requires a token; userId alone is not enough.
      authAvailable: auth.snapshot().isLoggedIn,
      networkAvailable: true,
      appActive: initiallyAppActive,
      userWantsConnection: true
    )
    connectionManager = ConnectionManager(session: session, constraints: initialConstraints)
    let syncConfig = RealtimeConfigStore.initialSyncConfig()
    sync = Sync(
      applyUpdates: applyUpdates,
      syncStorage: syncStorage,
      client: session,
      config: syncConfig,
      acceptsWork: false
    )
    transactions = Transactions(persistenceHandler: persistenceHandler, blockerResolver: blockerResolver)
    stateObject = RealtimeState()
    authAdapter = AuthConnectionAdapter(
      auth: auth,
      manager: connectionManager,
      observationProbe: authObservationProbe
    )
    lifecycleAdapter = LifecycleConnectionAdapter(manager: connectionManager)
    networkAdapter = NetworkConnectionAdapter(manager: connectionManager)

    Task {
      // Initialize everything and start
      await self.start()
    }
  }

  // MARK: - Deinitialization

  deinit {
    // Cancel all associated tasks
    for task in tasks {
      task.cancel()
    }
    tasks.removeAll()
    authRecoveryTask?.cancel()
    authRecoveryTask = nil
    // Stop the transport and terminate its infinite event collector. Capture
    // only the manager so cleanup cannot extend RealtimeV2's lifetime.
    Task { [connectionManager] in
      await connectionManager.stop()
      await connectionManager.finishSessionEventForwarding()
    }
  }

  // MARK: - Lifecycle

  /// Start core components, register listeners and start run loops.
  private func start() async {
    _ = await ensureTransactionOwnerIfNeeded()
    await sync.setSyncActivityListener { [weak self] isActive in
      await self?.syncActivityChanged(isActive)
    }
    stateObject.start(realtime: self)
    await startListeners()

    await session.start()
    await connectionManager.start()
    lifecycleAdapter?.start()
    networkAdapter?.start()
    authAdapter?.start()
    if auth.snapshot().isLoggedIn {
      await connectionManager.setAuthAvailable(true)
      await connectionManager.connectNow()
    }
  }

  /// Called when log out happens
  /// Reset all state to their initial values.
  /// Stop transport. But do not kill the listeners and tasks. This is state is recoverable via a transport start.
  public func loggedOut() async {
    log.info("Stopping realtime account generation")
    acceptsTransactions = false
    authRecoveryTask?.cancel()
    authRecoveryTask = nil
    transactionRetryTask?.cancel()
    let retryTask = transactionRetryTask
    transactionRetryTask = nil

    let ownerTransitionTask = transactionOwnerTransitionTask
    await ownerTransitionTask?.value

    let endingOwner = transactionOwner
    transactionOwner = nil
    resumeAllTransactionContinuations(throwing: CancellationError())

    await connectionManager.stop()
    await retryTask?.value
    await waitForTransactionOperationsToFinish()

    if let endingOwner {
      await transactions.reset(owner: endingOwner, deletePersisted: true)
    }
    await sync.clearSyncState(acceptNewWork: false)
    await updateTransportConnectionState(.connecting)
    log.info("Stopped realtime account generation")
  }

  /// Restarts account work after an in-place local-data reset that preserved authentication.
  public func resumeAfterLocalDataReset() async {
    guard let accountID = auth.userId() else {
      log.warning("Local-data reset resume skipped because authentication is unavailable")
      return
    }

    acceptsTransactions = true
    await transitionTransactionOwner(to: accountID)
    await connectionManager.setAuthAvailable(true)
    await startTransport()
    log.info("Resumed realtime account generation after local-data reset")
  }

  /// Stops process-owned work before application teardown without deleting
  /// durable transactions or sync checkpoints needed by the next launch.
  public func prepareForTermination() async {
    log.info("Quiescing realtime for application termination")
    acceptsTransactions = false
    authRecoveryTask?.cancel()
    authRecoveryTask = nil
    transactionRetryTask?.cancel()
    let retryTask = transactionRetryTask
    transactionRetryTask = nil

    let ownerTransitionTask = transactionOwnerTransitionTask
    await ownerTransitionTask?.value

    let endingOwner = transactionOwner
    transactionOwner = nil
    resumeAllTransactionContinuations(throwing: CancellationError())

    let listenerTasks = tasks
    tasks.removeAll()
    for task in listenerTasks {
      task.cancel()
    }

    async let connectionTermination: Void = connectionManager.stop()
    async let syncTermination: Void = sync.prepareForTermination()
    await retryTask?.value
    for task in listenerTasks {
      await task.value
    }
    await connectionTermination
    await connectionManager.finishSessionEventForwarding()
    await waitForTransactionOperationsToFinish()

    if let endingOwner {
      await transactions.reset(owner: endingOwner, deletePersisted: false)
    } else {
      await transactions.waitForPersistence()
    }
    await syncTermination
    log.info("Realtime quiesced for application termination")
  }

  /// Listen for auth events, transport events, sync events, etc.
  private func startListeners() async {
    let authDiagnosticSnapshots = authDiagnosticSnapshots
    Task {
      for await snapshot in authDiagnosticSnapshots {
        guard !Task.isCancelled else { return }
        await self.authDiagnosticSnapshotReceived(snapshot)
      }
    }.store(in: &tasks)

    // Connection snapshots
    Task {
      self.log.trace("Starting connection snapshot listener")
      for await snapshot in await self.connectionManager.snapshots() {
        guard !Task.isCancelled else { return }

        let mapped = self.mapConnectionState(snapshot.state)
        await self.updateTransportConnectionState(mapped)

        let lifecycleEdge = RealtimeConnectionLifecycleEdge(
          previousState: self.lastSnapshotState,
          previousSessionID: self.lastSnapshotSessionID,
          snapshot: snapshot
        )
        if lifecycleEdge.connectionLost {
          let expired = await self.transactions.connectionLost()
          await self.expireEphemeralTransactions(expired)
        }

        if lifecycleEdge.connectionOpened {
          self.didNotifyConnectionInitFailure = false
          self.didNotifyAuthInvalidated = false
          await self.restartTransactions()
        }
        self.lastSnapshotState = snapshot.state
        self.lastSnapshotSessionID = snapshot.sessionID
      }
    }.store(in: &tasks)

    // Session events (RPC + updates)
    Task {
      self.log.trace("Starting session events listener")
      for await envelope in await self.connectionManager.sessionEvents() {
        guard !Task.isCancelled else {
          await envelope.markProcessed()
          return
        }
        let event = envelope.event

        switch event {
        case let .ack(msgId):
          self.log.trace("Received ACK for message \(msgId)")
          await self.ackTransaction(msgId: msgId)

        case let .rpcResult(msgId, rpcResult):
          self.log.trace("Received RPC result for message \(msgId)")
          await self.completeTransaction(msgId: msgId, rpcResult: rpcResult)

        case let .rpcError(msgId, rpcError):
          self.log.trace("Received RPC error for message \(msgId)")
          if rpcError.errorCode == .unauthenticated {
            await self.handleAuthInvalidated()
          }
          await self.completeTransaction(msgId: msgId, error: TransactionError.rpcError(rpcError))

        case let .rpcCommitOutcomeUnknown(msgId):
          self.log.warning("Received carrier commit-unknown result for message \(msgId)")
          await self.completeTransaction(
            msgId: msgId,
            error: TransactionError.commitOutcomeUnknownAfterReconnect
          )

        case let .rpcRejectedBeforeExecution(msgId):
          self.log.warning("Received carrier pre-execution rejection for message \(msgId)")
          await self.completeTransaction(
            msgId: msgId,
            error: TransactionError.rejectedBeforeExecution
          )

        case let .updates(updates):
          self.log.trace("Received updates \(updates)")
          await self.sync.process(updates: updates.updates)

        case let .grid(event):
          self.publishGridEvent(event)

        case .authFailed:
          self.log.error("Realtime handshake failed due to missing auth token")
          await self.handleMissingAuthTokenHandshakeFailure()

        case let .connectionError(reason):
          self.log.error("Received server connection error during handshake reason=\(reason)")
          await self.handleConnectionErrorDuringHandshake(reason: reason)

        default:
          break
        }
        await envelope.markProcessed()
      }
    }.store(in: &tasks)

    // Transactions
    Task { [weak self] in
      guard let self else { return }
      self.log.trace("Starting transactions listener")
      for await _ in await self.transactions.queueStream {
        guard await self.canExecuteTransactions(), let owner = await self.activeTransactionOwner() else {
          self.log.trace("Skipping transaction queue stream because its connection or account owner is unavailable")
          continue
        }

        transactionDrain: while await self.canExecuteTransactions(),
                                await self.isCurrentTransactionOwner(owner),
                                let dequeueResult = await self.transactions.dequeue(
                                  owner: owner,
                                  maximumOutstanding: self.maximumOutstandingTransactions
                                ) {
          switch dequeueResult {
            case let .ready(transaction):
              self.log.trace("Dequeued transaction \(transaction.id)")
              if await self.runTransaction(transaction, owner: owner) == .deferred {
                break transactionDrain
              }
            case let .failed(transaction):
              self.log.trace("Dropping blocked transaction \(transaction.id) after dependency failure")
              await self.failQueuedTransaction(transaction, error: .dependencyFailed)
            case let .expired(transaction):
              self.log.trace("Discarding expired ephemeral transaction \(transaction.id)")
              await self.recordTransactionDiagnostics(ephemeralExpired: 1)
              await self.failQueuedTransaction(transaction, error: .timeout)
            case let .capacityLimited(pressure):
              await self.recordTransactionDiagnostics(
                windowSaturations: 1,
                pressure: pressure
              )
              break transactionDrain
          }
        }
      }
    }.store(in: &tasks)
  }

  private func authDiagnosticSnapshotReceived(_ snapshot: AuthSnapshot) async {
    authRecoverySequence = authRecoverySequence &+ 1
    let sequence = authRecoverySequence
    authRecoveryDiagnostics.recordSnapshot(sequence: sequence, snapshot: snapshot)

    authRecoveryTask?.cancel()
    authRecoveryTask = nil

    guard snapshot.isLoggedIn else {
      acceptsTransactions = false
      return
    }

    acceptsTransactions = true
    _ = await ensureTransactionOwnerIfNeeded()

    authRecoveryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      await self?.runAuthRecoveryCheck(sequence: sequence, expectedSnapshot: snapshot)
    }
  }

  private func runAuthRecoveryCheck(sequence: UInt64, expectedSnapshot: AuthSnapshot) async {
    guard sequence == authRecoverySequence, !Task.isCancelled else { return }

    var connection = await connectionManager.currentSnapshot()
    let propagationOutcome = authRecoveryDiagnostics.check(
      sequence: sequence,
      authAvailable: auth.snapshot().isLoggedIn,
      observerObserved: authObservationProbe.hasObserved(expectedSnapshot),
      observerApplied: authObservationProbe.hasApplied(expectedSnapshot),
      connection: connection,
      stage: .propagation
    )
    guard propagationOutcome == .pending || propagationOutcome == .deferred else {
      if sequence == authRecoverySequence {
        authRecoveryTask = nil
      }
      return
    }

    do {
      try await Task.sleep(for: .seconds(12))
    } catch {
      return
    }
    guard sequence == authRecoverySequence, !Task.isCancelled else { return }

    connection = await connectionManager.currentSnapshot()
    _ = authRecoveryDiagnostics.check(
      sequence: sequence,
      authAvailable: auth.snapshot().isLoggedIn,
      observerObserved: authObservationProbe.hasObserved(expectedSnapshot),
      observerApplied: authObservationProbe.hasApplied(expectedSnapshot),
      connection: connection,
      stage: .deadline
    )
    if sequence == authRecoverySequence {
      authRecoveryTask = nil
    }
  }

  private func startTransport() async {
    await updateTransportConnectionState(.connecting)
    await connectionManager.start()
    await connectionManager.connectNow()
  }

  private func stopTransport() async {
    await connectionManager.stop()
  }

  /// Ensure the transport is started when credentials are available.
  /// This is intentionally light-weight so callers can pre-warm the connection without using transactions.
  public func connectIfNeeded() async {
    if auth.snapshot().isLoggedIn {
      await connectionManager.setAuthAvailable(true)
      await startTransport()
    }
  }

  private func runTransaction(
    _ transactionWrapper: TransactionWrapper,
    owner expectedOwner: TransactionOwner
  ) async -> TransactionDispatchOutcome {
    guard isCurrentTransactionOwner(expectedOwner) else {
      await transactions.requeue(transactionId: transactionWrapper.id, signal: false)
      return .deferred
    }
    log.trace("Running transaction \(transactionWrapper.id) with method \(transactionWrapper.transaction.method)")
    let transaction = transactionWrapper.transaction
    let queueDurationMilliseconds = max(0, Int(Date().timeIntervalSince(transactionWrapper.date) * 1_000))
    log.debug(
      "Transaction dispatch started transaction_id=\(transactionWrapper.id) method=\(transaction.method) queue_ms=\(queueDurationMilliseconds)"
    )
    beginTransactionOperation()
    defer { endTransactionOperation() }

    do {
      guard isCurrentTransactionOwner(expectedOwner) else {
        await transactions.requeue(transactionId: transactionWrapper.id, signal: false)
        return .deferred
      }
      try await session.sendRpc(
        method: transaction.method,
        input: transaction.input
      ) { [transactions] msgId in
        switch await transactions.prepareForDispatch(
          transactionId: transactionWrapper.id,
          rpcMsgId: msgId,
          owner: expectedOwner
        ) {
          case .prepared:
            break
          case .ownerUnavailable:
            throw ProtocolSessionError.stopped
          case .persistenceUnavailable:
            throw TransactionDispatchPreparationError.persistenceUnavailable
        }
      }
      guard isCurrentTransactionOwner(expectedOwner) else { return .dispatched }
      return .dispatched
    } catch TransactionDispatchPreparationError.persistenceUnavailable {
      log.warning("Transaction dispatch deferred method=\(transaction.method) reason=persistence_unavailable")
      await transactions.requeue(transactionId: transactionWrapper.id, signal: false)
      scheduleTransactionQueueRetry()
      return .deferred
    } catch ProtocolSessionError.stopped {
      log.warning("Transaction dispatch deferred method=\(transaction.method) reason=not_dispatched")
      await transactions.requeue(transactionId: transactionWrapper.id, signal: false)
      scheduleTransactionQueueRetry()
      return .deferred
    } catch ProtocolSessionError.notConnected {
      // The transport rejected the write before accepting bytes. The durable
      // dispatch marker was intentionally conservative, but this boundary is
      // still known-unsent and may safely return to the queue, including for
      // non-replayable mutations.
      log.warning("Transaction dispatch deferred method=\(transaction.method) reason=transport_not_connected")
      await transactions.requeueBeforeDispatch(transactionId: transactionWrapper.id, signal: false)
      scheduleTransactionQueueRetry()
      return .deferred
    } catch ProtocolSessionError.capacityExceeded {
      // Carrier admission rejected this request before accepting bytes. Hold it
      // behind the bounded transaction window instead of reporting uncertainty.
      recordTransactionDiagnostics(capacityRejections: 1)
      await transactions.requeueBeforeDispatch(transactionId: transactionWrapper.id, signal: false)
      scheduleTransactionQueueRetry()
      return .deferred
    } catch {
      if let unresolved = await transactions.recoverAfterUncertainDispatch(
        transactionId: transactionWrapper.id
      ) {
        log.error(
          "Transaction commit outcome unknown after transport failure method=\(transaction.method)",
          error: error
        )
        await transaction.commitOutcomeUnknown()
        await transactions.deletePersisted(transactionId: unresolved.id, owner: expectedOwner)
        await transactions.finishExecution(for: unresolved)
        resumeTransactionContinuation(
          for: transactionWrapper.id,
          throwing: TransactionError.commitOutcomeUnknownAfterReconnect
        )
        await transactions.signalQueue()
        return .dispatched
      }
      log.warning("Replaying application-idempotent transaction method=\(transaction.method)")
      scheduleTransactionQueueRetry()
      return .deferred
    }
  }

  private func ackTransaction(msgId: UInt64) async {
    log.debug("Acknowledging transaction with message ID \(msgId)")
    await transactions.ack(rpcMsgId: msgId)
  }

  private func completeTransaction(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async {
    guard let completingOwner = transactionOwner else { return }
    beginTransactionOperation()
    defer { endTransactionOperation() }

    guard let transactionWrapper = await transactions.complete(
      rpcMsgId: msgId,
      owner: completingOwner,
      deletePersisted: false
    ) else {
      return
    }

    let transaction = transactionWrapper.transaction
    let transactionId = transactionWrapper.id

    guard completingOwner == transactionOwner else {
      await transaction.cancelled()
      await transactions.finishExecution(for: transactionWrapper)
      return
    }

    log.trace("Transaction \(transactionId) completed with result")
    let totalDurationMilliseconds = max(0, Int(Date().timeIntervalSince(transactionWrapper.date) * 1_000))
    log.debug(
      "Transaction completed transaction_id=\(transactionId) method=\(transaction.method) total_ms=\(totalDurationMilliseconds)"
    )

    do {
      try await transaction.apply(rpcResult)
      guard completingOwner == transactionOwner else {
        await transaction.cancelled()
        await transactions.finishExecution(for: transactionWrapper)
        return
      }
      await transactions.deletePersisted(transactionId: transactionId, owner: completingOwner)
      await transactions.finishExecution(for: transactionWrapper)
      await transactions.satisfy(blockers: transaction.satisfiedBlockersOnSuccess)
      resumeTransactionContinuation(for: transactionId, returning: rpcResult)
      await transactions.signalQueue()
    } catch {
      guard completingOwner == transactionOwner else {
        await transaction.cancelled()
        await transactions.finishExecution(for: transactionWrapper)
        return
      }
      await transaction.failed(error: TransactionError.invalid)
      await transactions.deletePersisted(transactionId: transactionId, owner: completingOwner)
      await transactions.finishExecution(for: transactionWrapper)
      await transactions.signalQueue()
      resumeTransactionContinuation(for: transactionId, throwing: TransactionError.invalid)
    }
  }

  private func completeTransaction(msgId: UInt64, error: TransactionError) async {
    guard let completingOwner = transactionOwner else { return }
    beginTransactionOperation()
    defer { endTransactionOperation() }

    let rejectedBeforeExecution = isRejectedBeforeExecution(error)
    let shouldRetry = rejectedBeforeExecution || isLimitedRetryRpcError(error)
    guard let transactionWrapper = await transactions.complete(
      rpcMsgId: msgId,
      owner: completingOwner,
      deletePersisted: false
    ) else {
      return
    }

    let transaction = transactionWrapper.transaction
    let transactionId = transactionWrapper.id

    guard completingOwner == transactionOwner else {
      await transaction.cancelled()
      await transactions.finishExecution(for: transactionWrapper)
      return
    }

    if case .commitOutcomeUnknownAfterReconnect = error {
      log.warning("Transaction commit outcome is unknown transaction_id=\(transactionId)")
      await transaction.commitOutcomeUnknown()
      await transactions.deletePersisted(transactionId: transactionId, owner: completingOwner)
      await transactions.finishExecution(for: transactionWrapper)
      guard completingOwner == transactionOwner else { return }
      resumeTransactionContinuation(for: transactionId, throwing: error)
      await transactions.signalQueue()
      return
    }

    if shouldRetry {
      let requeued = await transactions.retryAfterRpcError(
        transactionWrapper,
        owner: completingOwner,
        maxRetries: maxLimitedRpcErrorRetries,
        signalQueue: !rejectedBeforeExecution
      )
      guard completingOwner == transactionOwner else {
        if !requeued {
          await transaction.cancelled()
          await transactions.finishExecution(for: transactionWrapper)
        }
        return
      }
      if requeued {
        log.warning(
          "Retrying transaction \(transactionId) after RPC error \(transactionWrapper.rpcErrorRetryCount + 1)/\(maxLimitedRpcErrorRetries): \(error)"
        )
        if rejectedBeforeExecution {
          // The server proved this request did not execute. Back off before
          // redelivery so overload does not turn into an immediate retry burst.
          scheduleTransactionQueueRetry()
        }
        return
      }
    }

    log.error("Transaction \(transactionId) failed with error", error: error)

    guard completingOwner == transactionOwner else {
      await transaction.cancelled()
      await transactions.finishExecution(for: transactionWrapper)
      return
    }
    await transaction.failed(error: error)
    await transactions.deletePersisted(transactionId: transactionId, owner: completingOwner)
    await transactions.finishExecution(for: transactionWrapper)
    guard completingOwner == transactionOwner else { return }
    resumeTransactionContinuation(for: transactionId, throwing: error)
    await transactions.signalQueue()
  }

  private func failQueuedTransaction(_ transactionWrapper: TransactionWrapper, error: TransactionError) async {
    guard let completingOwner = transactionOwner else { return }
    let transaction = transactionWrapper.transaction
    let transactionId = transactionWrapper.id

    beginTransactionOperation()
    defer { endTransactionOperation() }
    await transaction.failed(error: error)
    guard completingOwner == transactionOwner else { return }
    resumeTransactionContinuation(for: transactionId, throwing: error)
  }

  private func cancelSupersededEphemeralTransactions(_ wrappers: [TransactionWrapper]) async {
    guard !wrappers.isEmpty else { return }
    recordTransactionDiagnostics(ephemeralSuperseded: wrappers.count)
    for wrapper in wrappers {
      await wrapper.transaction.cancelled()
      resumeTransactionContinuation(for: wrapper.id, throwing: CancellationError())
    }
  }

  private func expireEphemeralTransactions(_ wrappers: [TransactionWrapper]) async {
    guard !wrappers.isEmpty else { return }
    recordTransactionDiagnostics(ephemeralExpired: wrappers.count)
    for wrapper in wrappers {
      await wrapper.transaction.failed(error: .timeout)
      resumeTransactionContinuation(for: wrapper.id, throwing: TransactionError.timeout)
    }
    await transactions.signalQueue()
  }

  private func getAndRemoveContinuation(for transactionId: TransactionId) -> PendingTransactionContinuation? {
    transactionContinuations.removeValue(forKey: transactionId)
  }

  private func restartTransactions() async {
    guard let restartingOwner = transactionOwner else { return }
    // FIXME: probably wait a little before requeuing the inflight list as ack may come soon after a quick intermittent connection loss
    guard let dropped = await transactions.requeueAll(owner: restartingOwner),
          restartingOwner == transactionOwner
    else { return }

    // Queue signals emitted while disconnected are consumed and skipped. On reconnect,
    // wake the transaction loop so previously queued work (e.g. chat history refetches)
    // is drained even if no in-flight transactions were requeued.
    await transactions.signalQueue()

    guard !dropped.isEmpty else { return }

    for wrapper in dropped {
      let transaction = wrapper.transaction
      let transactionId = wrapper.id
      log.warning(
        "Failing non-replayable transaction with unknown commit outcome after reconnect method=\(transaction.method)"
      )
      beginTransactionOperation()
      await transaction.commitOutcomeUnknown()
      await transactions.deletePersisted(transactionId: transactionId, owner: restartingOwner)
      await transactions.finishExecution(for: wrapper)
      endTransactionOperation()
      guard restartingOwner == transactionOwner else { return }
      resumeTransactionContinuation(
        for: transactionId,
        throwing: TransactionError.commitOutcomeUnknownAfterReconnect
      )
    }

    await transactions.signalQueue()
  }

  /// Store the continuation for a transaction from actor context
  private func storeContinuation(for transactionId: TransactionId, continuation: CheckedContinuation<
    RpcResult.OneOf_Result?,
    any Error
  >, cancellationState: TransactionSendCancellationState) {
    transactionContinuations[transactionId] = PendingTransactionContinuation(
      continuation: continuation,
      cancellationState: cancellationState
    )
  }

  private func registerAndEnqueue(
    _ transaction: any Transaction2,
    transactionId: TransactionId,
    owner: TransactionOwner,
    continuation: CheckedContinuation<RpcResult.OneOf_Result?, any Error>,
    cancellationState: TransactionSendCancellationState
  ) async {
    defer { endTransactionOperation() }

    if cancellationState.isCancellationRequested() {
      cancellationState.finish()
      await transaction.cancelled()
      continuation.resume(throwing: CancellationError())
      return
    }

    guard isCurrentTransactionOwner(owner) else {
      cancellationState.finish()
      await transaction.cancelled()
      continuation.resume(throwing: CancellationError())
      return
    }

    if cancellationState.isCancellationRequested() {
      cancellationState.finish()
      await transaction.cancelled()
      continuation.resume(throwing: CancellationError())
      return
    }

    storeContinuation(
      for: transactionId,
      continuation: continuation,
      cancellationState: cancellationState
    )

    let admission = await transactions.enqueue(
      transaction: transaction,
      transactionId: transactionId,
      owner: owner
    )
    switch admission {
      case let .accepted(superseded):
        await cancelSupersededEphemeralTransactions(superseded)
      case .ownerUnavailable:
        resumeTransactionContinuation(for: transactionId, throwing: CancellationError())
        await transaction.cancelled()
        return
      case .persistenceFailed:
        resumeTransactionContinuation(for: transactionId, throwing: TransactionError.persistenceFailed)
        await transaction.cancelled()
        return
    }

    guard isCurrentTransactionOwner(owner) else {
      resumeTransactionContinuation(for: transactionId, throwing: CancellationError())
      await transactions.cancel(transactionId: transactionId)
      return
    }

    guard transactionContinuations[transactionId] != nil else {
      await transactions.cancel(transactionId: transactionId)
      return
    }

    if cancellationState.isCancellationRequested() {
      await cancelTransaction(transactionId: transactionId)
      return
    }

    log.trace("Queued transaction method=\(transaction.method)")
    await transactions.signalQueue()
  }

  private func cancelTransaction(transactionId: TransactionId) async {
    resumeTransactionContinuation(for: transactionId, throwing: CancellationError())
    await transactions.cancel(transactionId: transactionId)
  }

  private func resumeTransactionContinuation(
    for transactionId: TransactionId,
    returning result: RpcResult.OneOf_Result?
  ) {
    guard let pending = getAndRemoveContinuation(for: transactionId) else { return }
    pending.cancellationState.finish()
    pending.continuation.resume(returning: result)
  }

  private func resumeTransactionContinuation(for transactionId: TransactionId, throwing error: any Error) {
    guard let pending = getAndRemoveContinuation(for: transactionId) else { return }
    pending.cancellationState.finish()
    pending.continuation.resume(throwing: error)
  }

  private func resumeAllTransactionContinuations(throwing error: any Error) {
    let pending = Array(transactionContinuations.values)
    transactionContinuations.removeAll()
    for item in pending {
      item.cancellationState.finish()
      item.continuation.resume(throwing: error)
    }
  }

  private func ensureTransactionOwnerIfNeeded() async -> TransactionOwner? {
    guard acceptsTransactions, let accountID = auth.userId() else { return nil }

    if let transactionOwner, transactionOwner.accountID == accountID {
      return transactionOwner
    }

    if let transactionOwnerTransitionTask {
      await transactionOwnerTransitionTask.value
      guard acceptsTransactions,
            auth.userId() == accountID,
            let transactionOwner,
            transactionOwner.accountID == accountID
      else { return nil }
      return transactionOwner
    }

    let transitionID = UUID()
    transactionOwnerTransitionID = transitionID
    let transitionTask = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.transitionTransactionOwner(to: accountID)
    }
    transactionOwnerTransitionTask = transitionTask
    await transitionTask.value
    if transactionOwnerTransitionID == transitionID {
      transactionOwnerTransitionID = nil
      transactionOwnerTransitionTask = nil
    }

    guard acceptsTransactions,
          auth.userId() == accountID,
          let transactionOwner,
          transactionOwner.accountID == accountID
    else { return nil }
    return transactionOwner
  }

  private func transitionTransactionOwner(to accountID: Int64) async {
    guard acceptsTransactions, auth.userId() == accountID else { return }

    if let previousOwner = transactionOwner {
      transactionOwner = nil
      resumeAllTransactionContinuations(throwing: CancellationError())
      let endingRetryTask = transactionRetryTask
      transactionRetryTask = nil
      endingRetryTask?.cancel()
      await endingRetryTask?.value
      await waitForTransactionOperationsToFinish()
      await transactions.reset(owner: previousOwner, deletePersisted: true)
      await sync.clearSyncState(acceptNewWork: false)
    }

    guard acceptsTransactions, auth.userId() == accountID, transactionOwner == nil else { return }

    transactionGeneration = transactionGeneration &+ 1
    let newOwner = TransactionOwner(accountID: accountID, generation: transactionGeneration)
    transactionOwner = newOwner
    await transactions.activate(owner: newOwner)
    await sync.activateGeneration()

    guard acceptsTransactions, auth.userId() == accountID, transactionOwner == newOwner else {
      if transactionOwner == newOwner {
        transactionOwner = nil
      }
      await transactions.reset(owner: newOwner, deletePersisted: true)
      await sync.clearSyncState(acceptNewWork: false)
      return
    }
  }

  private func beginTransactionSubmission() async -> TransactionOwner? {
    guard let owner = await ensureTransactionOwnerIfNeeded(), isCurrentTransactionOwner(owner) else {
      return nil
    }
    beginTransactionOperation()
    return owner
  }

  private func isCurrentTransactionOwner(_ owner: TransactionOwner) -> Bool {
    acceptsTransactions && transactionOwner == owner && auth.userId() == owner.accountID
  }

  private func hasActiveTransactionOwner() -> Bool {
    guard let transactionOwner else { return false }
    return isCurrentTransactionOwner(transactionOwner)
  }

  private func activeTransactionOwner() -> TransactionOwner? {
    guard let transactionOwner, isCurrentTransactionOwner(transactionOwner) else { return nil }
    return transactionOwner
  }

  private func beginTransactionOperation() {
    transactionOperationsInProgress += 1
  }

  private func endTransactionOperation() {
    transactionOperationsInProgress = max(0, transactionOperationsInProgress - 1)
    guard transactionOperationsInProgress == 0 else { return }
    let waiters = transactionDrainWaiters
    transactionDrainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func waitForTransactionOperationsToFinish() async {
    guard transactionOperationsInProgress > 0 else { return }
    await withCheckedContinuation { continuation in
      transactionDrainWaiters.append(continuation)
    }
  }

  private func scheduleTransactionQueueRetry() {
    guard transactionRetryTask == nil,
          acceptsTransactions,
          let expectedOwner = transactionOwner
    else { return }
    transactionRetryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.retryTransactionQueueIfCurrent(owner: expectedOwner)
    }
  }

  private func retryTransactionQueueIfCurrent(owner expectedOwner: TransactionOwner) async {
    transactionRetryTask = nil
    guard acceptsTransactions, transactionOwner == expectedOwner, canExecuteTransactions() else { return }
    await transactions.signalQueue()
  }

  // MARK: - Public API

  /// Send a transaction and wait for the result
  /// Uses nonisolated func to allow use from MainActor for faster optimistic updates
  @discardableResult
  public nonisolated func send(_ transaction: any Transaction2) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    let transactionId = TransactionId.generate()
    let cancellationState = TransactionSendCancellationState()

    return try await withTaskCancellationHandler {
      guard let owner = await beginTransactionSubmission() else {
        cancellationState.finish()
        await transaction.cancelled()
        throw CancellationError()
      }

      guard await admitEphemeralTransactionWhileConnected(transaction) else {
        cancellationState.finish()
        await transaction.failed(error: .timeout)
        await endTransactionOperation()
        throw TransactionError.timeout
      }

      guard !Task.isCancelled, !cancellationState.isCancellationRequested() else {
        cancellationState.finish()
        await transaction.cancelled()
        await endTransactionOperation()
        throw CancellationError()
      }

      // Keep optimistic work on the caller's executor and await it directly so
      // remote execution can never overtake the local projection.
      await transaction.optimistic()

      return try await withCheckedThrowingContinuation { continuation in
        Task {
          await registerAndEnqueue(
            transaction,
            transactionId: transactionId,
            owner: owner,
            continuation: continuation,
            cancellationState: cancellationState
          )
        }
      }
    } onCancel: {
      guard cancellationState.requestCancellation() else { return }
      Task {
        await self.cancelTransaction(transactionId: transactionId)
      }
    }
  }

  /// Send a transaction without waiting for a result.
  /// Optimistic updates still run immediately, and the transaction is queued in order.
  @discardableResult
  public nonisolated func sendQueued(_ transaction: any Transaction2) async -> TransactionId {
    let transactionId = TransactionId.generate()
    guard !Task.isCancelled, let owner = await beginTransactionSubmission() else {
      await transaction.cancelled()
      return transactionId
    }

    guard await admitEphemeralTransactionWhileConnected(transaction) else {
      await transaction.failed(error: .timeout)
      await endTransactionOperation()
      return transactionId
    }

    guard !Task.isCancelled else {
      await transaction.cancelled()
      await endTransactionOperation()
      return transactionId
    }

    await transaction.optimistic()

    guard !Task.isCancelled, await isCurrentTransactionOwner(owner) else {
      await transaction.cancelled()
      await endTransactionOperation()
      return transactionId
    }

    let admission = await transactions.enqueue(
      transaction: transaction,
      transactionId: transactionId,
      owner: owner
    )
    switch admission {
      case let .accepted(superseded):
        await cancelSupersededEphemeralTransactions(superseded)
      case .ownerUnavailable, .persistenceFailed:
        await transaction.cancelled()
        await endTransactionOperation()
        return transactionId
    }

    guard await isCurrentTransactionOwner(owner) else {
      await transactions.cancel(transactionId: transactionId)
      await endTransactionOperation()
      return transactionId
    }

    await endTransactionOperation()
    log.trace("Queued transaction method=\(transaction.method)")
    await transactions.signalQueue()
    return transactionId
  }

  /// Returns a stream of connection state changes that can be consumed from any task.
  public func connectionStates() -> AsyncStream<RealtimeConnectionState> {
    let id = UUID()
    let stream = AsyncStream.makeStream(
      of: RealtimeConnectionState.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    stream.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeConnectionStateContinuation(id) }
    }
    addConnectionStateContinuation(id: id, continuation: stream.continuation)
    return stream.stream
  }

  public func gridEvents() -> AsyncStream<InlineProtocol.GridEvent> {
    let id = UUID()
    let stream = AsyncStream.makeStream(
      of: InlineProtocol.GridEvent.self,
      // Grid events are ephemeral invalidations/targeted hints; snapshots and
      // target-scoped credential retries repair any observer suspension.
      bufferingPolicy: .bufferingNewest(128)
    )
    stream.continuation.onTermination = { [weak self] _ in
      Task { await self?.removeGridEventContinuation(id) }
    }
    addGridEventContinuation(id: id, continuation: stream.continuation)
    return stream.stream
  }

  public func applyUpdates(_ updates: [InlineProtocol.Update]) {
    Task { await sync.process(updates: updates) }
  }

  /// Applies transaction-result updates before returning when subsequent
  /// reconciliation depends on their database state.
  public func applyUpdatesAndWait(_ updates: [InlineProtocol.Update]) async {
    await sync.process(updates: updates)
  }

  public func satisfyTransactionBlockers(_ blockers: [TransactionBlocker]) async {
    await transactions.satisfy(blockers: blockers)
  }

  /// Low-level RPC call that bypasses the transaction system.
  /// Used by short-lived contexts (e.g. share extension) that must send media before full transaction support.
  public func callRpcDirect(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration? = .seconds(15)
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    do {
      return try await session.callRpc(method: method, input: input, timeout: timeout)
    } catch let error as ProtocolSessionError {
      switch error {
        case .notAuthorized:
          throw RealtimeDirectRpcError.notAuthorized
        case .notConnected:
          throw RealtimeDirectRpcError.notConnected
        case .timeout:
          throw RealtimeDirectRpcError.timeout
        case .commitOutcomeUnknown:
          throw RealtimeDirectRpcError.commitOutcomeUnknown
        case .capacityExceeded:
          throw RealtimeDirectRpcError.capacityExceeded
        case let .rpcError(errorCode, message, code):
          if errorCode == .unauthenticated {
            await handleAuthInvalidated()
          }
          throw RealtimeDirectRpcError.rpcError(errorCode: errorCode, message: message, code: code)
        case .stopped:
          throw RealtimeDirectRpcError.notConnected
        }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RealtimeDirectRpcError.unknown(error)
    }
  }

  public func revokeSession(_ sessionID: Int64) async throws -> InlineProtocol.RevokeSessionResult {
    let result = try await callRpcDirect(
      method: .revokeSession,
      input: .revokeSession(.with {
        $0.sessionID = sessionID
      })
    )

    guard case let .revokeSession(revokeResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return revokeResult
  }

  public func getSessions() async throws -> InlineProtocol.GetSessionsResult {
    let result = try await callRpcDirect(
      method: .getSessions,
      input: .getSessions(.with { _ in })
    )

    guard case let .getSessions(sessionsResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return sessionsResult
  }

  public func createCliSession(
    deviceID: String,
    deviceName: String?,
    clientVersion: String,
    osVersion: String?
  ) async throws -> InlineProtocol.CreateCliSessionResult {
    let result = try await callRpcDirect(
      method: .createCliSession,
      input: .createCliSession(.with {
        $0.deviceID = deviceID
        if let deviceName { $0.deviceName = deviceName }
        $0.clientVersion = clientVersion
        if let osVersion { $0.osVersion = osVersion }
      })
    )

    guard case let .createCliSession(createResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return createResult
  }

  public func checkUsername(_ username: String) async throws -> InlineProtocol.CheckUsernameResult {
    let result = try await callRpcDirect(
      method: .checkUsername,
      input: .checkUsername(.with {
        $0.username = username
      })
    )

    guard case let .checkUsername(usernameResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return usernameResult
  }

  public func changeUsername(_ username: String) async throws -> InlineProtocol.ChangeUsernameResult {
    let result = try await callRpcDirect(
      method: .changeUsername,
      input: .changeUsername(.with {
        $0.username = username
      })
    )

    guard case let .changeUsername(usernameResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return usernameResult
  }

  public func updateProfile(
    firstName: String?,
    lastName: String?,
    bio: String?
  ) async throws -> InlineProtocol.UpdateProfileResult {
    let result = try await callRpcDirect(
      method: .updateProfile,
      input: .updateProfile(.with {
        if let firstName {
          $0.firstName = firstName
        }
        if let lastName {
          $0.lastName = lastName
        }
        if let bio {
          $0.bio = bio
        }
      })
    )

    guard case let .updateProfile(profileResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return profileResult
  }

  public func setProfilePhoto(fileUniqueID: String?) async throws -> InlineProtocol.SetProfilePhotoResult {
    let result = try await callRpcDirect(
      method: .setProfilePhoto,
      input: .setProfilePhoto(.with {
        $0.fileUniqueID = fileUniqueID ?? ""
      })
    )

    guard case let .setProfilePhoto(profileResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return profileResult
  }

  public func getExternalProfilePhoto(
    provider: InlineProtocol.ExternalProfileProvider,
    username: String
  ) async throws -> InlineProtocol.GetExternalProfilePhotoResult {
    let result = try await callRpcDirect(
      method: .getExternalProfilePhoto,
      input: .getExternalProfilePhoto(.with {
        $0.provider = provider
        $0.username = username
      })
    )

    guard case let .getExternalProfilePhoto(profilePhotoResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    return profilePhotoResult
  }

  public func collapseHistory(
    peer: InlineProtocol.InputPeer,
    maxID: Int64?
  ) async throws -> Int64? {
    let result = try await callRpcDirect(
      method: .collapseHistory,
      input: .collapseHistory(.with {
        $0.peerID = peer
        if let maxID {
          $0.maxID = maxID
        }
      })
    )

    guard case let .collapseHistory(collapseResult)? = result else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }
    guard let boundaryUpdate = collapseResult.updates.first(where: {
      if case .dialogCollapsedMaxID = $0.update { return true }
      return false
    }), case let .dialogCollapsedMaxID(boundary) = boundaryUpdate.update else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: nil, code: 500)
    }

    await sync.process(updates: collapseResult.updates)
    return boundary.hasMaxID ? boundary.maxID : nil
  }

  public func cancelTransaction(where predicate: @escaping @Sendable (TransactionWrapper) -> Bool) {
    guard let owner = activeTransactionOwner() else { return }
    beginTransactionOperation()
    Task { [predicate] in
      await transactions.cancel(where: predicate, owner: owner)
      endTransactionOperation()
    }
  }

  public func updateSyncConfig(_ config: SyncConfig) {
    Task { await sync.updateConfig(config) }
  }

  public func getSyncStats() async -> SyncStats {
    await sync.getStats()
  }

  public func clearSyncState() async {
    await sync.clearSyncState()
  }

  /// Reconciles already-created in-memory bucket actors with cursors committed by
  /// an authoritative account snapshot.
  public func installSnapshotBucketStates(_ states: [BucketKey: BucketState]) async {
    await sync.installSnapshotBucketStates(states)
  }

#if DEBUG || DEBUG_BUILD
  public func runSyncDebugScenario(_ scenario: SyncDebugScenario) async -> SyncDebugScenarioResult {
    await sync.runDebugScenario(scenario)
  }

  public func runSyncDebugBucketScenario(
    _ scenario: SyncDebugBucketScenario,
    key: BucketKey
  ) async -> SyncDebugActionResult {
    await sync.runDebugBucketScenario(scenario, key: key)
  }

  public func cycleConnectionForSyncDebug() async -> SyncDebugActionResult {
    guard auth.snapshot().isLoggedIn else {
      return SyncDebugActionResult(
        succeeded: false,
        summary: "Sign in before cycling the realtime connection."
      )
    }

    await connectionManager.stop()
    await connectionManager.start()
    await connectionManager.setAuthAvailable(true)
    await connectionManager.connectNow()

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(15)
    while clock.now < deadline {
      let snapshot = await connectionManager.currentSnapshot()
      if snapshot.state == .open {
        return SyncDebugActionResult(
          succeeded: true,
          summary: "Cycled the real connection owner and reached authenticated open; reconnect discovery is running normally."
        )
      }
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return SyncDebugActionResult(
          succeeded: false,
          summary: "Connection-cycle observation was cancelled."
        )
      }
    }

    let snapshot = await connectionManager.currentSnapshot()
    return SyncDebugActionResult(
      succeeded: false,
      summary: "Connection cycle did not reopen within 15 seconds (state: \(snapshot.state))."
    )
  }
#endif

  // MARK: - Helpers

  private func mapConnectionState(_ state: ConnectionState) -> RealtimeConnectionState {
    switch state {
    case .open:
      return .connected
    case .connectingTransport, .authenticating, .backoff, .waitingForConstraints, .backgroundSuspended, .stopped:
      return .connecting
    }
  }

  private func updateTransportConnectionState(_ newState: RealtimeConnectionState) async {
    guard newState != transportConnectionState else { return }
    transportConnectionState = newState
    Task { await sync.connectionStateChanged(state: newState) }
    await publishConnectionStateIfNeeded()
  }

  private func syncActivityChanged(_ isActive: Bool) async {
    guard isActive != syncActivityInProgress else { return }
    syncActivityInProgress = isActive
    await publishConnectionStateIfNeeded()
  }

  private func publishConnectionStateIfNeeded() async {
    let nextState: RealtimeConnectionState
    if transportConnectionState == .connected && syncActivityInProgress {
      nextState = .updating
    } else {
      nextState = transportConnectionState
    }

    guard nextState != currentConnectionState else { return }
    currentConnectionState = nextState
    for continuation in connectionStateContinuations.values {
      continuation.yield(nextState)
    }
  }

  private func canExecuteTransactions() -> Bool {
    switch currentConnectionState {
    case .connected, .updating:
      true
    case .connecting:
      false
    }
  }

  private func admitEphemeralTransactionWhileConnected(_ transaction: any Transaction) -> Bool {
    let accepted = transaction.ephemeralConfig == nil || canExecuteTransactions()
    if !accepted {
      recordTransactionDiagnostics(ephemeralExpired: 1)
    }
    return accepted
  }

  private func recordTransactionDiagnostics(
    windowSaturations: Int = 0,
    ephemeralSuperseded: Int = 0,
    ephemeralExpired: Int = 0,
    capacityRejections: Int = 0,
    pressure: TransactionQueuePressure? = nil
  ) {
    transactionDiagnosticCounters.windowSaturations += windowSaturations
    transactionDiagnosticCounters.ephemeralSuperseded += ephemeralSuperseded
    transactionDiagnosticCounters.ephemeralExpired += ephemeralExpired
    transactionDiagnosticCounters.capacityRejections += capacityRejections

    let now = Date()
    let incomingWarning = windowSaturations > 0 || capacityRejections > 0
    let lastRelevantDiagnosticAt = incomingWarning
      ? lastTransactionWarningDiagnosticAt
      : lastTransactionDiagnosticAt
    guard now.timeIntervalSince(lastRelevantDiagnosticAt) >= transactionDiagnosticInterval,
          !transactionDiagnosticCounters.isEmpty
    else { return }

    let counters = transactionDiagnosticCounters
    transactionDiagnosticCounters = RealtimeTransactionDiagnosticCounters()
    lastTransactionDiagnosticAt = now

    var data: [String: Any] = [
      "window_saturations": counters.windowSaturations,
      "ephemeral_superseded": counters.ephemeralSuperseded,
      "ephemeral_expired": counters.ephemeralExpired,
      "capacity_rejections": counters.capacityRejections,
    ]
    if let pressure {
      data["queued"] = pressure.queued
      data["outstanding"] = pressure.outstanding
      data["oldest_queue_age_ms"] = pressure.oldestQueueAgeMilliseconds
    }

    let isWarning = counters.windowSaturations > 0 || counters.capacityRejections > 0
    if isWarning { lastTransactionWarningDiagnosticAt = now }
    PerformanceTrace.breadcrumb(
      "realtime_transaction_pressure",
      category: "realtime.transaction",
      level: isWarning ? .warning : .info,
      data: data
    )
    if isWarning {
      log.warning(
        "Realtime transaction pressure queued=\(pressure?.queued ?? 0) outstanding=\(pressure?.outstanding ?? 0) saturations=\(counters.windowSaturations) capacity_rejections=\(counters.capacityRejections)"
      )
    }
  }

  private func addConnectionStateContinuation(
    id: UUID,
    continuation: AsyncStream<RealtimeConnectionState>.Continuation
  ) {
    connectionStateContinuations[id] = continuation
    continuation.yield(currentConnectionState)
  }

  private func removeConnectionStateContinuation(_ id: UUID) {
    connectionStateContinuations.removeValue(forKey: id)
  }

  private func addGridEventContinuation(
    id: UUID,
    continuation: AsyncStream<InlineProtocol.GridEvent>.Continuation
  ) {
    gridEventContinuations[id] = continuation
  }

  private func removeGridEventContinuation(_ id: UUID) {
    gridEventContinuations.removeValue(forKey: id)
  }

  private func publishGridEvent(_ event: InlineProtocol.GridEvent) {
    for continuation in gridEventContinuations.values {
      continuation.yield(event)
    }
  }

  private func notifyConnectionInitFailureIfNeeded() {
    guard !didNotifyConnectionInitFailure else { return }
    didNotifyConnectionInitFailure = true
    NotificationCenter.default.post(name: .realtimeV2ConnectionInitFailed, object: nil)
  }

  private func handleConnectionErrorDuringHandshake(reason: InlineProtocol.ConnectionError.Reason) async {
    if reason == .sessionRevoked || reason == .invalidAuth {
      log.error("Realtime handshake failed because auth was invalidated")
      await handleAuthInvalidated()
      return
    }

    await auth.refreshFromStorage()

    guard isMissingAuthToken() else { return }

    log.error("Realtime handshake connectionError mapped to missing auth token")
    await handleMissingAuthTokenHandshakeFailure()
  }

  private func handleAuthInvalidated() async {
    guard !didNotifyAuthInvalidated else { return }
    didNotifyAuthInvalidated = true
    acceptsTransactions = false
    await connectionManager.setAuthAvailable(false)
    NotificationCenter.default.post(name: .realtimeV2AuthInvalidated, object: nil)
  }

  private func handleMissingAuthTokenHandshakeFailure() async {
    await connectionManager.setAuthAvailable(false)
    notifyConnectionInitFailureIfNeeded()
  }

  private func isMissingAuthToken() -> Bool {
    switch auth.snapshot().status {
    case .reauthRequired:
      return true
    case .authenticated(let credentials):
      return credentials.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .hydrating, .unauthenticated, .locked, .authenticatedV3:
      return false
    }
  }

  private func isLimitedRetryRpcError(_ error: TransactionError) -> Bool {
    guard case let .rpcError(rpcError) = error else { return false }

    switch rpcError.errorCode {
    case .badRequest,
         .peerIDInvalid,
         .messageIDInvalid,
         .userIDInvalid,
         .userAlreadyMember,
         .spaceIDInvalid,
         .chatIDInvalid,
         .emailInvalid,
         .phoneNumberInvalid,
         .spaceAdminRequired,
         .spaceOwnerRequired,
         .usernameInvalid,
         .usernameTaken,
         .firstNameInvalid,
         .urlPreviewUnavailable:
      return true
    case .unknown,
         .unauthenticated,
         .rateLimit,
         .internalError,
         .UNRECOGNIZED(_):
      return false
    }
  }

  private func isRejectedBeforeExecution(_ error: TransactionError) -> Bool {
    if case .rejectedBeforeExecution = error { return true }
    return false
  }
}
