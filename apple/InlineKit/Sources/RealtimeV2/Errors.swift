import InlineProtocol

public typealias TransactionError2 = TransactionError
public enum TransactionError: Error {
  case rpcError(InlineProtocol.RpcError)
  case timeout
  case invalid
  case cancelled
}

extension TransactionError {
  static func executionError(_ error: TransactionExecutionError) -> Self {
    switch error {
      case .invalid:
        // Map invalid execution errors to cancelled since it represents a failed transaction state
        .invalid
    }
  }
}
