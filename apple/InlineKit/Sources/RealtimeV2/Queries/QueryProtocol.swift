import InlineProtocol

protocol Query {
  associatedtype Result

  func execute(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?
  ) async throws -> RpcResult.OneOf_Result

  /// Apply the result of the query to database
  /// Error propagated to the caller of the query
  func apply(result: RpcResult.OneOf_Result) throws -> Result
}
