import AsyncAlgorithms
@testable import Auth
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("RealtimeV2.ForegroundReconnect")
final class ForegroundReconnectTests {
  @Test("foreground transition is coalesced")
  func testForegroundTransitionCoalesces() async throws {
    let transport = CountingTransport()
    let auth = Auth(mockAuthenticated: true)
    let client = ProtocolClient(transport: transport, auth: auth)

    async let first: Void = client.handleForegroundTransition()
    async let second: Void = client.handleForegroundTransition()
    async let third: Void = client.handleForegroundTransition()

    _ = await (first, second, third)

    let calls = await transport.getForegroundCallCount()
    #expect(calls == 1)
  }
}

// MARK: - Test Transport

actor CountingTransport: Transport {
  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  func start() async {}

  func stop() async {}

  func send(_ message: ClientMessage) async throws {}

  func stopConnection() async {}

  func reconnect(skipDelay: Bool) async {}

  func handleForegroundTransition() async {
    foregroundCallCount += 1
  }

  func getForegroundCallCount() -> Int {
    foregroundCallCount
  }

  private var foregroundCallCount = 0
  private let channel = AsyncChannel<TransportEvent>()
}
