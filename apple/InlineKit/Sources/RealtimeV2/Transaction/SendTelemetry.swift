import Foundation
import InlineProtocol
import Logger

/// One health event per finished message send. Duration runs from when the send was queued to
/// its final outcome, so it includes offline queue time and retries, as the sender experiences it.
enum SendTelemetry {
  static let eventName = "messages.send"

  enum Outcome: String {
    case sent
    case failed
    case commitUnknown = "commit_unknown"
    case canceled
  }

  static func record(_ wrapper: TransactionWrapper, _ outcome: Outcome, error: TransactionError? = nil) {
    guard wrapper.transaction.method == .sendMessage else { return }
    PerformanceTrace.healthEvent(eventName, data: data(
      outcome: outcome,
      error: error,
      durationMs: PerformanceTrace.elapsedMilliseconds(since: wrapper.date),
      retryCount: wrapper.rpcErrorRetryCount,
      carrier: RealtimeTelemetryContext.protocolName
    ))
  }

  static func data(
    outcome: Outcome, error: TransactionError?, durationMs: Int, retryCount: Int, carrier: String?
  ) -> [String: Any] {
    var data: [String: Any] = [
      "send_outcome": outcome.rawValue,
      "duration_ms": durationMs,
      "retry_count": retryCount,
    ]
    if let error {
      let errorClass = errorClass(error)
      data["error_class"] = errorClass.name
      if let code = errorClass.code { data["error_code"] = code }
    }
    if let carrier { data["carrier"] = carrier }
    return data
  }

  static func errorClass(_ error: TransactionError) -> (name: String, code: Int?) {
    switch error {
      case let .rpcError(rpc): return ("rpc", Int(rpc.code))
      case .timeout: return ("timeout", nil)
      case .invalid: return ("invalid", nil)
      case .historyUnavailable: return ("history_unavailable", nil)
      case .persistenceFailed: return ("persistence_failed", nil)
      case .commitOutcomeUnknownAfterReconnect: return ("commit_outcome_unknown", nil)
      case .rejectedBeforeExecution: return ("rejected_before_execution", nil)
      case .dependencyFailed: return ("dependency_failed", nil)
    }
  }
}
