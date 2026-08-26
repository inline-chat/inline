import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("Transaction failure telemetry")
struct TransactionFailureTelemetryTests {
  @Test("method scope is static and bounded")
  func methodScopeIsStaticAndBounded() {
    #expect(
      transactionFailureLogScope(method: .sendMessage)
        == "RealtimeV2.Transaction.sendMessage"
    )
    #expect(
      transactionFailureLogScope(method: .UNRECOGNIZED(999))
        == "RealtimeV2.Transaction.method_999"
    )
  }

  @Test("error categories omit RPC messages and request identity")
  func errorCategoriesArePrivacySafe() {
    var rpcError = InlineProtocol.RpcError()
    rpcError.reqMsgID = 9_876_543
    rpcError.errorCode = .unknown
    rpcError.code = 401
    rpcError.message = "private-message-sentinel"

    let category = TransactionError.rpcError(rpcError).privacySafeErrorCategory
    #expect(category == "transaction:rpc:0:401")
    #expect(!category.contains("private-message-sentinel"))
    #expect(!category.contains("9876543"))
    #expect(TransactionError.timeout.privacySafeErrorCategory == "transaction:timeout")
    #expect(
      TransactionError.persistenceFailed.privacySafeErrorCategory
        == "transaction:persistence_failed"
    )
  }
}
