import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("RealtimeV2.ConnectionManager")
final class ConnectionManagerTests {
  @Test("login triggers immediate transport start")
  func testLoginTriggersImmediateTransportStart() async throws {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    await manager.connectNow()

    let didStart = await waitForCondition { await session.startTransportCount == 1 }
    #expect(didStart)

    await manager.shutdownForTesting()
  }

  @Test("transport connected triggers handshake")
  func testTransportConnectedTriggersHandshake() async throws {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    await manager.connectNow()

    session.emit(.transportConnected)
    let didHandshake = await waitForCondition { await session.startHandshakeCount == 1 }
    #expect(didHandshake)

    await manager.shutdownForTesting()
  }
}

// MARK: - Test Helpers

private func waitForCondition(
  timeout: Duration = .seconds(1),
  pollInterval: Duration = .milliseconds(10),
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while await condition() == false {
    if clock.now >= deadline {
      return false
    }
    try? await clock.sleep(for: pollInterval)
  }

  return true
}

actor FakeProtocolSession: ProtocolSessionType {
  nonisolated let events = AsyncChannel<ProtocolSessionEvent>()

  private(set) var startTransportCount: Int = 0
  private(set) var stopTransportCount: Int = 0
  private(set) var startHandshakeCount: Int = 0

  func startTransport() async {
    startTransportCount += 1
  }

  func stopTransport() async {
    stopTransportCount += 1
  }

  func startHandshake() async {
    startHandshakeCount += 1
  }

  func sendPing(nonce: UInt64) async {}

  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 {
    0
  }

  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    nil
  }

  nonisolated func emit(_ event: ProtocolSessionEvent) {
    Task {
      await events.send(event)
    }
  }
}
