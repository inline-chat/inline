import AsyncAlgorithms
import Collections
import Foundation
import Logger

actor Transactions {
  /// Transactions that are queued to be run
  var _queue: OrderedDictionary<TransactionId, TransactionWrapper> = [:]

  /// Transactions that have an RPC call in progress
  var inFlight: [TransactionId: TransactionWrapper] = [:]

  /// Transactions that have been sent but not yet completed
  var sent: [TransactionId: TransactionWrapper] = [:]

  /// Make of transport RPC msgId to transactionId
  var transactionRpcMap: [UInt64: TransactionId] = [:]
  private var pendingAckMsgIds: Set<UInt64> = []

  /// Async stream to signal run loop to check the transaction queue
  var queueStream: AsyncChannel<Void> = AsyncChannel()

  // Private
  private let log = Log.scoped("RealtimeV2.Transactions", level: .debug)
  private var persistenceHandler: TransactionPersistenceHandler?

  init(persistenceHandler: TransactionPersistenceHandler? = nil) {
    self.persistenceHandler = persistenceHandler
    Task {
      // load all transactions from disk into queue
      await loadAllFromDisk()
      // signal the run loop
      await queueStream.send(())
    }
  }

  func queue(transaction: some Transaction) -> TransactionId {
    let transactionId = TransactionId.generate()
    enqueue(transaction: transaction, transactionId: transactionId)
    Task(priority: .userInitiated) {
      await queueStream.send(())
    }
    return transactionId
  }

  /// Queue without notifying the run-loop yet.
  /// Useful when callers must atomically register continuations before execution starts.
  func enqueue(transaction: some Transaction) -> TransactionId {
    let transactionId = TransactionId.generate()
    enqueue(transaction: transaction, transactionId: transactionId)
    return transactionId
  }

  /// Queue without notifying the run-loop yet, using a caller-provided transaction ID.
  /// Useful when the caller must register state keyed by transaction ID before execution starts.
  func enqueue(transaction: some Transaction, transactionId: TransactionId) {
    let wrapper = TransactionWrapper(id: transactionId, date: Date(), transaction: transaction)
    enqueue(wrapper)
  }

  private func enqueue(_ wrapper: TransactionWrapper) {
    let transactionId = wrapper.id

    log.trace("Queuing transaction \(transactionId): \(wrapper.transaction.debugDescription)")

    // add to queue
    _queue[transactionId] = wrapper

    // FIXME: there might be a race condition where delete is called before save to disk
    Task(priority: .utility) {
      // persist
      saveToDisk(transaction: wrapper)
    }
  }

  func signalQueue() async {
    await queueStream.send(())
  }

  /// Dequeue next transaction from the queue and mark it as in-flight.
  func dequeue() -> TransactionWrapper? {
    guard let first = _queue.keys.first else { return nil }
    let transactionId = first
    let wrapper = _queue[first]

    // remove from queue
    _queue.removeValue(forKey: transactionId)

    // add to in-flight
    inFlight[transactionId] = wrapper

    return wrapper
  }

  /// Mark a transaction as running, which means it has an RPC call in progress.
  func running(transactionId: TransactionId, rpcMsgId: UInt64) {
    guard let _ = inFlight[transactionId] else {
      // if not found, it means it was already completed or discarded
      return
    }

    // map rpc msgId to transactionId
    transactionRpcMap[rpcMsgId] = transactionId

    // ACK can arrive before `running` registration on fast transports.
    if pendingAckMsgIds.remove(rpcMsgId) != nil {
      ack(transactionId: transactionId)
    }
  }

  /// Acknowledge a transaction by the rpc message ID. It deletes the transaction from the system.
  func ack(rpcMsgId: UInt64) {
    guard let transactionId = transactionRpcMap[rpcMsgId] else {
      // ACK can race ahead of running() registration; keep it pending.
      pendingAckMsgIds.insert(rpcMsgId)
      return
    }

    ack(transactionId: transactionId)
  }

  /// Acknowledge a transaction that has been completed, it moves it to sent queue waiting for the result.
  func ack(transactionId: TransactionId) {
    log.trace("Acknowledging transaction \(transactionId) - moving to sent queue and deleting from disk")

    // move to sent
    sent[transactionId] = inFlight[transactionId]

    // remove from in-flight
    _ = inFlight.removeValue(forKey: transactionId)

    // delete from disk because we no longer need to retry it
    deleteFromDisk(transactionId: transactionId)
  }

  /// Complete a transaction by the rpc message ID. Called when a response or error is received.
  /// It deletes the transaction from the system.
  func complete(rpcMsgId: UInt64) -> TransactionWrapper? {
    guard let transactionId = transactionRpcMap[rpcMsgId] else {
      pendingAckMsgIds.remove(rpcMsgId)
      log.trace("Complete called for unknown rpcMsgId \(rpcMsgId) - transaction already completed or discarded")
      return nil
    }

    log
      .trace(
        "Completing transaction \(transactionId) (rpcMsgId: \(rpcMsgId)) - removing from all queues and deleting from disk"
      )

    // delete from all queues
    let transactionFromInFlight = inFlight.removeValue(forKey: transactionId)
    let transactionFromSent = sent.removeValue(forKey: transactionId)
    _ = _queue.removeValue(forKey: transactionId)

    // remove from rpc map
    transactionRpcMap.removeValue(forKey: rpcMsgId)
    pendingAckMsgIds.remove(rpcMsgId)

    // delete from disk because we no longer need to retry it
    deleteFromDisk(transactionId: transactionId)

    // In case we have missed the ACK, we return the transaction from in-flight
    return transactionFromSent ?? transactionFromInFlight
  }

  /// Requeue a transaction that needs to be retried
  func requeue(transactionId: TransactionId) {
    guard let wrapper = inFlight[transactionId] else {
      // if not found, it means it was already completed or discarded
      return
    }

    // remove from in-flight
    inFlight.removeValue(forKey: transactionId)
    removeRpcMappings(for: [transactionId])

    // re-add to queue
    _queue[transactionId] = wrapper

    // signal the run loop
    Task {
      await queueStream.send(())
    }
  }

  @discardableResult
  func requeueAll() -> [TransactionWrapper] {
    var requeuedIds = Set<TransactionId>()
    var dropped = [TransactionWrapper]()
    var droppedIds = Set<TransactionId>()

    for (transactionId, wrapper) in inFlight {
      _queue[transactionId] = wrapper
      requeuedIds.insert(transactionId)
    }
    inFlight.removeAll()

    for (transactionId, wrapper) in sent {
      if shouldRetryAfterAck(transaction: wrapper) {
        _queue[transactionId] = wrapper
        requeuedIds.insert(transactionId)
      } else {
        dropped.append(wrapper)
        droppedIds.insert(transactionId)
      }
    }
    sent.removeAll()

    removeRpcMappings(for: requeuedIds.union(droppedIds))

    guard !requeuedIds.isEmpty else { return dropped }

    Task {
      await queueStream.send(())
    }

    return dropped
  }

  // MARK: - Helpers

  func isInFlight(transactionId: TransactionId) -> Bool {
    inFlight[transactionId] != nil
  }

  func isInQueue(transactionId: TransactionId) -> Bool {
    _queue[transactionId] != nil
  }

  func transactionIdFrom(msgId: UInt64) -> TransactionId? {
    transactionRpcMap[msgId]
  }

  /// Called when a transport/session disconnect happens.
  /// RPC message IDs are session-scoped and must not survive reconnect boundaries.
  func connectionLost() {
    transactionRpcMap.removeAll()
    pendingAckMsgIds.removeAll()
  }

  /// Cancel all transactions that match the predicate from the queue.
  func cancel(where predicate: @Sendable (TransactionWrapper) -> Bool) {
    for (transactionId, wrapper) in _queue {
      if predicate(wrapper) {
        log.trace("Cancelling transaction \(transactionId) \(wrapper.transaction.debugDescription)")
        Task {
          await wrapper.transaction.cancelled()
        }
        _queue.removeValue(forKey: transactionId)
      }
    }
  }

  // MARK: - Private APIs

  private func shouldSaveToDisk(transaction: TransactionWrapper) -> Bool {
    switch transaction.transaction.type {
      case .query:
        false
      case let .mutation(config):
        config.transient ? false : true
    }
  }

  private func shouldRetryAfterAck(transaction: TransactionWrapper) -> Bool {
    switch transaction.transaction.type {
      case .query:
        false
      case let .mutation(config):
        config.retryAfterAck
    }
  }

  private func removeRpcMappings(for transactionIds: Set<TransactionId>) {
    guard !transactionIds.isEmpty else { return }
    transactionRpcMap = transactionRpcMap.filter { _, transactionId in
      !transactionIds.contains(transactionId)
    }
  }

  private func saveToDisk(transaction: TransactionWrapper) {
    guard shouldSaveToDisk(transaction: transaction) else { return }

    Task.detached { [transaction, log, persistenceHandler] in
      do {
        if let persistenceHandler {
          log.trace("Saving transaction \(transaction.id) to disk: \(transaction.transaction.debugDescription)")
          try await persistenceHandler.saveTransaction(transaction)
          log.trace("Successfully saved transaction \(transaction.id) to disk")
        } else {
          log.trace("No persistence handler available, skipping save for transaction \(transaction.id)")
        }
      } catch {
        log.error("Failed to save transaction \(transaction.id) to disk", error: error)
      }
    }
  }

  private func deleteFromDisk(transactionId: TransactionId) {
    Task.detached { [transactionId, persistenceHandler, log] in
      do {
        if let persistenceHandler {
          log.trace("Deleting transaction \(transactionId) from disk")
          try await persistenceHandler.deleteTransaction(transactionId)
          log.trace("Successfully deleted transaction \(transactionId) from disk")
        } else {
          log.trace("No persistence handler available, skipping delete for transaction \(transactionId)")
        }
      } catch {
        // FIXME: distinguish between queries and mutations to avoid showing errors for queries that are not persisted
        // It's safe to ignore this error, the file may not exist, but better to be safe from infinite retries than
        // sorry
        log.trace("Failed to delete transaction \(transactionId) from disk (file may not exist): \(error)")
      }
    }
  }

  private func loadAllFromDisk() {
    Task { [weak self, log, persistenceHandler] in
      guard let self else { return }

      do {
        if let persistenceHandler {
          log.trace("Starting to load transactions from disk")
          let allTransactions = try await persistenceHandler.loadTransactions()
          log.trace("Loaded \(allTransactions.count) raw transactions from disk")

          // Separate valid and expired transactions
          let expirationDate = Date().addingTimeInterval(-10 * 60) // 10 minutes
          var validTransactions: [TransactionWrapper] = []
          var expiredTransactions: [TransactionWrapper] = []

          for transaction in allTransactions {
            if transaction.date < expirationDate {
              log.trace("Transaction \(transaction.id) expired (created: \(transaction.date))")
              expiredTransactions.append(transaction)
            } else {
              validTransactions.append(transaction)
            }
          }

          // Trigger failed() for expired transactions
          for expiredTransaction in expiredTransactions {
            log.debug("Transaction \(expiredTransaction.id) expired, calling failed()")
            await expiredTransaction.transaction.failed(error: .timeout)

            // Delete expired transaction from disk
            try? await persistenceHandler.deleteTransaction(expiredTransaction.id)
          }

          // Sort valid transactions by creation date
          validTransactions.sort { $0.date < $1.date }
          log.trace("Sorted \(validTransactions.count) valid transactions by creation date")

          // Add loaded transactions to queue
          await addLoadedTransactions(validTransactions)

          log.info("Loaded \(validTransactions.count) transactions from disk, expired \(expiredTransactions.count)")
        } else {
          log.debug("No persistence handler available, skipping load from disk")
        }
      } catch {
        log.error("Failed to load transactions from disk", error: error)
      }
    }
  }

  private func addLoadedTransactions(_ transactions: [TransactionWrapper]) {
    for transaction in transactions {
      _queue[transaction.id] = transaction
    }
  }
}

// MARK: - Transaction Persistence Protocol

public protocol TransactionPersistenceHandler: Sendable {
  func saveTransaction(_ transaction: TransactionWrapper) async throws
  func deleteTransaction(_ transactionId: TransactionId) async throws
  func loadTransactions() async throws -> [TransactionWrapper]
}
