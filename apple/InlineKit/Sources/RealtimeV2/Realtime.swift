import AsyncAlgorithms
import Auth
import Combine
import Foundation
import InlineProtocol
import Logger

/// Internal – later we will rename the main module to Realtime
///
/// This actor manages the real-time communication with the Inline Protocol server.
public actor RealtimeV2 {
  // MARK: - Core Components

  private var auth: Auth
  private var client: ProtocolClient
  private var sync: Sync
  private var transactions: Transactions
  private var queries: Queries

  // Public
  public var stateObject: RealtimeState

  // TODO:
  // transactions
  // queries
  // sync

  // MARK: - Private Properties

  private let log = Log.scoped("RealtimeV2")
  private var cancellables = Set<AnyCancellable>()
  private var tasks: Set<Task<Void, Never>> = []

  // Connection state channel for cross-task consumption and the latest cached state
  private let connectionStateChannel = AsyncChannel<RealtimeConnectionState>()
  private var currentConnectionState: RealtimeConnectionState = .connecting

  // Transaction execution
  private var transactionContinuations: [TransactionId: CheckedContinuation<
    InlineProtocol.RpcResult.OneOf_Result?,
    // TransactionError
    any Error
  >] = [:]

  // MARK: - Options

  private let retryDelay: TimeInterval = 2.0

  // MARK: - Initialization

  public init(transport: Transport, auth: Auth, applyUpdates: ApplyUpdates) {
    // self.transport = transport
    self.auth = auth
    client = ProtocolClient(transport: transport, auth: auth)
    sync = Sync(applyUpdates: applyUpdates)
    transactions = Transactions()
    queries = Queries()
    stateObject = RealtimeState()

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
      await client.stopTransport()
    }
  }

  // MARK: - Lifecycle

  /// Start core components, register listeners and start run loops.
  private func start() async {
    stateObject.start(realtime: self)
    await startListeners()

    if auth.isLoggedIn {
      await startTransport()
    }
  }

  /// Called when log out happens
  /// Reset all state to their initial values.
  /// Stop transport. But do not kill the listeners and tasks. This is state is recoverable via a transport start.
  private func stopAndReset() async {
    await client.stopTransport()
  }

  /// Listen for auth events, transport events, sync events, etc.
  private func startListeners() async {
    // Auth events
    Task.detached {
      self.log.debug("Starting auth events listener")
      for await event in await self.auth.events {
        guard !Task.isCancelled else { return }

        switch event {
          case .login:
            Task {
              await self.startTransport()
            }

          case .logout:
            Task { await self.stopAndReset() }
        }
      }
    }.store(in: &tasks)

    // Client/Transport events
    Task.detached {
      self.log.debug("Starting transport events listener")
      for await event in await self.client.events {
        guard !Task.isCancelled else { return }

        switch event {
          case .open:
            self.log.debug("Transport connected")
            Task {
              await self.updateConnectionState(.connected)
              await self.restartTransactions()
            }

          case .connecting:
            self.log.debug("Transport connecting")
            Task { await self.updateConnectionState(.connecting) }

          case let .ack(msgId):
            self.log.debug("Received ACK for message \(msgId)")
            Task { await self.ackTransaction(msgId: msgId) }

          case let .rpcResult(msgId, rpcResult):
            self.log.debug("Received RPC result for message \(msgId)")
            Task { await self.completeTransaction(msgId: msgId, rpcResult: rpcResult) }

          case let .rpcError(msgId, rpcError):
            self.log.debug("Received RPC error for message \(msgId)")
            Task { await self.completeTransaction(msgId: msgId, error: TransactionError.rpcError(rpcError)) }

          case let .updates(updates):
            self.log.debug("Received updates \(updates)")
            Task { await self.sync.process(updates: updates.updates) }
        }
      }
    }.store(in: &tasks)

    // Transactions
    Task.detached {
      self.log.debug("Starting transactions listener")
      for await _ in await self.transactions.queueStream {
        guard await self.currentConnectionState == .connected else {
          self.log.debug("Skipping transaction queue stream as connection is not connected")
          continue
        }

        while let transaction = await self.transactions.dequeue() {
          self.log.debug("Dequeued transaction \(transaction.id)")
          await self.runTransaction(transaction)
        }
      }
    }.store(in: &tasks)
  }

  private func startTransport() async {
    await updateConnectionState(.connecting)
    await client.startTransport()
  }

  private func stopTransport() async {
    await client.stopTransport()
  }

  private func runTransaction(_ transactionWrapper: TransactionWrapper) async {
    log.debug("Running transaction \(transactionWrapper.id) with method \(transactionWrapper.transaction.method)")
    let transaction = transactionWrapper.transaction
    // send as RPC
    // mark as running
    Task {
      // send as RPC message
      let msgId = try await client.sendRpc(method: transaction.method, input: transaction.input)
      // mark as running
      await transactions.running(transactionId: transactionWrapper.id, rpcMsgId: msgId)
      // the rest of the work (ack, etc) is handled later
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

    log.debug("Transaction \(transactionId) completed with result \(rpcResult)")

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

  // MARK: - Public API

  @discardableResult
  public func send(_ transaction: any Transaction2) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    // run optimistic immediately
    Task(priority: .userInitiated) { @MainActor in
      await transaction.optimistic()
    }

    // add to execution queue
    let transactionId = await transactions.queue(transaction: transaction)
    log.debug("Queued transaction \(transaction.debugDescription)")

    // optionally if they want to wait for the result
    return try await withCheckedThrowingContinuation { continuation in
      transactionContinuations[transactionId] = continuation
//      as? CheckedContinuation<
//        RpcResult.OneOf_Result?,
//        TransactionError
//      >
    }
  }

  /// Returns a stream of connection state changes that can be consumed from any task.
  public func connectionStates() -> AsyncStream<RealtimeConnectionState> {
    let channel = connectionStateChannel
    return AsyncStream { continuation in
      let task = Task {
        for await state in channel {
          continuation.yield(state)
        }
        continuation.finish()
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  // MARK: - Helpers

  private func updateConnectionState(_ newState: RealtimeConnectionState) async {
    guard newState != currentConnectionState else { return }
    currentConnectionState = newState
    Task { await connectionStateChannel.send(newState) }
  }
}
