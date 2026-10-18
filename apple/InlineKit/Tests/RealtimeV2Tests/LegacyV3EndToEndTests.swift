import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Testing

/// Opt-in: runs the real client stack against a local server. Use scripts/e2e/legacy-v3-upgrade.sh.
@Suite(
  "Legacy V3 upgrade end to end",
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["INLINE_E2E_FIXTURE"] != nil)
)
struct LegacyV3EndToEndTests {
  private struct Fixture: Decodable {
    let userId: Int64
    let sessionId: Int64
    let token: String
  }

  @Test("legacy bearer session upgrades in the background, reconnects over V3 and follows the operator preference")
  func upgradeReconnectAndRollback() async throws {
    let environment = ProcessInfo.processInfo.environment
    let fixturePath = try #require(environment["INLINE_E2E_FIXTURE"])
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
    let serverDirectory = try #require(environment["INLINE_E2E_SERVER_DIR"])

    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: fixture.token, userId: fixture.userId)
    let preference = E2EPreferenceBox()
    let transport = NegotiatingRealtimeTransport(
      auth: auth.handle,
      automaticallyUpgradeLegacySession: true,
      transportPreference: preference.store
    )
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    let manager = ConnectionManager(session: session, constraints: .init(
      authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true
    ))
    let consumer = Task {
      for await envelope in await manager.sessionEvents() {
        await envelope.markProcessed()
      }
    }
    await session.start()
    await manager.start()

    // 1. The legacy session opens over V2 with its bearer.
    #expect(await eventually(.seconds(15)) { await isOpen(manager, protocol: "v2") })

    // 2. Background preparation binds V3 to the same server session and keeps the bearer.
    #expect(await eventually(.seconds(30)) { auth.handle.snapshot().inlineProtocol != nil })
    let credentials = try #require(auth.handle.snapshot().inlineProtocol)
    #expect(credentials.userId == fixture.userId)
    #expect(credentials.accountSessionId == fixture.sessionId)
    #expect(auth.handle.token() == fixture.token)
    guard case let .authenticated(bearer) = auth.handle.snapshot().status else {
      Issue.record("Upgrade replaced the bearer account authority")
      return
    }
    #expect(bearer.userId == fixture.userId && bearer.token == fixture.token)

