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

  /// Async stream to signal run loop to check the transaction queue
  var queueStream: AsyncChannel<Void> = AsyncChannel()

  // Private
  private let log = Log.scoped("RealtimeV2/Transactions")
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

  public func queue(transaction: some Transaction) -> TransactionId {
    let wrapper = TransactionWrapper(transaction: transaction)
    let transactionId = wrapper.id

    log.debug("Queuing transaction \(transactionId): \(transaction.debugDescription)")

    // add to queue
    _queue[transactionId] = wrapper
    
    // FIXME: there might be a race condition where delete is called before save to disk
    Task(priority: .utility) {
      // persist
      saveToDisk(transaction: wrapper)
    }
    
    Task(priority: .userInitiated) {
      // send to stream
      await queueStream.send(())
    }



    return transactionId
  }

  /// Dequeue next transaction from the queue and mark it as in-flight.
  public func dequeue() -> TransactionWrapper? {
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
  public func running(transactionId: TransactionId, rpcMsgId: UInt64) {
    guard let _ = inFlight[transactionId] else {
      // if not found, it means it was already completed or discarded
      return
    }

    // map rpc msgId to transactionId
    transactionRpcMap[rpcMsgId] = transactionId
  }

  /// Acknowledge a transaction by the rpc message ID. It deletes the transaction from the system.
  public func ack(rpcMsgId: UInt64) {
    guard let transactionId = transactionRpcMap[rpcMsgId] else {
      // if not found, it means it was already completed or discarded
      return
    }

    ack(transactionId: transactionId)
  }

  /// Acknowledge a transaction that has been completed, it moves it to sent queue waiting for the result.
  func ack(transactionId: TransactionId) {
    log.debug("Acknowledging transaction \(transactionId) - moving to sent queue and deleting from disk")

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
      log.debug("Complete called for unknown rpcMsgId \(rpcMsgId) - transaction already completed or discarded")
      return nil
    }

    log
      .debug(
        "Completing transaction \(transactionId) (rpcMsgId: \(rpcMsgId)) - removing from all queues and deleting from disk"
      )

    // delete from all queues
    let transactionFromInFlight = inFlight.removeValue(forKey: transactionId)
    let transactionFromSent = sent.removeValue(forKey: transactionId)
    _ = _queue.removeValue(forKey: transactionId)

    // remove from rpc map
    transactionRpcMap.removeValue(forKey: rpcMsgId)

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

    // re-add to queue
    _queue[transactionId] = wrapper

    // signal the run loop
    Task {
      await queueStream.send(())
    }
  }

  public func requeueAll() {
    for (transactionId, wrapper) in inFlight {
      _queue[transactionId] = wrapper
    }
    inFlight.removeAll()

    // signal the run loop
    Task {
      await queueStream.send(())
    }
  }

  // MARK: - Helpers

  public func isInFlight(transactionId: TransactionId) -> Bool {
    inFlight[transactionId] != nil
  }

  public func isInQueue(transactionId: TransactionId) -> Bool {
    _queue[transactionId] != nil
  }

  public func transactionIdFrom(msgId: UInt64) -> TransactionId? {
    transactionRpcMap[msgId]
  }

  /// Cancel all transactions that match the predicate from the queue.
  public func cancel(where predicate: (TransactionWrapper) -> Bool) {
    for (transactionId, wrapper) in _queue {
      if predicate(wrapper) {
        log.debug("Cancelling transaction \(transactionId) \(wrapper.transaction.debugDescription)")
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

  private func saveToDisk(transaction: TransactionWrapper) {
    guard shouldSaveToDisk(transaction: transaction) else { return }

    Task.detached { [transaction, log, persistenceHandler] in
      do {
        if let persistenceHandler {
          log.debug("Saving transaction \(transaction.id) to disk: \(transaction.transaction.debugDescription)")
          try await persistenceHandler.saveTransaction(transaction)
          log.debug("Successfully saved transaction \(transaction.id) to disk")
        } else {
          log.debug("No persistence handler available, skipping save for transaction \(transaction.id)")
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
          log.debug("Deleting transaction \(transactionId) from disk")
          try await persistenceHandler.deleteTransaction(transactionId)
          log.debug("Successfully deleted transaction \(transactionId) from disk")
        } else {
          log.trace("No persistence handler available, skipping delete for transaction \(transactionId)")
        }
      } catch {
        // It's safe to ignore this error, the file may not exist, but better to be safe from infinite retries than
        // sorry
        log.debug("Failed to delete transaction \(transactionId) from disk (file may not exist): \(error)")
      }
    }
  }

  private func loadAllFromDisk() {
    Task { [weak self, log, persistenceHandler] in
      guard let self else { return }

      do {
        if let persistenceHandler {
          log.debug("Starting to load transactions from disk")
          let allTransactions = try await persistenceHandler.loadTransactions()
          log.debug("Loaded \(allTransactions.count) raw transactions from disk")

          // Separate valid and expired transactions
          let expirationDate = Date().addingTimeInterval(-10 * 60) // 10 minutes
          var validTransactions: [TransactionWrapper] = []
          var expiredTransactions: [TransactionWrapper] = []

          for transaction in allTransactions {
            if transaction.date < expirationDate {
              log.debug("Transaction \(transaction.id) expired (created: \(transaction.date))")
              expiredTransactions.append(transaction)
            } else {
              validTransactions.append(transaction)
            }
          }

          // Trigger failed() for expired transactions
          for expiredTransaction in expiredTransactions {
            log.info("Transaction \(expiredTransaction.id) expired, calling failed()")
            await expiredTransaction.transaction.failed(error: .timeout)

            // Delete expired transaction from disk
            try? await persistenceHandler.deleteTransaction(expiredTransaction.id)
          }

          // Sort valid transactions by creation date
          validTransactions.sort { $0.date < $1.date }
          log.debug("Sorted \(validTransactions.count) valid transactions by creation date")

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
