import Auth
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("Auth + RealtimeV2 Integration")
final class AuthRealtimeIntegrationTests {
  @Test("login event triggers connection init with token")
  func testAuthLoginStartsHandshake() async throws {
    let auth = Auth.mocked(authenticated: false)
    let transport = MockTransport()
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: apply,
      syncStorage: storage
    )

    try? await Task.sleep(for: .milliseconds(50))
    let initialMessages = await transport.sentMessages
    #expect(initialMessages.isEmpty)

    let token = "1:integrationToken"
    let userId: Int64 = 42
    await auth.saveCredentials(token: token, userId: userId)

    let didSend = await waitForCondition {
      let messages = await transport.sentMessages
      return containsConnectionInit(with: token, in: messages)
    }
    #expect(didSend)

    withExtendedLifetime(realtime) {}
  }
}

private func containsConnectionInit(with token: String, in messages: [ClientMessage]) -> Bool {
  for message in messages {
    switch message.body {
    case let .connectionInit(payload):
      if payload.token == token {
        return true
      }
    default:
      continue
    }
  }
  return false
}

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