    // 3. The next natural reconnect selects V3, and application RPCs work on it.
    let v2SessionID = await manager.currentSnapshot().sessionID
    await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
    #expect(await eventually(.seconds(15)) {
      let replaced = await manager.currentSnapshot().sessionID != v2SessionID
      let open = await isOpen(manager, protocol: "v3")
      return replaced && open
    })
    let me = try await session.callRpc(method: .getMe, input: .getMe(.init()), timeout: .seconds(10))
    guard case let .getMe(result) = me else {
      Issue.record("getMe over V3 returned \(String(describing: me))")
      return
    }
    #expect(result.user.id == fixture.userId)

    // 4. Operator rollback: the V3 open reports the V2 preference and the session moves to V2.
    try runServerScript(serverDirectory, "transport", "v2", fixturePath)
    try await Task.sleep(for: .seconds(6))
    // Connection opens never wait on configuration storage, so the open that refreshes a stale
    // snapshot may still report the previous value; a following reconnect sees the new one.
    #expect(await reconnectUntil(manager) { preference.prefersLegacy })
    #expect(await eventually(.seconds(25)) { await isOpen(manager, protocol: "v2") })
    // A further reconnect stays on V2 while the rollback is active.
    await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
    try await Task.sleep(for: .seconds(2))
    #expect(await eventually(.seconds(15)) { await isOpen(manager, protocol: "v2") })

    // 5. Restoring V3: a V2 open clears the preference, and the next reconnect returns to V3.
    try runServerScript(serverDirectory, "transport", "v3", fixturePath)
    try await Task.sleep(for: .seconds(6))
    #expect(await reconnectUntil(manager) { !preference.prefersLegacy })
    await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
    #expect(await eventually(.seconds(15)) { await isOpen(manager, protocol: "v3") })

    await manager.stop()
    await manager.shutdownForTesting()
    consumer.cancel()

    // 6. Server-side invariants: one session, original bearer, key bound to that session.
    let inspection = try runServerScript(serverDirectory, "inspect", fixturePath)
    let report = try JSONDecoder().decode(ServerInspection.self, from: Data(inspection.utf8))
    #expect(report.sessions == 1)
    #expect(report.originalSessionKept)
    #expect(report.bearerUnchanged)
    #expect(report.keysOnOriginalSession >= 1)
  }

  @Test("disabled upgrade mode keeps a legacy session on V2 and binds nothing")
  func disabledUpgradeModeKeepsLegacy() async throws {
    let environment = ProcessInfo.processInfo.environment
    let serverDirectory = try #require(environment["INLINE_E2E_SERVER_DIR"])
    let fixturePath = try #require(environment["INLINE_E2E_DISABLED_FIXTURE"])
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
    try runServerScript(serverDirectory, "upgrade-mode", "disabled", fixturePath)
    try await Task.sleep(for: .seconds(6))

    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: fixture.token, userId: fixture.userId)
    let transport = NegotiatingRealtimeTransport(
      auth: auth.handle,
      automaticallyUpgradeLegacySession: true,
      transportPreference: E2EPreferenceBox().store
    )
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    let manager = ConnectionManager(session: session, constraints: .init(
      authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true
    ))
    let consumer = Task {
      for await envelope in await manager.sessionEvents() {
        await envelope.markProcessed()
      }
    }
    await session.start()
    await manager.start()
    #expect(await eventually(.seconds(15)) { await isOpen(manager, protocol: "v2") })
    // Give the background attempt time to finish; a declined attempt must not bind or log out.
    try await Task.sleep(for: .seconds(8))
    #expect(auth.handle.snapshot().inlineProtocol == nil)
    #expect(auth.handle.token() == fixture.token)
    #expect(await isOpen(manager, protocol: "v2"))

    await manager.stop()
    await manager.shutdownForTesting()
    consumer.cancel()
    try runServerScript(serverDirectory, "upgrade-mode", "native", fixturePath)

    let inspection = try runServerScript(serverDirectory, "inspect", fixturePath)
    let report = try JSONDecoder().decode(ServerInspection.self, from: Data(inspection.utf8))
    #expect(report.sessions == 1)
    #expect(report.originalSessionKept)
    #expect(report.bearerUnchanged)
    #expect(report.boundKeys == 0)
  }

  private struct ServerInspection: Decodable {
    let sessions: Int
    let originalSessionKept: Bool
    let bearerUnchanged: Bool
    let boundKeys: Int
    let keysOnOriginalSession: Int
  }
}

private func isOpen(_ manager: ConnectionManager, protocol name: String) async -> Bool {
  let state = await manager.currentSnapshot().state
  return state == .open && RealtimeTelemetryContext.protocolName == name
}

private func reconnectUntil(
  _ manager: ConnectionManager,
  attempts: Int = 3,
  _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
  for _ in 0..<attempts {
    await manager.networkPathChanged(isAvailable: true, routeChanged: true, quality: .good)
    if await eventually(.seconds(10), predicate) { return true }
  }
  return false
}

private func eventually(
  _ timeout: Duration,
  _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while !(await predicate()) {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: .milliseconds(50))
  }
  return true
}

@discardableResult
private func runServerScript(_ serverDirectory: String, _ arguments: String...) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["bun", "scripts/e2e/legacy-v3-upgrade.ts"] + arguments
  process.currentDirectoryURL = URL(fileURLWithPath: serverDirectory)
  let output = Pipe()
  process.standardOutput = output
  try process.run()
  process.waitUntilExit()
  let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  guard process.terminationStatus == 0 else {
    throw E2EScriptError(status: process.terminationStatus)
  }
  return text.split(separator: "\n").last.map(String.init) ?? ""
}

private struct E2EScriptError: Error { let status: Int32 }

private final class E2EPreferenceBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var prefersLegacy: Bool { lock.withLock { value } }
  var store: UpgradedSessionTransportPreference {
    .init(prefersLegacy: { [self] in prefersLegacy }, record: { [self] next in lock.withLock { value = next } })
  }
}
