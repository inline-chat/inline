import AsyncAlgorithms
import Foundation
import InlineProtocol
import Logger
import Testing
@testable import RealtimeV2

@Suite("Connection command stall report", .serialized)
struct ConnectionCommandStallTests {
  /// A transport stop that never returned left the macOS owner on "Connecting..." with nothing
  /// in the logs (2026-10-19): every later command waited behind it and the slow-handler warning
  /// only logs after a handler returns.
  @Test("a command blocked in transport stop is reported while it is still running")
  func blockedStopIsReported() async {
    let sink = StallRecordingSink()
    Log.addSink(sink, id: "connection-command-stall-tests")
    defer { Log.removeSink(id: "connection-command-stall-tests") }

    let session = BlockingStopSession()
    let manager = ConnectionManager(
      session: session,
      policy: ConnectionPolicy(stalledCommandReportDelay: .milliseconds(100)),
      constraints: .init(authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true),
      telemetry: ConnectionTelemetry { _ in }
    )
    await manager.start()
    #expect(await eventually { await manager.currentSnapshot().state == .open })
    #expect(sink.messages.isEmpty)

    let stopping = Task { await manager.stop() }
    #expect(await eventually { await session.stopsStarted == 1 })
    #expect(await eventually { sink.messages.count == 1 })
    #expect(sink.messages.first?.contains("Connection event handler stalled event=stop") == true)

    await session.releaseStop()
    await stopping.value
    #expect(await manager.currentSnapshot().state == .stopped)
    try? await Task.sleep(for: .milliseconds(200))
    #expect(sink.messages.count == 1)
    await manager.shutdownForTesting()
  }
}

private actor BlockingStopSession: ProtocolSessionType {
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()
  private(set) var stopsStarted = 0
  private var stopRelease: CheckedContinuation<Void, Never>?

  func startTransport(sessionID: UInt64) async {
    await events.send(.lifecycle(.transportConnected(sessionID: sessionID)))
  }

  func stopTransport() async {
    stopsStarted += 1
    await withCheckedContinuation { stopRelease = $0 }
  }

  func releaseStop() {
    stopRelease?.resume()
    stopRelease = nil
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

private final class StallRecordingSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var messages: [String] {
    lock.withLock { recorded }
  }

  func write(_ event: LogEvent) {
    guard event.entry.level == .error, event.entry.message.contains("handler stalled") else { return }
    lock.withLock { recorded.append(event.entry.message) }
  }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(2)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}
