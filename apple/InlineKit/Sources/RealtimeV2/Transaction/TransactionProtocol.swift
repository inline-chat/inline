import InlineProtocol

enum TransactionExecutionError: Error {
  case rpcError // todo
  case invalid
}

protocol Transaction: Sendable {
  associatedtype Result

  var method: InlineProtocol.Method { get set }
  var input: InlineProtocol.RpcCall.OneOf_Input? { get set }

  func execute() async throws(TransactionExecutionError) -> Result

  /// Apply the result of the query to database
  /// Error propagated to the caller of the query
  func apply(result: Result) throws

  /// Optimistically update the database
  func optimistic()

  /// Called when the transaction is cancelled
  func cancelled()

  /// Called when the transaction fails to execute
  func failed()
}
