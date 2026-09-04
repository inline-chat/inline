@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Create chat failure telemetry")
struct CreateChatFailureTelemetryTests {
  @Test("category records only request shape and protocol failure")
  func categoryRecordsOnlySafeShape() throws {
    var rpcError = InlineProtocol.RpcError()
    rpcError.reqMsgID = 9_876_543
    rpcError.errorCode = .badRequest
    rpcError.code = 400
    rpcError.message = "private-message-sentinel"
    let agentContext = InlineProtocol.AgentThreadContext.with {
      $0.botUserID = 42
      $0.configuration.reasoningEffortID = "private-reasoning-sentinel"
    }
    let context = try CreateChatTransaction.Context(
      title: nil,
      placeholderTitle: "private-title-sentinel",
      emoji: nil,
      isPublic: false,
      spaceId: nil,
      participants: [42],
      reservedChatId: 123,
      agentContext: agentContext.serializedData()
    )

    let category = CreateChatFailureTelemetryError(
      error: .rpcError(rpcError),
      context: context
    ).privacySafeErrorCategory

    #expect(category == "create_chat:transaction:rpc:1:400:r1:a1:i0:c1:cp0:cm0:cr1:s0:p0")
    #expect(!category.contains("private-message-sentinel"))
    #expect(!category.contains("private-title-sentinel"))
    #expect(!category.contains("9876543"))
    #expect(!category.contains("private-reasoning-sentinel"))
  }
}
