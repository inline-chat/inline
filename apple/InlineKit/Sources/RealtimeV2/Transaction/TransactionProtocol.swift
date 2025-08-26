import Foundation
import InlineProtocol
import Logger

public enum TransactionExecutionError: Error {
  case invalid
}

public struct QueryConfig: Sendable {
  public init() {}
}

public struct MutationConfig: Sendable {
  public var transient: Bool = false

  public init(transient: Bool = false) {
    self.transient = transient
  }
}

public enum TransactionKindType: Sendable {
  /// Query is a transaction that will not be persisted to disk
  case query(QueryConfig = QueryConfig())

  /// Mutations will be persisted to disk for the duration of the timeout
  case mutation(MutationConfig = MutationConfig())
}

public protocol Transaction: Sendable, Codable {
  var method: InlineProtocol.Method { get set }
  var type: TransactionKindType { get set }

  associatedtype Context: Sendable, Codable

  var context: Context { get set }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input?

  /// Apply the result of the query to database
  /// Error propagated to the caller of the query
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError)

  /// Optimistically update the database
  func optimistic() async

  /// Called when the transaction fails to execute
  func failed(error: TransactionError) async

  /// Called when the transaction is cancelled
  func cancelled() async
}

public extension Transaction {
  var debugDescription: String {
    """
    Transaction
    method: \(method)
    input: \(String(describing: input)))
    """
  }
}

public extension Transaction {
  func cancelled() async {}
  func optimistic() async {}
  func failed(error: TransactionError) async {
    Log.shared.error("Transaction failed \(debugDescription)", error: error)
  }

  var input: InlineProtocol.RpcCall.OneOf_Input? {
    input(from: context)
  }
}
