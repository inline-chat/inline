import InlineProtocol
import Logger

public typealias TransactionError2 = TransactionError

/// Why a history page could not be admitted. Reported as a telemetry category;
/// callers still receive `TransactionExecutionError.historyUnavailable`.
public enum HistoryUnavailableReason: String, Error, Sendable {
  case missingSequence = "missing_sequence"
  case syncInactive = "sync_inactive"
  case bucketUnresolved = "bucket_unresolved"
  case snapshotTimeout = "snapshot_timeout"
  case admission
}

public enum TransactionError: Error, PrivacySafeErrorCategoryProviding {
  case rpcError(InlineProtocol.RpcError)
  case timeout
  case invalid
  case historyUnavailable(HistoryUnavailableReason)
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
      case let .historyUnavailable(reason):
        "transaction:history_unavailable:\(reason.rawValue)"
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

/// How a failed completion reaches the transaction. The awaiting caller always
/// receives the precise error through its continuation.
enum TransactionCompletionFailure {
  /// A newer request or owner replaced this one; expected, not a failure.
  case superseded
  case failed(TransactionError)

  init(_ error: any Error, historyUnavailable reason: HistoryUnavailableReason) {
    if error is CancellationError {
      self = .superseded
      return
    }
    switch error as? TransactionExecutionError {
      case .staleHistory: self = .superseded
      case .historyUnavailable: self = .failed(.historyUnavailable(reason))
      case .invalid, nil: self = .failed(.invalid)
    }
  }
}
