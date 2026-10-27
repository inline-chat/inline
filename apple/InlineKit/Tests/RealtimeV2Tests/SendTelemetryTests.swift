import Foundation
import InlineProtocol
@testable import Logger
@testable import RealtimeV2
import Testing

@Suite("Message send telemetry")
struct SendTelemetryTests {
  @Test("failed sends keep the error class and RPC status through the privacy projection")
  func failedSendSurvivesProjection() throws {
    let rpc = InlineProtocol.RpcError.with {
      $0.errorCode = .rateLimit
      $0.code = 429
      $0.message = "raw server text"
    }
    let data = SendTelemetry.data(
      outcome: .failed, error: .rpcError(rpc), durationMs: 1_250, retryCount: 2, carrier: "v3"
    )
    let projected = PerformanceTrace.privacySafeBreadcrumbProjection(
      message: SendTelemetry.eventName, category: SendTelemetry.eventName, data: data
    ).data

    #expect(projected["send_outcome"] as? String == "failed")
    #expect(projected["error_class"] as? String == "rpc")
    #expect(try #require(projected["error_code"] as? Double) == 429)
    #expect(try #require(projected["retry_count"] as? Double) == 2)
    #expect(try #require(projected["duration_ms"] as? Double) == 1_250)
    #expect(projected["carrier"] as? String == "v3")
    #expect(projected.count == data.count)
  }

  @Test("every outcome and transaction error is on the allow-list")
  func vocabularyIsAllowed() {
    for outcome in [SendTelemetry.Outcome.sent, .failed, .commitUnknown, .canceled] {
      #expect(PerformanceTrace.isAllowedEnumValue(outcome.rawValue, for: "send_outcome"))
    }
    let errors: [TransactionError] = [
      .rpcError(InlineProtocol.RpcError()), .timeout, .invalid, .historyUnavailable(.admission),
      .persistenceFailed, .commitOutcomeUnknownAfterReconnect, .rejectedBeforeExecution, .dependencyFailed,
    ]
    for error in errors {
      #expect(PerformanceTrace.isAllowedEnumValue(SendTelemetry.errorClass(error).name, for: "error_class"))
    }
  }

  @Test("successful sends carry no error fields")
  func sentOmitsError() {
    let data = SendTelemetry.data(outcome: .sent, error: nil, durationMs: 80, retryCount: 0, carrier: nil)
    #expect(data["send_outcome"] as? String == "sent")
    #expect(data["error_class"] == nil)
    #expect(data["error_code"] == nil)
    #expect(data["carrier"] == nil)
  }
}
