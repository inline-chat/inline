import InlineProtocol
import Logger

public typealias TransactionError2 = TransactionError
public enum TransactionError: Error, PrivacySafeErrorCategoryProviding {
  case rpcError(InlineProtocol.RpcError)
  case timeout
  case invalid
  case persistenceFailed
  case commitOutcomeUnknownAfterReconnect
  case rejectedBeforeExecution
  case dependencyFailed

  public var privacySafeErrorCategory: String {
    switch self {
    case let .rpcError(error):
      "transaction:rpc:\(error.errorCode.rawValue):\(error.code)"
    case .timeout:
      "transaction:timeout"
    case .invalid:
      "transaction:invalid"
    case .persistenceFailed:
      "transaction:persistence_failed"
    case .commitOutcomeUnknownAfterReconnect:
      "transaction:commit_outcome_unknown"
    case .rejectedBeforeExecution:
      "transaction:rejected_before_execution"
    case .dependencyFailed:
      "transaction:dependency_failed"
    }
  }
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
