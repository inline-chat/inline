import Collections
import Foundation

actor Transactions {
  /// Transactions that are queued to be run
  var queue: OrderedDictionary<TransactionId, TransactionWrapper> = [:]

  /// Transactions that have an RPC call in progress
  var inFlight: OrderedDictionary<TransactionId, TransactionWrapper> = [:]

  /// Make of transport RPC msgId to transactionId
  var transactionRpcMap: [Int64: TransactionId] = [:]

  init() {}

  public func queue(transaction: any Transaction) -> TransactionId {
    let wrapper = TransactionWrapper(transaction: transaction)
    let transactionId = wrapper.id

    // add to queue
    queue[transactionId] = wrapper

    // persist
    saveToDisk(transaction: wrapper)

    return transactionId
  }

  /// Dequeue next transaction from the queue and mark it as in-flight.
  public func dequeue() -> TransactionWrapper? {
    guard let first = queue.keys.first else { return nil }
    let transactionId = first
    let wrapper = queue[first]

    // remove from queue
    queue.removeValue(forKey: transactionId)

    // add to in-flight
    inFlight[transactionId] = wrapper

    return wrapper
  }

  /// Mark a transaction as running, which means it has an RPC call in progress.
  public func running(transactionId: TransactionId, rpcMsgId: Int64) {
    guard let wrapper = inFlight[transactionId] else {
      // if not found, it means it was already completed or discarded
      return
    }

    // map rpc msgId to transactionId
    transactionRpcMap[rpcMsgId] = transactionId
  }

  /// Acknowledge a transaction by the rpc message ID
  public func ack(rpcMsgId: Int64) {
    guard let transactionId = transactionRpcMap[rpcMsgId] else {
      // if not found, it means it was already completed or discarded
      return
    }

    ack(transactionId: transactionId)
  }

  /// Acknowledge a transaction that has been completed and deletes it from the system
  func ack(transactionId: TransactionId) {
    delete(transactionId: transactionId)
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
    queue[transactionId] = wrapper

    // persist
    saveToDisk(transaction: wrapper)
  }

  // MARK: - Helpers

  public func isInFlight(transactionId: TransactionId) -> Bool {
    inFlight[transactionId] != nil
  }

  public func isInQueue(transactionId: TransactionId) -> Bool {
    queue[transactionId] != nil
  }

  public func transactionIdFrom(msgId: Int64) -> TransactionId? {
    transactionRpcMap[msgId]
  }

  // MARK: - Private APIs

  public func delete(transactionId: TransactionId) {
    queue.removeValue(forKey: transactionId)
    inFlight.removeValue(forKey: transactionId)
    transactionRpcMap = transactionRpcMap.filter { $0.value != transactionId }
    deleteFromDisk(transactionId: transactionId)
  }

  private func saveToDisk(transaction: TransactionWrapper) {
    // todo
  }

  private func deleteFromDisk(transactionId: TransactionId) {
    // todo
  }
}
