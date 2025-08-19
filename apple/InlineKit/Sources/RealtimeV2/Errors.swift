import InlineProtocol

public enum TransactionError: Error {
  case rpcError(InlineProtocol.RpcError)
  case timeout
  case cancelled
}

extension TransactionError {
  static func executionError(_ error: TransactionExecutionError) -> Self {
    switch error {
      case .rpcError:
        // Map to a generic RPC error since we don't have the specific RpcError details
        .rpcError(InlineProtocol.RpcError())
      case .invalid:
        // Map invalid execution errors to cancelled since it represents a failed transaction state
        .cancelled
    }
  }
}
