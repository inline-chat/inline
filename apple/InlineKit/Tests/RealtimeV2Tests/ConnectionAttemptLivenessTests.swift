import AsyncAlgorithms
import Foundation
import InlineProtocol
import Logger
import Testing
@testable import RealtimeV2

/// macOS stayed on "Connecting..." until relaunch (2026-10-26): an attempt's `.connecting`
/// reached the manager only while its connect timeout was stopping it, ran after backoff began,
/// and moved the manager back to connecting with no transport and no timer. The backoff timer
/// then found the manager not in backoff, and every later lifecycle event treated it as busy.
@Suite("Connection late transport events", .serialized)
struct ConnectionLateTransportEventTests {
  @Test(
    "events that land after their attempt timed out do not cancel the retry",
    arguments: [
      [LateTransportEvent.connecting],
      [.connected],
      [.open],
      [.disconnected],
      [.connected, .open, .connecting, .disconnected],
    ]
  )
  func lateEventsAfterTimeoutStillRetry(_ lateEvents: [LateTransportEvent]) async {
    let session = ScriptedAttemptSession(lateEventsOnStop: lateEvents)
    let manager = makeManager(
      session: session,
      policy: ConnectionPolicy(
        backoff: BackoffPolicy { _ in .milliseconds(50) },
        connectTimeout: .milliseconds(200)
      )
    )
    await manager.start()

    _ = await eventually { await manager.currentSnapshot().state == .open }
    let snapshot = await manager.currentSnapshot()
    let startedSessions = await session.startedSessions
    #expect(snapshot.state == .open)
    #expect(snapshot.sessionID == 2)
    #expect(startedSessions == [1, 2])
    await manager.shutdownForTesting()
  }
}

@Suite("Connection liveness", .serialized)
struct ConnectionLivenessTests {
  @Test("a lifecycle nudge restarts an attempt that lost its deadline")
  func nudgeRestoresMissingDeadline() async {
    let sink = ErrorRecordingSink()
    Log.addSink(sink, id: "connection-liveness-nudge")
    defer { Log.removeSink(id: "connection-liveness-nudge") }

    let session = ScriptedAttemptSession()
    let manager = makeManager(
      session: session,
      policy: ConnectionPolicy(backoff: BackoffPolicy { _ in .milliseconds(50) })
    )
    await manager.start()
    #expect(await eventually { await session.startedSessions == [1] })

    await manager.dropPendingDeadlinesForTesting()
    // What a click into the Mac app sends. Before the check it found "already connecting".
    await manager.applicationBecameActive(transportWasRetained: true)

    _ = await eventually { await manager.currentSnapshot().state == .open }
    let snapshot = await manager.currentSnapshot()
    let startedSessions = await session.startedSessions
    #expect(snapshot.state == .open)
    #expect(snapshot.sessionID == 2)
    #expect(startedSessions == [1, 2])
    let repairs = sink.messages(containing: "no pending deadline")
    #expect(repairs.count == 1)
    #expect(repairs.first?.contains("state=connectingTransport missing=connect_timeout") == true)
    await manager.shutdownForTesting()
  }

  @Test("the watchdog reports the episode and repairs it without any other event")
  func watchdogRepairsWithoutEvents() async {
    let sink = ErrorRecordingSink()
    Log.addSink(sink, id: "connection-liveness-watchdog")
    defer { Log.removeSink(id: "connection-liveness-watchdog") }

    let session = ScriptedAttemptSession()
    let manager = makeManager(
      session: session,
      policy: ConnectionPolicy(
        backoff: BackoffPolicy { _ in .milliseconds(50) },
        stuckEpisodeReportDelay: .milliseconds(200)
      )
    )
    await manager.start()
    #expect(await eventually { await session.startedSessions == [1] })
    await manager.dropPendingDeadlinesForTesting()

    _ = await eventually { await manager.currentSnapshot().state == .open }
    let snapshot = await manager.currentSnapshot()
    #expect(snapshot.state == .open)
    #expect(snapshot.sessionID == 2)
    let reports = sink.messages(containing: "Realtime connection stuck")
    #expect(reports.count == 1)
    #expect(reports.first?.contains("state=connectingTransport") == true)
    #expect(reports.first?.contains("pending=none") == true)
    #expect(sink.messages(containing: "no pending deadline").count == 1)
    await manager.shutdownForTesting()
  }

