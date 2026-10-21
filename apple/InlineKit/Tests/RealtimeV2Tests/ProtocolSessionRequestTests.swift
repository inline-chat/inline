import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Testing

/// Direct RPCs through the real `ProtocolSession` over a scripted transport. These are the
/// caller-visible guarantees the ledger provides: a request waits for a session instead of
/// failing while the transport is down, a lost read is re-sent, a lost write is uncertain.
@Suite("Protocol session direct requests", .serialized)
struct ProtocolSessionRequestTests {
  @Test("a call made before the session opens is sent when it opens and resolves")
  func callWaitsForSession() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }

    let call = Task { try await fixture.session.callRpc(method: .getMe, input: .getMe(.init()), timeout: .seconds(5)) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await fixture.transport.sentRpcs.isEmpty)

    await fixture.open(sessionID: 1)
    #expect(await eventually { await fixture.transport.sentRpcs.count == 1 })
    let message = try #require(await fixture.transport.sentRpcs.first)
    await fixture.transport.reply(to: message.id, with: .getMe(GetMeResult()))

    let result = try await call.value
    guard case .getMe = result else { Issue.record("unexpected result \(String(describing: result))"); return }
  }

  @Test("a read in flight when the connection drops is re-sent on the next session")
  func lostReadIsResent() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }
    await fixture.open(sessionID: 1)

    let call = Task { try await fixture.session.callRpc(method: .getMe, input: .getMe(.init()), timeout: .seconds(10)) }
    #expect(await eventually { await fixture.transport.sentRpcs.count == 1 })
    let first = try #require(await fixture.transport.sentRpcs.first)

    await fixture.session.stopTransport()
    await fixture.open(sessionID: 2)
    #expect(await eventually { await fixture.transport.sentRpcs.count == 2 })
    let second = try #require(await fixture.transport.sentRpcs.last)
    #expect(second.id != first.id)
    if case let .rpcCall(call) = second.body { #expect(call.method == .getMe) } else { Issue.record("not an rpc") }

    await fixture.transport.reply(to: second.id, with: .getMe(GetMeResult()))
    _ = try await call.value
  }

  @Test("a write in flight when the connection drops resolves as outcome unknown, not stopped")
  func lostWriteIsUncertain() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }
    await fixture.open(sessionID: 1)

    let call = Task { try await fixture.session.callRpc(method: .sendMessage, input: .sendMessage(.init()), timeout: .seconds(10)) }
    #expect(await eventually { await fixture.transport.sentRpcs.count == 1 })
    await fixture.session.stopTransport()

    await #expect(throws: ProtocolSessionError.self) { try await call.value }
    do { _ = try await call.value } catch let error as ProtocolSessionError {
      guard case .commitOutcomeUnknown = error else { Issue.record("expected commitOutcomeUnknown, got \(error)"); return }
    }
    await fixture.open(sessionID: 2)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await fixture.transport.sentRpcs.count == 1, "an uncertain write must never be re-sent")
  }

  @Test("a queued write survives the gap and is sent exactly once on the next session")
  func queuedWriteSurvivesGap() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }

    let call = Task { try await fixture.session.callRpc(method: .sendMessage, input: .sendMessage(.init()), timeout: .seconds(10)) }
    try await Task.sleep(for: .milliseconds(50))
    await fixture.session.stopTransport()
    await fixture.open(sessionID: 1)
    #expect(await eventually { await fixture.transport.sentRpcs.count == 1 })
    let message = try #require(await fixture.transport.sentRpcs.first)
    await fixture.transport.reply(to: message.id, with: .sendMessage(SendMessageResult()))
    _ = try await call.value
    #expect(await fixture.transport.sentRpcs.count == 1)
  }

  @Test("the deadline while no session opens is the only notConnected outcome")
  func deadlineWhileDisconnected() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }

    let started = ContinuousClock.now
    do {
      _ = try await fixture.session.callRpc(method: .getMe, input: .getMe(.init()), timeout: .milliseconds(200))
      Issue.record("expected notConnected")
    } catch let error as ProtocolSessionError {
      guard case .notConnected = error else { Issue.record("expected notConnected, got \(error)"); return }
    }
    #expect(ContinuousClock.now - started >= .milliseconds(150))
    #expect(await fixture.transport.sentRpcs.isEmpty)
  }

  @Test("the deadline on an open session is a timeout for reads and uncertainty for writes")
  func deadlineWhileOpen() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }
    await fixture.open(sessionID: 1)

    do {
      _ = try await fixture.session.callRpc(method: .getMe, input: .getMe(.init()), timeout: .milliseconds(150))
      Issue.record("expected timeout")
    } catch let error as ProtocolSessionError {
      guard case .timeout = error else { Issue.record("expected timeout, got \(error)"); return }
    }
    do {
      _ = try await fixture.session.callRpc(method: .sendMessage, input: .sendMessage(.init()), timeout: .milliseconds(150))
      Issue.record("expected commitOutcomeUnknown")
    } catch let error as ProtocolSessionError {
      guard case .commitOutcomeUnknown = error else { Issue.record("expected commitOutcomeUnknown, got \(error)"); return }
    }
  }

  @Test("closing the session resolves held calls with stopped")
  func closeResolvesHeldCalls() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }

    let call = Task { try await fixture.session.callRpc(method: .getMe, input: .getMe(.init()), timeout: .seconds(10)) }
    try await Task.sleep(for: .milliseconds(50))
    await fixture.session.closeDirectRequests()
    do {
      _ = try await call.value
      Issue.record("expected stopped")
    } catch let error as ProtocolSessionError {
      guard case .stopped = error else { Issue.record("expected stopped, got \(error)"); return }
    }
  }

  @Test("a transport capacity refusal is retried after a hold, not surfaced")
  func capacityRefusalRetries() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }
    await fixture.open(sessionID: 1)
    await fixture.transport.refuseNextSends(1, with: .capacityExceeded)

    let call = Task { try await fixture.session.callRpc(method: .getMe, input: .getMe(.init()), timeout: .seconds(10)) }
    #expect(await eventually(within: .seconds(3)) { await fixture.transport.sentRpcs.count == 1 })
    let message = try #require(await fixture.transport.sentRpcs.first)
    await fixture.transport.reply(to: message.id, with: .getMe(GetMeResult()))
    _ = try await call.value
    #expect(await fixture.transport.refusals == 1)
  }

  @Test("a server pre-execution rejection re-sends the request")
  func rejectedBeforeExecutionResends() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }
    await fixture.open(sessionID: 1)

    let call = Task { try await fixture.session.callRpc(method: .sendMessage, input: .sendMessage(.init()), timeout: .seconds(10)) }
    #expect(await eventually { await fixture.transport.sentRpcs.count == 1 })
    let first = try #require(await fixture.transport.sentRpcs.first)
    await fixture.transport.emit(.rpcRejectedBeforeExecution(msgId: first.id))
    #expect(await eventually(within: .seconds(3)) { await fixture.transport.sentRpcs.count == 2 })
    let second = try #require(await fixture.transport.sentRpcs.last)
    await fixture.transport.reply(to: second.id, with: .sendMessage(SendMessageResult()))
    _ = try await call.value
  }

  @Test("a failing pre-dispatch check resolves with that error and sends nothing")
  func beforeDispatchFailure() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }
    await fixture.open(sessionID: 1)

    struct Rejected: Error {}
    do {
      _ = try await fixture.session.callRpc(
        method: .getMe, input: .getMe(.init()), timeout: .seconds(5),
        beforeDispatch: { throw Rejected() }
      )
      Issue.record("expected Rejected")
    } catch is Rejected {}
    try await Task.sleep(for: .milliseconds(50))
    #expect(await fixture.transport.sentRpcs.isEmpty)
  }

  @Test("cancelling a held call resolves it and never sends it")
  func cancellationOfHeldCall() async throws {
    let fixture = await Fixture()
    defer { fixture.close() }

    let call = Task { try await fixture.session.callRpc(method: .sendMessage, input: .sendMessage(.init()), timeout: .seconds(10)) }
    try await Task.sleep(for: .milliseconds(50))
    call.cancel()
    await #expect(throws: CancellationError.self) { try await call.value }
    await fixture.open(sessionID: 1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await fixture.transport.sentRpcs.isEmpty)
  }
}

