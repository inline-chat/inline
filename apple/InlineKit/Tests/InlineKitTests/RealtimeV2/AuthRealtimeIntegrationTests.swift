import Auth
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2
@testable import InlineKit

@Suite("Auth + RealtimeV2 Integration", .serialized)
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

    let token = "42:integrationToken"
    let userId: Int64 = 42
    try await auth.saveCredentials(token: token, userId: userId)

    let didSend = await waitForCondition {
      let messages = await transport.sentMessages
      return containsConnectionInit(with: token, in: messages)
    }
    #expect(didSend)

    withExtendedLifetime(realtime) {}
  }

  @Test("logout followed by login starts a new authenticated handshake")
  func testAuthReloginStartsNewHandshake() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: RecordingApplyUpdates(),
      syncStorage: InMemorySyncStorage()
    )

    let initialHandshake = await waitForCondition {
      let messages = await transport.sentMessages
      return containsConnectionInit(with: "1:mockToken", in: messages)
    }
    #expect(initialHandshake)

    let fence = try auth.beginLogoutSynchronously()
    await auth.publishLogoutInProgress()
    // This suite owns only the auth-snapshot/realtime handshake boundary. Persistent database
    // cleanup is covered separately; using the process-global test fallback here would now (and
    // correctly) fail the production logout proof because it is not an on-disk DatabasePool.
    let databaseProof = AuthDatabaseCleanupProof(fence: fence)
    guard let credentialProof = await auth.destroyCredentialsForPendingLogout(fence: fence) else {
      Issue.record("Expected credential destruction proof")
      return
    }
    #expect(await LogoutCompletionCoordinator.complete(
      fence: fence,
      databaseProof: databaseProof,
      credentialProof: credentialProof,
      completionPermit: AuthLogoutCompletionPermit(fence: fence),
      auth: auth
    ))
    try await auth.saveCredentials(token: "2:reloginToken", userId: 2)

    let reloginHandshake = await waitForCondition {
      let messages = await transport.sentMessages
      return containsConnectionInit(with: "2:reloginToken", in: messages)
    }
    #expect(reloginHandshake)

    withExtendedLifetime(realtime) {}
  }

  @Test("replacing an authenticated token starts a new handshake")
  func testAuthenticatedTokenReplacementStartsNewHandshake() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = MockTransport()
    let realtime = RealtimeV2(
      transport: transport,
      auth: auth.handle,
      applyUpdates: RecordingApplyUpdates(),
      syncStorage: InMemorySyncStorage()
    )

    let initialHandshake = await waitForCondition {
      let messages = await transport.sentMessages
      return containsConnectionInit(with: "1:mockToken", in: messages)
    }
    #expect(initialHandshake)

    try await auth.saveCredentials(token: "2:replacementToken", userId: 2)

    let replacementHandshake = await waitForCondition {
      let messages = await transport.sentMessages
      return containsConnectionInit(with: "2:replacementToken", in: messages)
    }
    #expect(replacementHandshake)

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
  timeout: Duration = .seconds(3),
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