  @Test("a retry loop that never connects is reported once and never trips the invariant")
  func unreachableServerReportsOnce() async {
    let sink = ErrorRecordingSink()
    Log.addSink(sink, id: "connection-liveness-unreachable")
    defer { Log.removeSink(id: "connection-liveness-unreachable") }

    let session = ScriptedAttemptSession(firstConnectingAttempt: .max)
    let manager = makeManager(
      session: session,
      policy: ConnectionPolicy(
        backoff: BackoffPolicy { _ in .milliseconds(20) },
        connectTimeout: .milliseconds(50),
        stuckEpisodeReportDelay: .milliseconds(150)
      )
    )
    await manager.start()

    #expect(await eventually { sink.messages(containing: "Realtime connection stuck").count == 1 })
    #expect(await eventually { await session.startedSessions.count >= 3 })
    // Later watchdog ticks in the same episode stay quiet.
    try? await Task.sleep(for: .milliseconds(400))
    #expect(sink.messages(containing: "Realtime connection stuck").count == 1)
    #expect(sink.messages(containing: "no pending deadline").isEmpty)
    #expect(await manager.currentSnapshot().state != .open)
    await manager.shutdownForTesting()
  }

  @Test("an attempt that opens before the report delay is never reported")
  func openingEndsTheEpisode() async {
    let sink = ErrorRecordingSink()
    Log.addSink(sink, id: "connection-liveness-open")
    defer { Log.removeSink(id: "connection-liveness-open") }

    let session = ScriptedAttemptSession(firstConnectingAttempt: 1)
    let manager = makeManager(
      session: session,
      policy: ConnectionPolicy(stuckEpisodeReportDelay: .milliseconds(100))
    )
    await manager.start()
    #expect(await eventually { await manager.currentSnapshot().state == .open })

    try? await Task.sleep(for: .milliseconds(400))
    #expect(await manager.currentSnapshot().state == .open)
    #expect(sink.messages(containing: "Realtime connection stuck").isEmpty)
    #expect(sink.messages(containing: "no pending deadline").isEmpty)
    await manager.shutdownForTesting()
  }
}

enum LateTransportEvent: Sendable {
  case connecting
  case connected
  case open
  case disconnected

  fileprivate func envelope(sessionID: UInt64) -> ProtocolSessionEventEnvelope {
    switch self {
    case .connecting: .lifecycle(.transportConnecting(sessionID: sessionID))
    case .connected: .lifecycle(.transportConnected(sessionID: sessionID))
    case .open: .lifecycle(.protocolOpen(sessionID: sessionID))
    case .disconnected: .lifecycle(.transportDisconnected(sessionID: sessionID, errorDescription: "late"))
    }
  }
}

/// Attempts before `firstConnectingAttempt` never connect, so their connect timeout stops them.
/// Stopping an attempt delivers `lateEventsOnStop` for it while the timeout handler is suspended
/// in the stop, so they queue behind that handler, as in the incident.
private actor ScriptedAttemptSession: ProtocolSessionType {
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()
  private let firstConnectingAttempt: Int
  private let lateEventsOnStop: [LateTransportEvent]
  private(set) var startedSessions: [UInt64] = []
  private var activeSessionID: UInt64?

  init(firstConnectingAttempt: Int = 2, lateEventsOnStop: [LateTransportEvent] = []) {
    self.firstConnectingAttempt = firstConnectingAttempt
    self.lateEventsOnStop = lateEventsOnStop
  }

  func startTransport(sessionID: UInt64) async {
    startedSessions.append(sessionID)
    activeSessionID = sessionID
    guard startedSessions.count >= firstConnectingAttempt else { return }
    await events.send(.lifecycle(.transportConnected(sessionID: sessionID)))
  }

  func stopTransport() async {
    guard let sessionID = activeSessionID else { return }
    activeSessionID = nil
    guard !lateEventsOnStop.isEmpty else { return }
    for event in lateEventsOnStop {
      await events.send(event.envelope(sessionID: sessionID))
    }
    // The forwarder takes this only after submitting the previous event.
    await events.send(.lifecycle(.transportConnecting(sessionID: 0)))
  }

  func startHandshake(sessionID: UInt64) async {
    await events.send(.lifecycle(.protocolOpen(sessionID: sessionID)))
  }

  func sendPing(nonce: UInt64) async {}
  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 { 0 }
  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result? { nil }
}

private final class ErrorRecordingSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  func messages(containing text: String) -> [String] {
    lock.withLock { recorded.filter { $0.contains(text) } }
  }

  func write(_ event: LogEvent) {
    guard event.entry.level == .error else { return }
    lock.withLock { recorded.append(event.entry.message) }
  }
}

private func makeManager(session: ScriptedAttemptSession, policy: ConnectionPolicy) -> ConnectionManager {
  ConnectionManager(
    session: session,
    policy: policy,
    constraints: .init(authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true),
    telemetry: ConnectionTelemetry { _ in }
  )
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}
