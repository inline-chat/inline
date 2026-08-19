import Foundation

public enum TransactionDispatchPhase: String, Codable, Sendable {
  /// Durable work is known not to have reached the transport dispatch boundary.
  case queued

  /// Dispatch may have reached the server; process death cannot prove rollback.
  case mayHaveExecuted
}

// Wrap automatically generated transaction code
public struct TransactionWrapper: Sendable, Identifiable {
  /// ID of the transaction
  public let id: TransactionId

  /// Date of initial creation
  public let date: Date

  /// Number of times this transaction has been retried after a server-side RPC error.
  public let rpcErrorRetryCount: Int

  /// Durable dispatch state used to distinguish unsent work from commit-unknown work.
  public let dispatchPhase: TransactionDispatchPhase

  /// Transaction to execute
  public let transaction: any Transaction

  init(transaction: some Transaction) {
    id = .generate()
    date = Date()
    rpcErrorRetryCount = 0
    dispatchPhase = .queued
    self.transaction = transaction
  }
  
  // Public initializer for deserialization
  public init(
    id: TransactionId,
    date: Date,
    transaction: any Transaction,
    rpcErrorRetryCount: Int = 0,
    dispatchPhase: TransactionDispatchPhase = .queued
  ) {
    self.id = id
    self.date = date
    self.rpcErrorRetryCount = rpcErrorRetryCount
    self.dispatchPhase = dispatchPhase
    self.transaction = transaction
  }

  func incrementingRpcErrorRetryCount() -> TransactionWrapper {
    TransactionWrapper(
      id: id,
      date: date,
      transaction: transaction,
      rpcErrorRetryCount: rpcErrorRetryCount + 1,
      dispatchPhase: .queued
    )
  }

  func withDispatchPhase(_ dispatchPhase: TransactionDispatchPhase) -> TransactionWrapper {
    TransactionWrapper(
      id: id,
      date: date,
      transaction: transaction,
      rpcErrorRetryCount: rpcErrorRetryCount,
      dispatchPhase: dispatchPhase
    )
  }
}
