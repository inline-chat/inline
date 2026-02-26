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
    let didHandshake = await waitForCondition(timeout: .seconds(3)) { await session.startHandshakeCount == 1 }
    #expect(didHandshake)

    await manager.shutdownForTesting()
  }

  @Test("authFailed disables auth constraint and stops reconnect attempts")
  func testAuthFailedDisablesAuthConstraintAndStopsReconnect() async throws {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    await manager.connectNow()

    session.emit(.transportConnected)
    let enteredAuthenticating = await waitForCondition(timeout: .seconds(1)) {
      let snapshot = await manager.currentSnapshot()
      return snapshot.state == .authenticating
    }
    #expect(enteredAuthenticating)

    session.emit(.authFailed)

    let transitionedToWaiting = await waitForCondition(timeout: .seconds(1)) {
      let snapshot = await manager.currentSnapshot()
      return snapshot.state == .waitingForConstraints && snapshot.constraints.authAvailable == false
    }
    #expect(transitionedToWaiting)

    try? await Task.sleep(for: .milliseconds(800))
    #expect(await session.startTransportCount == 1)

    await manager.shutdownForTesting()
  }

  @Test("authFailed recovers when auth becomes available again")
  func testAuthFailedRecoversWhenAuthBecomesAvailableAgain() async throws {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    await manager.connectNow()

    session.emit(.transportConnected)
    let firstHandshake = await waitForCondition(timeout: .seconds(1)) {
      await session.startHandshakeCount == 1
    }
    #expect(firstHandshake)

    session.emit(.authFailed)
    let pausedForMissingAuth = await waitForCondition(timeout: .seconds(1)) {
      let snapshot = await manager.currentSnapshot()
      return snapshot.state == .waitingForConstraints && snapshot.constraints.authAvailable == false
    }
    #expect(pausedForMissingAuth)

    // Simulate later token recovery (e.g. re-login / fresh app start with valid credentials).
    await manager.setAuthAvailable(true)
    let restartedTransport = await waitForCondition(timeout: .seconds(1)) {
      await session.startTransportCount == 2
    }
    #expect(restartedTransport)

    session.emit(.transportConnected)
    let secondHandshake = await waitForCondition(timeout: .seconds(1)) {
      await session.startHandshakeCount == 2
    }
    #expect(secondHandshake)

    await manager.shutdownForTesting()
  }

  @Test("default policy uses fast ping cadence")
  func testDefaultPolicyPingCadence() {
    let policy = ConnectionPolicy()
    #expect(policy.pingInterval == .seconds(5))
    #expect(policy.pingTimeoutGood == .seconds(6))
    #expect(policy.pingTimeoutConstrained == .seconds(12))
  }

  @Test("missing pong transitions to backoff with ping timeout reason")
  func testPingTimeoutTransitionsToBackoff() async throws {
    let session = FakeProtocolSession()
    let policy = ConnectionPolicy(
      backoff: BackoffPolicy { _ in .seconds(5) },
      authTimeout: .seconds(1),
      connectTimeout: .seconds(1),
      pingInterval: .milliseconds(20),
      pingTimeoutGood: .milliseconds(30),
      pingTimeoutConstrained: .milliseconds(30),
      backgroundGrace: .seconds(30),
      wakeProbeTimeout: .seconds(1)
    )
    let manager = ConnectionManager(session: session, policy: policy, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    await manager.connectNow()

    session.emit(.transportConnected)
    session.emit(.protocolOpen)

    let sentPing = await waitForCondition(timeout: .seconds(1)) {
      await session.sentPingCount > 0
    }
    #expect(sentPing)

    let transitionedToBackoff = await waitForCondition(timeout: .seconds(1)) {
      let snapshot = await manager.currentSnapshot()
      return snapshot.state == .backoff && snapshot.reason == .pingTimeout
    }
    #expect(transitionedToBackoff)

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
  private(set) var sentPingCount: Int = 0

  func startTransport() async {
    startTransportCount += 1
  }

  func stopTransport() async {
    stopTransportCount += 1
  }

  func startHandshake() async {
    startHandshakeCount += 1
  }

  func sendPing(nonce: UInt64) async {
    sentPingCount += 1
  }

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
