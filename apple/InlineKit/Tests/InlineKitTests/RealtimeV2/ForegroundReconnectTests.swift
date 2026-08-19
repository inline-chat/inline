import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("RealtimeV2.ConnectionManager", .serialized)
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

    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()
    let didHandshake = await waitForCondition(timeout: .seconds(3)) { await session.startHandshakeCount == 1 }
    #expect(didHandshake)

    await manager.shutdownForTesting()
  }

  @Test("protocol open is consumed while handshake work is suspended")
  func testProtocolOpenIsConsumedWhileHandshakeWorkIsSuspended() async {
    let session = FakeProtocolSession(suspendHandshake: true)
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()

    let handshakeStarted = await waitForCondition {
      await session.startHandshakeCount == 1
    }
    #expect(handshakeStarted)

    await session.emitProtocolOpen()
    let opened = await waitForCondition {
      await manager.currentSnapshot().state == .open
    }
    #expect(opened)

    await manager.shutdownForTesting()
  }

  @Test("stale protocol open cannot authenticate a newer reconnect generation")
  func staleProtocolOpenCannotAuthenticateNewerGeneration() async {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()

    let firstHandshakeStarted = await waitForCondition {
      await session.handshakeSessionIDs.count == 1
    }
    #expect(firstHandshakeStarted)
    let firstSessionID = await session.handshakeSessionIDs[0]

    await session.emitTransportDisconnected(errorDescription: "test_disconnect")
    let enteredBackoff = await waitForCondition {
      await manager.currentSnapshot().state == .backoff
    }
    #expect(enteredBackoff)

    await manager.connectNow()
    #expect(await waitForCondition { await session.startTransportCount == 2 })
    await session.emitTransportConnected()
    let secondHandshakeStarted = await waitForCondition {
      await session.handshakeSessionIDs.count == 2
    }
    #expect(secondHandshakeStarted)
    let secondSessionID = await session.handshakeSessionIDs[1]
    #expect(secondSessionID != firstSessionID)

    await session.emitProtocolOpen(sessionID: firstSessionID)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await manager.currentSnapshot().state == .authenticating)

    await session.emitProtocolOpen(sessionID: secondSessionID)
    let opened = await waitForCondition {
      await manager.currentSnapshot().state == .open
    }
    #expect(opened)

    await manager.shutdownForTesting()
  }

  @Test("stale transport lifecycle cannot mutate a newer reconnect generation")
  func staleTransportLifecycleCannotMutateNewerGeneration() async {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    #expect(await waitForCondition { await session.startTransportSessionIDs.count == 1 })
    let firstSessionID = await session.startTransportSessionIDs[0]

    await session.emitTransportConnected(sessionID: firstSessionID)
    #expect(await waitForCondition { await session.startHandshakeCount == 1 })
    await session.emitTransportDisconnected(
      sessionID: firstSessionID,
      errorDescription: "test_disconnect"
    )
    #expect(await waitForCondition { await manager.currentSnapshot().state == .backoff })

    await manager.connectNow()
    #expect(await waitForCondition { await session.startTransportSessionIDs.count == 2 })
    let secondSessionID = await session.startTransportSessionIDs[1]
    #expect(secondSessionID != firstSessionID)

    await session.emitTransportConnected(sessionID: firstSessionID)
    await session.emitTransportDisconnected(
      sessionID: firstSessionID,
      errorDescription: "stale_disconnect"
    )
    try? await Task.sleep(for: .milliseconds(30))
    #expect(await manager.currentSnapshot().state == .connectingTransport)
    #expect(await session.startHandshakeCount == 1)

    await session.emitTransportConnected(sessionID: secondSessionID)
    #expect(await waitForCondition { await session.startHandshakeCount == 2 })

    await manager.shutdownForTesting()
  }

  @Test("authFailed disables auth constraint and stops reconnect attempts")
  func testAuthFailedDisablesAuthConstraintAndStopsReconnect() async throws {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)
    let sessionEventDrain = Task {
      for await _ in await manager.sessionEvents() {}
    }
    defer { sessionEventDrain.cancel() }

    await manager.start()
    await manager.setAuthAvailable(true)
    await manager.connectNow()

    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()
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
    let sessionEventDrain = Task {
      for await _ in await manager.sessionEvents() {}
    }
    defer { sessionEventDrain.cancel() }

    await manager.start()
    await manager.setAuthAvailable(true)
    await manager.connectNow()

    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()
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

    await session.emitTransportConnected()
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

  @Test("session forwarding teardown releases an unbuffered account event")
  func sessionForwardingTeardownDoesNotStrandProducer() async {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)
    await manager.start()

    var updates = InlineProtocol.UpdatesPayload()
    updates.updates = []
    let envelope = ProtocolSessionEventEnvelope.account(.updates(updates: updates))
    await session.events.send(envelope)

    let finished = ForwardingFinishFlag()
    let teardown = Task {
      await manager.finishSessionEventForwarding()
      await finished.set()
    }
    let didFinish = await waitForCondition(timeout: .seconds(1)) {
      await finished.get()
    }
    #expect(didFinish)
    teardown.cancel()
  }

  @Test("connect timeout interrupts suspended transport startup")
  func testConnectTimeoutInterruptsSuspendedTransportStartup() async {
    let session = FakeProtocolSession(suspendTransportStart: true)
    let policy = ConnectionPolicy(
      backoff: BackoffPolicy { _ in .seconds(5) },
      authTimeout: .seconds(1),
      connectTimeout: .milliseconds(30),
      pingInterval: .seconds(1),
      pingTimeoutGood: .seconds(1),
      pingTimeoutConstrained: .seconds(1),
      backgroundGrace: .seconds(30),
      wakeProbeTimeout: .seconds(1)
    )
    let manager = ConnectionManager(session: session, policy: policy, constraints: .initial)

    await manager.start()
    let stopCountBeforeTimeout = await session.stopTransportCount
    let connectTask = Task { await manager.setAuthAvailable(true) }

    let timedOut = await waitForCondition(timeout: .seconds(1)) {
      let snapshot = await manager.currentSnapshot()
      return snapshot.state == .backoff &&
        snapshot.reason == .transportDisconnected &&
        snapshot.lastErrorDescription == "connect_timeout"
    }
    #expect(timedOut)
    let stopCount = await session.stopTransportCount
    #expect(stopCount == stopCountBeforeTimeout + 1)

    connectTask.cancel()
    await manager.shutdownForTesting()
  }

  @Test("stop interrupts suspended transport startup before the connect timeout")
  func stopInterruptsSuspendedTransportStartup() async {
    let session = FakeProtocolSession(suspendTransportStart: true)
    let policy = ConnectionPolicy(
      backoff: BackoffPolicy { _ in .seconds(5) },
      authTimeout: .seconds(1),
      connectTimeout: .milliseconds(500),
      pingInterval: .seconds(1),
      pingTimeoutGood: .seconds(1),
      pingTimeoutConstrained: .seconds(1),
      backgroundGrace: .seconds(30),
      wakeProbeTimeout: .seconds(1)
    )
    let manager = ConnectionManager(session: session, policy: policy, constraints: .initial)

    await manager.start()
    let connectTask = Task { await manager.setAuthAvailable(true) }
    #expect(await waitForCondition { await session.startTransportCount == 1 })
    let stopCountBeforeStop = await session.stopTransportCount

    let stopTask = Task { await manager.stop() }
    let stoppedBeforeConnectTimeout = await waitForCondition(timeout: .milliseconds(150)) {
      let snapshot = await manager.currentSnapshot()
      let stopTransportCount = await session.stopTransportCount
      return snapshot.state == .stopped && stopTransportCount == stopCountBeforeStop + 1
    }
    #expect(stoppedBeforeConnectTimeout)

    await stopTask.value
    await connectTask.value
    #expect(await manager.currentSnapshot().reason == .userStop)

    await manager.shutdownForTesting()
  }

  @Test("stop interrupts an in-flight wake probe")
  func stopInterruptsInFlightWakeProbe() async {
    let session = FakeProtocolSession(suspendPing: true)
    let policy = ConnectionPolicy(
      backoff: BackoffPolicy { _ in .seconds(5) },
      authTimeout: .seconds(1),
      connectTimeout: .seconds(1),
      pingInterval: .seconds(30),
      pingTimeoutGood: .seconds(1),
      pingTimeoutConstrained: .seconds(1),
      backgroundGrace: .seconds(30),
      wakeProbeTimeout: .seconds(5)
    )
    let manager = ConnectionManager(session: session, policy: policy, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()
    #expect(await waitForCondition { await session.startHandshakeCount == 1 })
    await session.emitProtocolOpen()
    #expect(await waitForCondition { await manager.currentSnapshot().state == .open })

    let wakeTask = Task { await manager.systemDidWake() }
    #expect(await waitForCondition { await session.sentPingCount == 1 })

    let stopTask = Task { await manager.stop() }
    let stoppedWithoutWaitingForProbe = await waitForCondition(timeout: .milliseconds(150)) {
      await manager.currentSnapshot().state == .stopped
    }
    #expect(stoppedWithoutWaitingForProbe)

    await stopTask.value
    await wakeTask.value
    await manager.shutdownForTesting()
  }

  @Test("stop is an ordered transport barrier")
  func testStopWaitsForTransportShutdown() async {
    let session = FakeProtocolSession()
    let manager = ConnectionManager(session: session, constraints: .initial)

    await manager.start()
    await manager.setAuthAvailable(true)
    let stopCountBeforeBarrier = await session.stopTransportCount

    await manager.stop()

    let snapshot = await manager.currentSnapshot()
    #expect(snapshot.state == .stopped)
    #expect(snapshot.constraints.userWantsConnection == false)
    #expect(await session.stopTransportCount == stopCountBeforeBarrier + 1)

    await manager.shutdownForTesting()
  }

  @Test("missing pong transitions to backoff with ping timeout reason")
  func testPingTimeoutTransitionsToBackoff() async throws {
    let session = FakeProtocolSession(stopEmitsDisconnect: true)
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

    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()
    #expect(await waitForCondition { await session.startHandshakeCount == 1 })
    await session.emitProtocolOpen()

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

  @Test("ping timeout bounds a suspended protocol ping")
  func testPingTimeoutBoundsSuspendedProtocolPing() async {
    let session = FakeProtocolSession(suspendPing: true)
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
    #expect(await waitForCondition { await session.startTransportCount == 1 })
    await session.emitTransportConnected()
    #expect(await waitForCondition { await session.startHandshakeCount == 1 })
    await session.emitProtocolOpen()

    let timedOut = await waitForCondition(timeout: .seconds(1)) {
      let snapshot = await manager.currentSnapshot()
      return snapshot.state == .backoff && snapshot.reason == .pingTimeout
    }
    #expect(timedOut)

    await manager.shutdownForTesting()
  }
}

private actor ForwardingFinishFlag {
  private var value = false

  func set() {
    value = true
  }

  func get() -> Bool {
    value
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
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()

  private let suspendTransportStart: Bool
  private let suspendHandshake: Bool
  private let suspendPing: Bool
  private let stopEmitsDisconnect: Bool

  private(set) var startTransportCount: Int = 0
  private(set) var startTransportSessionIDs: [UInt64] = []
  private(set) var stopTransportCount: Int = 0
  private(set) var startHandshakeCount: Int = 0
  private(set) var handshakeSessionIDs: [UInt64] = []
  private(set) var sentPingCount: Int = 0

  init(
    suspendTransportStart: Bool = false,
    suspendHandshake: Bool = false,
    suspendPing: Bool = false,
    stopEmitsDisconnect: Bool = false
  ) {
    self.suspendTransportStart = suspendTransportStart
    self.suspendHandshake = suspendHandshake
    self.suspendPing = suspendPing
    self.stopEmitsDisconnect = stopEmitsDisconnect
  }

  func startTransport(sessionID: UInt64) async {
    startTransportCount += 1
    startTransportSessionIDs.append(sessionID)
    if suspendTransportStart {
      try? await Task.sleep(for: .seconds(30))
    }
  }

  func stopTransport() async {
    stopTransportCount += 1
    if stopEmitsDisconnect {
      guard let sessionID = startTransportSessionIDs.last else { return }
      await events.send(.lifecycle(.transportDisconnected(
        sessionID: sessionID,
        errorDescription: "stopped"
      )))
    }
  }

  func startHandshake(sessionID: UInt64) async {
    startHandshakeCount += 1
    handshakeSessionIDs.append(sessionID)
    if suspendHandshake {
      try? await Task.sleep(for: .seconds(30))
    }
  }

  func sendPing(nonce: UInt64) async {
    sentPingCount += 1
    if suspendPing {
      try? await Task.sleep(for: .seconds(30))
    }
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
      await events.send(.lifecycle(event))
    }
  }

  func emitProtocolOpen() async {
    guard let sessionID = handshakeSessionIDs.last else {
      Issue.record("Cannot emit protocol open before a handshake starts")
      return
    }
    await emitProtocolOpen(sessionID: sessionID)
  }

  func emitProtocolOpen(sessionID: UInt64) async {
    await events.send(.lifecycle(.protocolOpen(sessionID: sessionID)))
  }

  func emitTransportConnected(sessionID: UInt64? = nil) async {
    guard let sessionID = sessionID ?? startTransportSessionIDs.last else {
      Issue.record("Cannot emit transport connected before transport startup")
      return
    }
    await events.send(.lifecycle(.transportConnected(sessionID: sessionID)))
  }

  func emitTransportDisconnected(
    sessionID: UInt64? = nil,
    errorDescription: String?
  ) async {
    guard let sessionID = sessionID ?? startTransportSessionIDs.last else {
      Issue.record("Cannot emit transport disconnected before transport startup")
      return
    }
    await events.send(.lifecycle(.transportDisconnected(
      sessionID: sessionID,
      errorDescription: errorDescription
    )))
  }
}
