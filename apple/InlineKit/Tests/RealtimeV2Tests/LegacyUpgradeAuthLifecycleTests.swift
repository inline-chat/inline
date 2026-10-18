import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Testing

@Suite("Legacy upgrade preserves the account lifecycle", .serialized)
struct LegacyUpgradeAuthLifecycleTests {
  @Test("verified upgrade and temporary rotation do not reconnect or retire account work")
  func upgradePreservesLiveAccount() async throws {
    let auth = Auth.mocked(authenticated: true)
    guard case let .authenticated(source) = auth.handle.snapshot().status else {
      Issue.record("Expected legacy fixture")
      return
    }
    let lease = try auth.handle.beginAccountMutation()
    let session = UpgradeLifecycleSession()
    let manager = ConnectionManager(session: session, constraints: .init(
      authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true
    ))
    let probe = AuthObservationProbe()
    let observer = AuthConnectionAdapter(auth: auth.handle, manager: manager, observationProbe: probe)
    observer.start()
    await manager.start()
    #expect(await eventually { await manager.currentSnapshot().state == .open })
    let initialStops = await session.stops
    let initialSessionID = await manager.currentSnapshot().sessionID

    let key = Array(UInt8.min...UInt8.max)
    let permanent = try InlineProtocolAuthorization(
      key: key, keyID: InlineSecureTransport.authKeyID(key), serverSalt: 7,
      temporary: false, expiresAt: nil
    )
    try await auth.handle.stageLegacyProtocolUpgrade(permanent, for: source)
    var credentials = InlineProtocolSessionCredentials(
      userId: source.userId, accountSessionId: 84, permanent: permanent,
      temporary: try temporaryKey(byte: 5)
    )
    try await auth.handle.commitLegacyProtocolUpgrade(credentials, for: source)
    let upgraded = auth.handle.snapshot()
    #expect(await eventually { probe.hasApplied(upgraded) })
    try auth.handle.validateAccountMutation(lease)
    #expect(auth.handle.token() == source.token)
    #expect(auth.handle.snapshot().status == .authenticated(source))
    #expect(await session.starts == 1)
    #expect(await session.stops == initialStops)
    #expect(await manager.currentSnapshot().state == .open)
    #expect(await manager.currentSnapshot().sessionID == initialSessionID)

    credentials.temporary = try temporaryKey(byte: 6)
    try await auth.handle.saveInlineProtocolCredentials(credentials)
    let rotated = auth.handle.snapshot()
    #expect(await eventually { probe.hasApplied(rotated) })
    try auth.handle.validateAccountMutation(lease)
    #expect(auth.handle.token() == source.token)
    #expect(await session.starts == 1)
    #expect(await session.stops == initialStops)
    #expect(await manager.currentSnapshot().sessionID == initialSessionID)

    await observer.stop()
    await manager.shutdownForTesting()
  }

  private func temporaryKey(byte: UInt8) throws -> InlineProtocolAuthorization {
    let key = [UInt8](repeating: byte, count: 256)
    return try InlineProtocolAuthorization(
      key: key, keyID: InlineSecureTransport.authKeyID(key), serverSalt: 9,
      temporary: true, expiresAt: Int32(Date().timeIntervalSince1970) + 3_600
    )
  }

  private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while !(await predicate()) {
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }
}

private actor UpgradeLifecycleSession: ProtocolSessionType {
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
  func callRpc(
    method: InlineProtocol.Method, input: RpcCall.OneOf_Input?, timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result? { nil }
}
