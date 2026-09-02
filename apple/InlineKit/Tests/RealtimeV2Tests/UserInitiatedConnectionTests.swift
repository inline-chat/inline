import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing
@testable import RealtimeV2

@Suite("User-initiated realtime activity")
struct UserInitiatedConnectionTests {
  @Test("overlapping background operations share a transport and release only after both finish")
  func overlappingOperations() async {
    let (manager, session) = fixture()
    await manager.beginUserInitiatedOperation()
    #expect(await opens(manager))
    await manager.beginUserInitiatedOperation()
    let before = await session.stops
    await manager.endUserInitiatedOperation()
    #expect(await manager.currentSnapshot().state == .open)
    #expect(await manager.currentSnapshot().constraints.appActive == false)
    #expect(await session.starts == 1)
    #expect(await session.stops == before)
    await manager.endUserInitiatedOperation()
    #expect(await manager.currentSnapshot().state == .backgroundSuspended)
    #expect(await session.stops == before + 1)
    await manager.shutdownForTesting()
  }

  @Test("foregrounding during an operation does not reconnect or stop on release")
  func foregroundTransition() async {
    let (manager, session) = fixture()
    await manager.beginUserInitiatedOperation()
    #expect(await opens(manager))
    let before = await session.stops
    await manager.applicationBecameActive(transportWasRetained: false)
    await manager.endUserInitiatedOperation()
    #expect(await manager.currentSnapshot().state == .open)
    #expect(await session.starts == 1)
    #expect(await session.stops == before)
    await manager.shutdownForTesting()
  }

  @Test("background grace expiration cannot interrupt an explicitly running operation")
  func graceExpiration() async {
    let (manager, session) = fixture()
    await manager.beginUserInitiatedOperation()
    #expect(await opens(manager))
    let before = await session.stops
    await manager.applicationBecameInactive(keepConnection: true)
    let id = await manager.currentSnapshot().sessionID
    await manager.scheduledEventDidFire(.backgroundGraceExpired, sessionID: id)
    #expect(await manager.currentSnapshot().state == .open)
    #expect(await session.stops == before)
    await manager.endUserInitiatedOperation()
    #expect(await manager.currentSnapshot().state == .backgroundSuspended)
    await manager.shutdownForTesting()
  }

  @Test("auth loss and explicit stop take precedence over an operation")
  func strongerConstraints() async {
    for loseAuth in [true, false] {
      let (manager, session) = fixture()
      await manager.beginUserInitiatedOperation()
      #expect(await opens(manager))
      if loseAuth { await manager.setAuthAvailable(false) }
      else { await manager.stop() }
      let state = await manager.currentSnapshot().state
      #expect(state != .open)
      await manager.endUserInitiatedOperation()
      #expect(await manager.currentSnapshot().state == state)
      #expect(await session.starts == 1)
      await manager.shutdownForTesting()
    }
  }

  private func fixture() -> (ConnectionManager, IntentActivitySession) {
    let session = IntentActivitySession()
    return (ConnectionManager(session: session, constraints: .init(
      authAvailable: true, networkAvailable: true, appActive: false, userWantsConnection: true
    )), session)
  }

  private func opens(_ manager: ConnectionManager) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
      if await manager.currentSnapshot().state == .open { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private actor IntentActivitySession: ProtocolSessionType {
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()
  private(set) var starts = 0
  private(set) var stops = 0
  func startTransport(sessionID: UInt64) async {
    starts += 1
    await events.send(.lifecycle(.transportConnected(sessionID: sessionID)))
  }
  func stopTransport() async { stops += 1 }
  func startHandshake(sessionID: UInt64) async {
    await events.send(.lifecycle(.protocolOpen(sessionID: sessionID)))
  }
  func sendPing(nonce: UInt64) async {}
  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 { 0 }
  func callRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?, timeout: Duration?) async throws -> RpcResult.OneOf_Result? { nil }
}
