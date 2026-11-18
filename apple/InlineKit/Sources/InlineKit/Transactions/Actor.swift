import Foundation
import RealtimeV2

/// Runs transactions, retry, etc
actor TransactionsActor {
  // MARK: - Types

  typealias CompletionHandler = @Sendable (any Transaction) -> Void

  private struct ActiveTransaction {
    let transactionId: String
    let task: Task<Void, Never>
    let inSendLane: Bool
  }

  private struct CancelMarker {
    let transactionId: String
    let sequence: UInt64
  }

  // MARK: - Private Properties

  private var isRunning = true
  private var isClearing = false
  private var queue: [any Transaction] = []
  private var currentTask: Task<Void, Never>?
  private var activeTransactions: [UUID: ActiveTransaction] = [:]
  private let maxConcurrentTransactions = 4
  /// Message sends run in their own lane. A media send holds its slot through its upload and,
  /// in an album, until every item's upload settles; sharing the 4 general slots let one chat's
  /// album hold back a photo sent to another chat. Bytes in flight are bounded by the upload part
  /// window and video exports by the compressor, so this cap only bounds waiting tasks. Sends of
  /// one chat still go out in admission order (`OutgoingSendOrder`): the lane is FIFO.
  static let maxConcurrentSends = 24
  private let maxCancelMarkers = 4_096

  private let workSignals: AsyncStream<Void>
  private let workContinuation: AsyncStream<Void>.Continuation

  // Return when done
  private var completionHandler: CompletionHandler?

  private var cancelMarkers: [String: UInt64] = [:]
  private var cancelMarkerOrder: [CancelMarker] = []
  private var cancelMarkerHead = 0
  private var nextCancelMarkerSequence: UInt64 = 0

  var cancelMarkerCount: Int { cancelMarkers.count }

  // MARK: - Lifecycle

  typealias ConnectionWaiter = @Sendable () async throws -> Void

  /// Waits for the realtime connection. Injected so tests never touch the shared realtime client.
  private let waitForConnection: ConnectionWaiter
  private let pendingMediaSends: PendingMediaSends
  /// A send whose connection wait keeps returning without the error clearing is bounded, so a
  /// misclassified error cannot spin forever.
  static let maxConnectionWaits = 1_000

  init(
    waitForConnection: @escaping ConnectionWaiter = TransactionsActor.waitForRealtimeConnection,
    pendingMediaSends: PendingMediaSends = .shared
  ) {
    self.pendingMediaSends = pendingMediaSends
    let stream = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    workSignals = stream.stream
    workContinuation = stream.continuation
    self.waitForConnection = waitForConnection
  }

  static let waitForRealtimeConnection: ConnectionWaiter = {
    try await waitUntilConnected(states: await Api.realtime.connectionStates())
  }

  /// Returns once the connection is usable. If it was already usable, the error came from
  /// something else (for example a transfer socket), so wait `settle` before retrying.
  static func waitUntilConnected(
    states: AsyncStream<RealtimeConnectionState>,
    settle: Duration = .seconds(2)
  ) async throws {
    var sawDisconnect = false
    for await state in states {
      switch state {
        case .connecting:
          sawDisconnect = true
        case .connected, .updating:
          if !sawDisconnect { try await Task.sleep(for: settle) }
          return
      }
    }
    // The stream ends when the task is cancelled.
    throw CancellationError()
  }

  deinit {
    isRunning = false
    currentTask?.cancel()
    for activeTransaction in activeTransactions.values {
      activeTransaction.task.cancel()
    }
    workContinuation.finish()

    // Clear the queue
    queue.removeAll()
  }

  // MARK: - Public Methods

  public func clearAll() async {
    isClearing = true
    let queued = queue
    queue.removeAll()
    for transaction in queued {
      await transaction.rollback()
      finish(transaction)
    }

    let activeTasks = activeTransactions.values.map(\.task)
    for task in activeTasks {
      task.cancel()
    }
    for task in activeTasks {
      await task.value
    }
    activeTransactions.removeAll()
    clearCancelMarkers()
    isClearing = false
    signalWorkAvailable()
  }

  func setCompletionHandler(_ handler: @escaping CompletionHandler) {
    completionHandler = handler
  }

  /// Every transaction leaves through here, whatever its outcome.
  private func finish(_ transaction: any Transaction) {
    pendingMediaSends.remove(transactionId: transaction.id)
    completionHandler?(transaction)
  }

  func cancel(transactionId: String) async {
    let queuedTransactions = queue.filter { $0.id == transactionId }
    if !queuedTransactions.isEmpty {
      queue.removeAll { $0.id == transactionId }
      insertCancelMarker(transactionId)
      for transaction in queuedTransactions {
        await transaction.rollback()
        finish(transaction)
      }
      return
    }

    let matchingTasks = activeTransactions.values
      .filter { $0.transactionId == transactionId }
      .map(\.task)
    guard !matchingTasks.isEmpty else {
      insertCancelMarker(transactionId)
      return
    }
    insertCancelMarker(transactionId)
    for task in matchingTasks {
      task.cancel()
    }
  }

  public func queue(transaction: consuming any Transaction) async {
    if consumeCancelMarker(transaction.id) {
      let rejectedTransaction = consume transaction
      await rejectedTransaction.rollback()
      finish(rejectedTransaction)
      return
    }

    if isClearing {
      let rejectedTransaction = consume transaction
      await rejectedTransaction.rollback()
      finish(rejectedTransaction)
      return
    }

    if let send = transaction.pendingMediaSend { pendingMediaSends.insert(send) }
    queue.append(consume transaction)
    signalWorkAvailable()
  }

  public func run(transaction: some Transaction) async {
    defer { removeCancelMarker(transaction.id) }
    do {
      let result = try await executeWithRetry(transaction)

      await transaction.didSucceed(result: result)
      finish(transaction)
    } catch TransactionError.canceled {
      await transaction.rollback()
      finish(transaction)
    } catch is CancellationError {
      await transaction.rollback()
      finish(transaction)
    } catch {
      await transaction.didFail(error: error)
      finish(transaction)
    }
  }

  private func executeWithRetry<T: Transaction>(_ transaction: T) async throws -> T.R {
    var attempts = 0
    var connectionWaits = 0
    // Always allow at least one attempt even if maxRetries == 0
    let maxAttempts = max(transaction.config.maxRetries, 0) + 1

    while attempts < maxAttempts {
      // Early-exit if user canceled
      if cancelMarkers[transaction.id] != nil || Task.isCancelled {
        throw TransactionError.canceled
      }

      do {
        // Wrap execute() in a timeout if a positive timeout is configured
        let result: T.R
        if transaction.config.executionTimeout > 0 {
          result = try await withThrowingTaskGroup(of: T.R.self) { group in
            // Task that performs the actual execution
            group.addTask {
              try await transaction.execute()
            }

            // Task that enforces the timeout
            group.addTask {
              try await Task.sleep(nanoseconds: UInt64(transaction.config.executionTimeout * 1_000_000_000))
              throw TransactionError.timeout
            }

            // Return the first finished child (throws if it threw)
            let value = try await group.next()!
            group.cancelAll()
            return value
          }
        } else {
          // No timeout requested
          result = try await transaction.execute()
        }

        return result
      } catch {
        try Task.checkCancellation()
        // If error is cancel/timeout just propagate – no retry.
        if case TransactionError.canceled = error {
          throw error
        }
        if case TransactionError.timeout = error {
          throw error
        }

        // Offline or reconnecting: wait for the connection without spending an attempt.
        if transaction.waitsForConnection(after: error), connectionWaits < Self.maxConnectionWaits {
          connectionWaits += 1
          try await waitForConnection()
          continue
        }

        // Decide if we should retry
        if transaction.shouldRetryOnFail(error: error),
           attempts + 1 < min(maxAttempts, max(0, transaction.retryLimit(for: error)) + 1) {
          attempts += 1
          let delay = max(0, transaction.retryDelay(afterAttempt: attempts, error: error))
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          continue
        } else {
          throw error
        }
      }
    }

    throw TransactionError.maxRetriesExceeded
  }

  // MARK: - Private Methods

  /// Starts queued transactions in admission order while their lane has room. A full lane never
  /// holds back the other one, and each lane stays in admission order.
  private func fillAvailableSlots() {
    guard isRunning, !isClearing else { return }
    var running = activeTransactions.values.reduce(into: (general: 0, sends: 0)) {
      if $1.inSendLane { $0.sends += 1 } else { $0.general += 1 }
    }
    var index = 0
    while index < queue.count {
      let inSendLane = queue[index].runsInSendLane
      let hasRoom = inSendLane
        ? running.sends < Self.maxConcurrentSends
        : running.general < maxConcurrentTransactions
      guard hasRoom else {
        index += 1
        continue
      }
      if inSendLane { running.sends += 1 } else { running.general += 1 }
      startTransaction(queue.remove(at: index))
    }
  }

  private func startTransaction(_ transaction: consuming any Transaction) {
    let token = UUID()
    let transactionId = transaction.id
    let inSendLane = transaction.runsInSendLane
    let transactionForTask = consume transaction
    let task = Task { [weak self] in
      guard let self else { return }
      await self.run(transaction: transactionForTask)
      await self.transactionDidFinish(token: token)
    }
    activeTransactions[token] = ActiveTransaction(transactionId: transactionId, task: task, inSendLane: inSendLane)
  }

  private func transactionDidFinish(token: UUID) {
    activeTransactions.removeValue(forKey: token)
    signalWorkAvailable()
  }

  private func signalWorkAvailable() {
    ensureWorkerStarted()
    workContinuation.yield(())
  }

  private func ensureWorkerStarted() {
    guard currentTask == nil else { return }
    let signals = workSignals
    currentTask = Task { [weak self] in
      for await _ in signals {
        guard !Task.isCancelled, let self else { return }
        await self.fillAvailableSlots()
      }
    }
  }

  private func removeCancelMarker(_ id: String) {
    _ = consumeCancelMarker(id)
  }

  @discardableResult
  private func consumeCancelMarker(_ id: String) -> Bool {
    guard cancelMarkers.removeValue(forKey: id) != nil else { return false }
    compactCancelMarkerOrderIfNeeded()
    return true
  }

  private func insertCancelMarker(_ id: String) {
    guard cancelMarkers[id] == nil else { return }

    nextCancelMarkerSequence &+= 1
    let marker = CancelMarker(transactionId: id, sequence: nextCancelMarkerSequence)
    cancelMarkers[id] = marker.sequence
    cancelMarkerOrder.append(marker)

    while cancelMarkers.count > maxCancelMarkers,
          cancelMarkerHead < cancelMarkerOrder.count {
      let expired = cancelMarkerOrder[cancelMarkerHead]
      cancelMarkerHead += 1
      if cancelMarkers[expired.transactionId] == expired.sequence {
        cancelMarkers.removeValue(forKey: expired.transactionId)
      }
    }

    compactCancelMarkerOrderIfNeeded()
  }

  private func compactCancelMarkerOrderIfNeeded() {
    guard cancelMarkerHead >= maxCancelMarkers || cancelMarkerOrder.count > maxCancelMarkers * 2 else {
      return
    }

    cancelMarkerOrder = cancelMarkerOrder[cancelMarkerHead...].filter { marker in
      cancelMarkers[marker.transactionId] == marker.sequence
    }
    cancelMarkerHead = 0
  }

  private func clearCancelMarkers() {
    cancelMarkers.removeAll()
    cancelMarkerOrder.removeAll()
    cancelMarkerHead = 0
  }
}