// MARK: - Fixture

private final class Fixture: Sendable {
  let session: ProtocolSession
  let transport: ScriptedTransport
  private let drain: Task<Void, Never>

  init() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = ScriptedTransport()
    let session = ProtocolSession(transport: transport, auth: auth.handle)
    self.transport = transport
    self.session = session
    // The session's event channel is unbuffered and awaits processing receipts; a direct
    // owner like the share extension drains it the same way.
    drain = Task {
      for await envelope in session.events {
        await envelope.markProcessed()
      }
    }
    await session.start()
  }

  /// Starts the transport for `sessionID` and performs the (V3-style) open handshake.
  func open(sessionID: UInt64) async {
    await session.startTransport(sessionID: sessionID)
    await session.startHandshake(sessionID: sessionID)
  }

  func close() {
    drain.cancel()
  }
}

/// Behaves like the production transports: a send while not connected is refused before any
/// bytes are accepted.
private actor ScriptedTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private(set) var sentRpcs: [ClientMessage] = []
  private(set) var refusals = 0
  private var connected = false
  private var refusalsRemaining = 0
  private var refusalError: TransportError = .capacityExceeded

  func isApplicationAuthenticatedOnConnect() -> Bool { true }

  func start() async {
    connected = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    connected = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    guard case .rpcCall = message.body else { return }
    guard connected else { throw TransportError.notConnected }
    if refusalsRemaining > 0 {
      refusalsRemaining -= 1
      refusals += 1
      throw refusalError
    }
    sentRpcs.append(message)
  }

  func refuseNextSends(_ count: Int, with error: TransportError) {
    refusalsRemaining = count
    refusalError = error
  }

  func emit(_ event: TransportEvent) async {
    await events.send(event)
  }

  func reply(to messageID: UInt64, with result: RpcResult.OneOf_Result) async {
    var message = ServerProtocolMessage()
    message.body = .rpcResult(.with {
      $0.reqMsgID = messageID
      $0.result = result
    })
    await events.send(.message(message))
  }
}

private func eventually(
  within limit: Duration = .seconds(2),
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + limit
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}
