import Foundation

// Wrap automatically generated transaction code
public struct TransactionWrapper: Sendable, Identifiable {
  /// ID of the transaction
  public let id: TransactionId

  /// Date of initial creation
  public let date: Date

  /// Number of times this transaction has been retried after a server-side RPC error.
  public let rpcErrorRetryCount: Int

  /// Transaction to execute
  public let transaction: any Transaction

  init(transaction: some Transaction) {
    id = .generate()
    date = Date()
    rpcErrorRetryCount = 0
    self.transaction = transaction
  }
  
  // Public initializer for deserialization
  public init(
    id: TransactionId,
    date: Date,
    transaction: any Transaction,
    rpcErrorRetryCount: Int = 0
  ) {
    self.id = id
    self.date = date
    self.rpcErrorRetryCount = rpcErrorRetryCount
    self.transaction = transaction
  }

  func incrementingRpcErrorRetryCount() -> TransactionWrapper {
    TransactionWrapper(
      id: id,
      date: date,
      transaction: transaction,
      rpcErrorRetryCount: rpcErrorRetryCount + 1
    )
  }
}
