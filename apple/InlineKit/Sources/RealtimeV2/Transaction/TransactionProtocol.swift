import InlineProtocol

public enum TransactionExecutionError: Error {
  case invalid
}

public protocol Transaction: Sendable, Codable {
  var method: InlineProtocol.Method { get set }
  var input: InlineProtocol.RpcCall.OneOf_Input? { get set }

  // func execute() async throws(TransactionExecutionError) -> Result

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
}
