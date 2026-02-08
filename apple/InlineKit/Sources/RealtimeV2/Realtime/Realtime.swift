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
  case rpcError(message: String?, code: Int)
  case unknown(Error)
}

/// This root actor manages the connection, sync, transactions, queries, etc.
///
/// later we will rename the main module to `Realtime`
public actor RealtimeV2 {
  // MARK: - Core Components

  private var auth: AuthHandle
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

  // Connection state channel for cross-task consumption and the latest cached state
  private var connectionStateContinuations: [UUID: AsyncStream<RealtimeConnectionState>.Continuation] = [:]
  private var currentConnectionState: RealtimeConnectionState = .connecting
  private var lastSnapshotState: ConnectionState = .stopped

  // Transaction execution
  private var transactionContinuations: [TransactionId: CheckedContinuation<
    InlineProtocol.RpcResult.OneOf_Result?,
    // TransactionError
    any Error
  >] = [:]

  // MARK: - Initialization

  public init(
    transport: Transport,
    auth: AuthHandle,
    applyUpdates: ApplyUpdates,
    syncStorage: SyncStorage,
    persistenceHandler: TransactionPersistenceHandler? = nil,
  ) {
    self.auth = auth
    session = ProtocolSession(transport: transport, auth: auth)
    let initialConstraints = ConnectionConstraints(
      // Realtime handshake requires a token; userId alone is not enough.
      authAvailable: auth.token() != nil,
      networkAvailable: true,
      appActive: true,
      userWantsConnection: true
    )
    connectionManager = ConnectionManager(session: session, constraints: initialConstraints)
    let syncConfig = RealtimeConfigStore.initialSyncConfig()
    sync = Sync(applyUpdates: applyUpdates, syncStorage: syncStorage, client: session, config: syncConfig)
    transactions = Transactions(persistenceHandler: persistenceHandler)
    stateObject = RealtimeState()
    authAdapter = AuthConnectionAdapter(auth: auth, manager: connectionManager)
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
    // Stop core components
    Task { [self] in
      await connectionManager.stop()
    }
  }

  // MARK: - Lifecycle

  /// Start core components, register listeners and start run loops.
  private func start() async {
    stateObject.start(realtime: self)
    await startListeners()

    await session.start()
    await connectionManager.start()
    authAdapter?.start()
    if auth.token() != nil {
      await connectionManager.setAuthAvailable(true)
      await connectionManager.connectNow()
    }
  }

  /// Called when log out happens
  /// Reset all state to their initial values.
  /// Stop transport. But do not kill the listeners and tasks. This is state is recoverable via a transport start.
  private func stopAndReset() async {
    await connectionManager.stop()
  }

  /// Listen for auth events, transport events, sync events, etc.
  private func startListeners() async {
    // Connection snapshots
    Task {
      self.log.trace("Starting connection snapshot listener")
      for await snapshot in await self.connectionManager.snapshots() {
        guard !Task.isCancelled else { return }

        let mapped = self.mapConnectionState(snapshot.state)
        await self.updateConnectionState(mapped)

        if snapshot.state == .open && self.lastSnapshotState != .open {
          await self.restartTransactions()
        }
        self.lastSnapshotState = snapshot.state
      }
    }.store(in: &tasks)

    // Session events (RPC + updates)
    Task {
      self.log.trace("Starting session events listener")
      for await event in await self.connectionManager.sessionEvents() {
        guard !Task.isCancelled else { return }

        switch event {
        case let .ack(msgId):
          self.log.trace("Received ACK for message \(msgId)")
          await self.ackTransaction(msgId: msgId)

        case let .rpcResult(msgId, rpcResult):
          self.log.trace("Received RPC result for message \(msgId)")
          await self.completeTransaction(msgId: msgId, rpcResult: rpcResult)

        case let .rpcError(msgId, rpcError):
          self.log.trace("Received RPC error for message \(msgId)")
          await self.completeTransaction(msgId: msgId, error: TransactionError.rpcError(rpcError))

        case let .updates(updates):
          self.log.trace("Received updates \(updates)")
          await self.sync.process(updates: updates.updates)

        default:
          break
        }
      }
    }.store(in: &tasks)

    // Transactions
    Task.detached {
      self.log.trace("Starting transactions listener")
      for await _ in await self.transactions.queueStream {
        guard await self.currentConnectionState == .connected else {
          self.log.trace("Skipping transaction queue stream as connection is not connected")
          continue
        }

        while let transaction = await self.transactions.dequeue() {
          self.log.trace("Dequeued transaction \(transaction.id)")
          await self.runTransaction(transaction)
        }
      }
    }.store(in: &tasks)
  }

  private func startTransport() async {
    await updateConnectionState(.connecting)
    await connectionManager.start()
    await connectionManager.connectNow()
  }

  private func stopTransport() async {
    await connectionManager.stop()
  }

  /// Ensure the transport is started when credentials are available.
  /// This is intentionally light-weight so callers can pre-warm the connection without using transactions.
  public func connectIfNeeded() async {
    if auth.token() != nil {
      await connectionManager.setAuthAvailable(true)
      await startTransport()
    }
  }

  private func runTransaction(_ transactionWrapper: TransactionWrapper) async {
    log.trace("Running transaction \(transactionWrapper.id) with method \(transactionWrapper.transaction.method)")
    let transaction = transactionWrapper.transaction
    // send as RPC
    // mark as running
    Task {
      do {
        // send as RPC message
        let msgId = try await session.sendRpc(method: transaction.method, input: transaction.input)
        // mark as running
        await transactions.running(transactionId: transactionWrapper.id, rpcMsgId: msgId)
        // the rest of the work (ack, etc) is handled later
      } catch {
        log.error("Failed to send transaction \(transactionWrapper.id) with method \(transaction.method)", error: error)
        await transactions.requeue(transactionId: transactionWrapper.id)
        // FIXME: What to do with the error? Restart the connection?
      }
    }
  }

  private func ackTransaction(msgId: UInt64) async {
    log.debug("Acknowledging transaction with message ID \(msgId)")
    await transactions.ack(rpcMsgId: msgId)
  }

  private func completeTransaction(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async {
    guard let transactionWrapper = await transactions.complete(rpcMsgId: msgId) else {
      return
    }

    let transaction = transactionWrapper.transaction
    let transactionId = transactionWrapper.id

    log.trace("Transaction \(transactionId) completed with result")

    // FIXME: Task, Task.detached, or...?
    Task.detached {
      do {
        try await transaction.apply(rpcResult)
        Task {
          await self.getAndRemoveContinuation(for: transactionId)?.resume(returning: rpcResult)
        }
      } catch {
        // This for some reason did not work
        // let error = TransactionError.executionError(error)
        await transaction.failed(error: TransactionError.invalid)
        Task {
          await self.getAndRemoveContinuation(for: transactionId)?
            .resume(throwing: TransactionError.invalid)
        }
      }
    }
  }

  private func completeTransaction(msgId: UInt64, error: TransactionError) async {
    guard let transactionWrapper = await transactions.complete(rpcMsgId: msgId) else {
      return
    }

    let transaction = transactionWrapper.transaction
    let transactionId = transactionWrapper.id

    log.error("Transaction \(transactionId) failed with error", error: error)

    Task.detached {
      await transaction.failed(error: error)
    }
    transactionContinuations[transactionId]?.resume(throwing: error)
    transactionContinuations.removeValue(forKey: transactionId)
  }

  private func getAndRemoveContinuation(for transactionId: TransactionId) -> CheckedContinuation<
    RpcResult.OneOf_Result?,
    any Error
  >? {
    let continuation = transactionContinuations[transactionId]
    transactionContinuations.removeValue(forKey: transactionId)
    return continuation
  }

  private func restartTransactions() async {
    // FIXME: probably wait a little before requeuing the inflight list as ack may come soon after a quick intermittent connection loss
    await transactions.requeueAll()
  }

  /// Store the continuation for a transaction from actor context
  private func storeContinuation(for transactionId: TransactionId, continuation: CheckedContinuation<
    RpcResult.OneOf_Result?,
    any Error
  >) {
    transactionContinuations[transactionId] = continuation
  }

  // MARK: - Public API

  /// Send a transaction and wait for the result
  /// Uses nonisolated func to allow use from MainActor for faster optimistic updates
  @discardableResult
  public nonisolated func send(_ transaction: any Transaction2) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    // run optimistic immediately
    // Note(@mo): Do not put this in a task or it may run after the execution of the transaction
    await transaction.optimistic()

    // add to execution queue
    let transactionId = await transactions.queue(transaction: transaction)
    log.trace("Queued transaction \(transaction.debugDescription)")

    // optionally if they want to wait for the result
    return try await withCheckedThrowingContinuation { continuation in
      Task {
        await storeContinuation(for: transactionId, continuation: continuation)
      }
    }
  }

  /// Send a transaction without waiting for a result.
  /// Optimistic updates still run immediately, and the transaction is queued in order.
  @discardableResult
  public nonisolated func sendQueued(_ transaction: any Transaction2) async -> TransactionId {
    // run optimistic immediately
    await transaction.optimistic()

    // add to execution queue
    let transactionId = await transactions.queue(transaction: transaction)
    log.trace("Queued transaction \(transaction.debugDescription)")
    return transactionId
  }

  /// Returns a stream of connection state changes that can be consumed from any task.
  public func connectionStates() -> AsyncStream<RealtimeConnectionState> {
    let id = UUID()
    return AsyncStream { continuation in
      Task { [weak self] in
        await self?.addConnectionStateContinuation(id: id, continuation: continuation)
      }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeConnectionStateContinuation(id) }
      }
    }
  }

  public func applyUpdates(_ updates: [InlineProtocol.Update]) {
    Task { await sync.process(updates: updates) }
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
        case let .rpcError(_, message, code):
          throw RealtimeDirectRpcError.rpcError(message: message, code: code)
        case .stopped:
          throw RealtimeDirectRpcError.notConnected
      }
    } catch {
      throw RealtimeDirectRpcError.unknown(error)
    }
  }

  public func cancelTransaction(where predicate: @escaping (TransactionWrapper) -> Bool) {
    Task { await transactions.cancel(where: predicate) }
  }

  public func updateSyncConfig(_ config: SyncConfig) {
    Task { await sync.updateConfig(config) }
  }

  public nonisolated func getEnableSyncMessageUpdates() -> Bool {
    RealtimeConfigStore.getEnableSyncMessageUpdates()
  }

  public func setEnableSyncMessageUpdates(_ enabled: Bool) {
    RealtimeConfigStore.setEnableSyncMessageUpdates(enabled)
    Task { await sync.updateConfig(syncConfig(for: enabled)) }
  }

  public func getSyncStats() async -> SyncStats {
    await sync.getStats()
  }

  public func clearSyncState() async {
    await sync.clearSyncState()
  }

  // MARK: - Helpers

  private func mapConnectionState(_ state: ConnectionState) -> RealtimeConnectionState {
    switch state {
    case .open:
      return .connected
    case .connectingTransport, .authenticating, .backoff, .waitingForConstraints, .backgroundSuspended, .stopped:
      return .connecting
    }
  }

  private func updateConnectionState(_ newState: RealtimeConnectionState) async {
    guard newState != currentConnectionState else { return }
    currentConnectionState = newState
    for continuation in connectionStateContinuations.values {
      continuation.yield(newState)
    }
    Task { await sync.connectionStateChanged(state: newState) }
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

  private func syncConfig(for enableMessageUpdates: Bool) -> SyncConfig {
    SyncConfig(
      enableMessageUpdates: enableMessageUpdates,
      lastSyncSafetyGapSeconds: SyncConfig.default.lastSyncSafetyGapSeconds
    )
  }
}
