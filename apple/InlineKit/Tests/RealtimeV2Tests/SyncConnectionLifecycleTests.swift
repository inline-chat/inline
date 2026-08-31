import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing
@testable import RealtimeV2

@Suite("Sync connection lifecycle", .serialized)
struct SyncConnectionLifecycleTests {
  @Test("foreground and route bursts do not replace a connecting transport")
  func connectingAttemptCoalescesLifecycleHints() async {
    let (manager, session) = fixture()
    await manager.start()
    #expect(await eventually { await session.starts == 1 })
    let initial = await manager.currentSnapshot()
    let stops = await session.stops

    for _ in 0 ..< 8 {
      await manager.applicationBecameActive(transportWasRetained: false)
      await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
    }

    #expect(await manager.currentSnapshot().state == .connectingTransport)
    #expect(await manager.currentSnapshot().sessionID == initial.sessionID)
    #expect(await session.starts == 1)
    #expect(await session.stops == stops)
    await manager.shutdownForTesting()
  }

  @Test("foreground and route bursts do not restart an accepted transport handshake")
  func authenticatingAttemptCoalescesLifecycleHints() async {
    let (manager, session) = fixture()
    await manager.start()
    #expect(await eventually { await session.starts == 1 })
    await session.transportConnected()
    #expect(await eventually { await session.handshakes == 1 })
    let initial = await manager.currentSnapshot()
    let stops = await session.stops

    for _ in 0 ..< 8 {
      await manager.applicationBecameActive(transportWasRetained: false)
      await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
    }
    await session.protocolOpen()

    #expect(await eventually { await manager.currentSnapshot().state == .open })
    #expect(await manager.currentSnapshot().sessionID == initial.sessionID)
    #expect(await session.starts == 1)
    #expect(await session.handshakes == 1)
    #expect(await session.stops == stops)
    await manager.shutdownForTesting()
  }

  @Test("one route replacement owns a burst until its replacement opens")
  func routeReplacementIsSingleFlight() async {
    let (manager, session) = fixture()
    await open(manager, session: session)
    let initial = await manager.currentSnapshot()
    let stops = await session.stops

    for _ in 0 ..< 8 {
      await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
      await manager.applicationBecameActive(transportWasRetained: false)
    }

    #expect(await eventually { await session.starts == 2 })
    #expect(await manager.currentSnapshot().sessionID == initial.sessionID + 1)
    #expect(await session.stops == stops + 1)
    await manager.shutdownForTesting()
  }

  @Test("repeated wake notifications share one probe and one timeout")
  func wakeProbeIsSingleFlight() async {
    let (manager, session) = fixture(wakeTimeout: .milliseconds(500))
    await open(manager, session: session)
    let initial = await manager.currentSnapshot()
    let stops = await session.stops

    await manager.systemDidWake()
    #expect(await eventually { await session.pings == 1 })
    for _ in 0 ..< 8 {
      await manager.systemDidWake()
    }
    #expect(await session.pings == 1)
    #expect(await manager.currentSnapshot().sessionID == initial.sessionID)
    #expect(await eventually { await session.starts == 2 })
    #expect(await session.pings == 1)
    #expect(await session.stops == stops + 1)
    await manager.shutdownForTesting()
  }

  @Test("stale and canceled probe admissions cannot occupy a replacement session")
  func obsoleteProbeCannotTakeReplacementOwnership() async {
    let (manager, session) = fixture(wakeTimeout: .milliseconds(500))
    await open(manager, session: session)
    let initialID = await manager.currentSnapshot().sessionID
    await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
    #expect(await eventually { await session.starts == 2 })
    await session.transportConnected()
    #expect(await eventually { await session.handshakes == 2 })
    await session.protocolOpen()
    #expect(await eventually { await manager.currentSnapshot().state == .open })
    let replacementID = await manager.currentSnapshot().sessionID

    #expect(await manager.probeConnection(sessionID: initialID, timeout: .seconds(1)) == false)
    let canceledProbe = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await manager.probeConnection(sessionID: replacementID, timeout: .seconds(1))
    }
    #expect(await canceledProbe.value == false)
    #expect(await session.pings == 0)

    await manager.systemDidWake()
    #expect(await eventually { await session.pings == 1 })
    await session.answerPing()
    try? await Task.sleep(for: .milliseconds(600))
    #expect(await manager.currentSnapshot().state == .open)
    #expect(await manager.currentSnapshot().sessionID == replacementID)
    #expect(await session.starts == 2)
    await manager.shutdownForTesting()
  }

  private func fixture(wakeTimeout: Duration = .seconds(2)) -> (ConnectionManager, SyncLifecycleSession) {
    let session = SyncLifecycleSession()
    let manager = ConnectionManager(
      session: session,
      policy: ConnectionPolicy(pingInterval: .seconds(30), wakeProbeTimeout: wakeTimeout),
      constraints: .init(
        authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true
      )
    )
    return (manager, session)
  }

  private func open(_ manager: ConnectionManager, session: SyncLifecycleSession) async {
    await manager.start()
    #expect(await eventually { await session.starts == 1 })
    await session.transportConnected()
    #expect(await eventually { await session.handshakes == 1 })
    await session.protocolOpen()
    #expect(await eventually { await manager.currentSnapshot().state == .open })
  }

  private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while !(await condition()) {
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }
}

private actor SyncLifecycleSession: ProtocolSessionType {
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()
  private var sessionID: UInt64 = 0
  private(set) var starts = 0
  private(set) var stops = 0
  private(set) var handshakes = 0
  private(set) var pings = 0
  private var lastPingNonce: UInt64?

  func startTransport(sessionID: UInt64) async {
    self.sessionID = sessionID
    starts += 1
  }

  func stopTransport() async { stops += 1 }
  func startHandshake(sessionID: UInt64) async { handshakes += 1 }
  func sendPing(nonce: UInt64) async {
    pings += 1
    lastPingNonce = nonce
  }
  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 { 0 }
  func callRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?, timeout: Duration?) async throws -> RpcResult.OneOf_Result? { nil }

  func transportConnected() async {
    await events.send(.lifecycle(.transportConnected(sessionID: sessionID)))
  }

  func protocolOpen() async {
    await events.send(.lifecycle(.protocolOpen(sessionID: sessionID)))
  }

  func answerPing() async {
    guard let lastPingNonce else {
      Issue.record("A probe must be sent before answering it")
      return
    }
    await events.send(.account(.pong(nonce: lastPingNonce), originatingSessionID: sessionID))
  }
}
