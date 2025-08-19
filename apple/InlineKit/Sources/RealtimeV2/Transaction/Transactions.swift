import AsyncAlgorithms
import Collections
import Foundation

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

  init() {
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

    // add to queue
    _queue[transactionId] = wrapper

    // persist
    saveToDisk(transaction: wrapper)

    Task {
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
    // delete(transactionId: transactionId)
    // move to sent
    sent[transactionId] = inFlight[transactionId]

    // remove from in-flight
    inFlight.removeValue(forKey: transactionId)

    // delete from disk because we no longer need to retry it
    deleteFromDisk(transactionId: transactionId)
  }

  /// Complete a transaction by the rpc message ID. Called when a response or error is received.
  /// It deletes the transaction from the system.
  func complete(rpcMsgId: UInt64) -> TransactionWrapper? {
    guard let transactionId = transactionRpcMap[rpcMsgId] else {
      // if not found, it means it was already completed or discarded
      return nil
    }

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
  }

  public func requeueAll() {
    for (transactionId, wrapper) in inFlight {
      _queue[transactionId] = wrapper
    }
    inFlight.removeAll()
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

  // MARK: - Private APIs

  private func saveToDisk(transaction: TransactionWrapper) {
    // todo
  }

  private func deleteFromDisk(transactionId: TransactionId) {
    // todo
  }

  private func loadAllFromDisk() {
    // todo
    // for transaction in transactions {
    //   queue[transaction.id] = transaction
    // }
  }
}
