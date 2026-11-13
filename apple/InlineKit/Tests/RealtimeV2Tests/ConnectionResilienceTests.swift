import AsyncAlgorithms
import Foundation
import InlineProtocol
import Logger
import Testing
@testable import RealtimeV2

@Suite("Reconnect backoff")
struct ReconnectBackoffTests {
  @Test("early delays carry ±25% jitter around the base curve")
  func earlyDelaysAreJittered() {
    for attempt: UInt32 in 0 ..< 8 {
      let base = min(8.0, 0.2 + pow(Double(attempt), 1.5) * 0.4)
      let low = seconds(BackoffPolicy.defaultDelay(attempt: attempt, unitRandom: 0))
      let high = seconds(BackoffPolicy.defaultDelay(attempt: attempt, unitRandom: 1))
      let middle = seconds(BackoffPolicy.defaultDelay(attempt: attempt, unitRandom: 0.5))
      #expect(abs(low - base * 0.75) < 0.000_1)
      #expect(abs(high - base * 1.25) < 0.000_1)
      #expect(abs(middle - base) < 0.000_1)
    }
  }

  @Test("late delays stay between 8 and 13 seconds")
  func lateDelaysAreBounded() {
    #expect(seconds(BackoffPolicy.defaultDelay(attempt: 8, unitRandom: 0)) == 8)
    #expect(seconds(BackoffPolicy.defaultDelay(attempt: 40, unitRandom: 1)) == 13)
  }

  @Test("the V2 fallback deadline leaves the fallback time inside the connect timeout")
  func fallbackDeadlineFitsConnectTimeout() {
    let deadline = seconds(NegotiatingRealtimeTransport.defaultFallbackDeadline)
    let connectTimeout = seconds(ConnectionPolicy().connectTimeout)
    #expect(deadline > 3)
    #expect(connectTimeout - deadline >= 3)
  }
}

@Suite("Connection resilience", .serialized)
struct ConnectionResilienceTests {
  @Test("a connection that drops right after opening keeps escalating its backoff")
  func flappingConnectionEscalatesBackoff() async {
    let recorder = AttemptRecorder()
    let session = ResilienceSession(dropAfterOpen: true)
    let manager = makeManager(session: session, policy: ConnectionPolicy(
      backoff: BackoffPolicy { attempt in
        recorder.record(attempt)
        return .milliseconds(10)
      },
      stableOpenDuration: .seconds(30)
    ))
    await manager.start()

    #expect(await eventually { recorder.attempts.count >= 4 })
    let attempts = Array(recorder.attempts.prefix(4))
    #expect(attempts == [1, 2, 3, 4])
    await manager.shutdownForTesting()
  }

  @Test("a connection that stayed open restarts the backoff from the first attempt")
  func stableConnectionResetsBackoff() async {
    let recorder = AttemptRecorder()
    let session = ResilienceSession(dropAfterOpen: true)
    let manager = makeManager(session: session, policy: ConnectionPolicy(
      backoff: BackoffPolicy { attempt in
        recorder.record(attempt)
        return .milliseconds(10)
      },
      stableOpenDuration: .zero
    ))
    await manager.start()

    #expect(await eventually { recorder.attempts.count >= 3 })
    #expect(Array(recorder.attempts.prefix(3)) == [1, 1, 1])
    await manager.shutdownForTesting()
  }

  @Test("a heartbeat timer that fired late gets one more timeout before teardown")
  func lateHeartbeatTimerGetsGrace() async {
    let sink = WarningRecordingSink()
    Log.addSink(sink, id: "connection-resilience-lag")
    defer { Log.removeSink(id: "connection-resilience-lag") }

    let clock = LaggingTimeProvider()
    let session = ResilienceSession()
    let manager = makeManager(session: session, timeProvider: clock, policy: ConnectionPolicy(
      backoff: BackoffPolicy { _ in .milliseconds(10) },
      pingInterval: .milliseconds(30),
      pingTimeoutGood: .milliseconds(150),
      pingTimerLagTolerance: .seconds(1)
    ))
    await manager.start()
    #expect(await eventually { await session.pingCount >= 1 })
    // The process "freezes" while the heartbeat waits for its pong.
    clock.advance(by: 5)

    #expect(await eventually { sink.messages(containing: "reason=timer_lag").count == 1 })
    #expect(await manager.currentSnapshot().sessionID == 1)
    // The repeated timeout, without lag, tears the silent socket down as before.
    #expect(await eventually { await session.startedSessions.count >= 2 })
    #expect(sink.messages(containing: "reason=timer_lag").count == 1)
    await manager.shutdownForTesting()
  }

  @Test("a silent socket is still torn down after one heartbeat timeout")
  func silentSocketTornDown() async {
    let sink = WarningRecordingSink()
    Log.addSink(sink, id: "connection-resilience-silent")
    defer { Log.removeSink(id: "connection-resilience-silent") }

    let session = ResilienceSession()
    let manager = makeManager(session: session, policy: ConnectionPolicy(
      backoff: BackoffPolicy { _ in .milliseconds(10) },
      pingInterval: .milliseconds(30),
      pingTimeoutGood: .milliseconds(100)
    ))
    await manager.start()

    #expect(await eventually { await session.startedSessions.count >= 2 })
    #expect(sink.messages(containing: "Realtime heartbeat timeout deferred").isEmpty)
    await manager.shutdownForTesting()
  }

  @Test("a heartbeat queued behind account traffic that is still applying does not reconnect")
  func busyAccountPipelineDefersTeardown() async {
    let sink = WarningRecordingSink()
    Log.addSink(sink, id: "connection-resilience-busy")
    defer { Log.removeSink(id: "connection-resilience-busy") }

    let session = ResilienceSession(accountEventAfterOpen: true)
    let manager = makeManager(session: session, policy: ConnectionPolicy(
      backoff: BackoffPolicy { _ in .milliseconds(10) },
      pingInterval: .milliseconds(30),
      pingTimeoutGood: .milliseconds(80),
      maxPingTimeoutGraces: 50
    ))
    let collector = SlowCollector(holdFor: .milliseconds(600))
    let collecting = Task { await collector.collect(from: await manager.sessionEvents()) }
    await manager.start()

    #expect(await eventually { await collector.received >= 1 })
    // Several heartbeat timeouts pass while the collector is applying the event.
    try? await Task.sleep(for: .milliseconds(400))
    #expect(await manager.currentSnapshot().sessionID == 1)
    #expect(await manager.currentSnapshot().state == .open)
    #expect(!sink.messages(containing: "reason=account_pipeline_busy").isEmpty)

    await manager.shutdownForTesting()
    collecting.cancel()
  }

  @Test("a heartbeat pong settles a wake probe the transport replaced")
  func heartbeatPongSettlesReplacedProbe() async {
    let session = ResilienceSession(answersLatestPingOnly: true)
    let manager = makeManager(session: session, policy: ConnectionPolicy(
      backoff: BackoffPolicy { _ in .milliseconds(10) },
      pingInterval: .milliseconds(20),
      pingTimeoutGood: .milliseconds(400),
      wakeProbeTimeout: .milliseconds(300)
    ))
    await manager.start()
    #expect(await eventually { await manager.currentSnapshot().state == .open })

    for _ in 0 ..< 3 {
      await manager.systemDidWake()
      try? await Task.sleep(for: .milliseconds(350))
    }

    let snapshot = await manager.currentSnapshot()
    #expect(snapshot.state == .open)
    #expect(snapshot.sessionID == 1)
    #expect(await session.startedSessions == [1])
    await manager.shutdownForTesting()
  }
}

// MARK: - Fixtures

private func seconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private final class AttemptRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [UInt32] = []

  var attempts: [UInt32] { lock.withLock { recorded } }

  func record(_ attempt: UInt32) {
    lock.withLock { recorded.append(attempt) }
  }
}

private final class LaggingTimeProvider: ConnectionTimeProvider, @unchecked Sendable {
  private let lock = NSLock()
  private var offset: TimeInterval = 0

  func advance(by seconds: TimeInterval) {
    lock.withLock { offset += seconds }
  }

  func now() -> Date { Date() }

  func uptime() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime + lock.withLock { offset }
  }

  func sleep(for duration: Duration) async {
    try? await Task.sleep(for: duration)
  }
}

/// Opens every attempt. Never answers pings unless asked to answer only the latest one, as the
/// V3 transport does: a new ping cancels the outstanding one.
private actor ResilienceSession: ProtocolSessionType {
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()
  private let dropAfterOpen: Bool
  private let accountEventAfterOpen: Bool
  private let answersLatestPingOnly: Bool
  private(set) var startedSessions: [UInt64] = []
  private(set) var pingCount = 0
  private var latestPing: UInt64?
  private var pongTask: Task<Void, Never>?

  init(dropAfterOpen: Bool = false, accountEventAfterOpen: Bool = false, answersLatestPingOnly: Bool = false) {
    self.dropAfterOpen = dropAfterOpen
    self.accountEventAfterOpen = accountEventAfterOpen
    self.answersLatestPingOnly = answersLatestPingOnly
  }

  func startTransport(sessionID: UInt64) async {
    startedSessions.append(sessionID)
    await events.send(.lifecycle(.transportConnected(sessionID: sessionID)))
  }

  func stopTransport() async {
    pongTask?.cancel()
    pongTask = nil
  }

  func startHandshake(sessionID: UInt64) async {
    await events.send(.lifecycle(.protocolOpen(sessionID: sessionID)))
    if dropAfterOpen {
      // The manager cancels the handshake task once it opens; drop from outside that task.
      let events = self.events
      Task { await events.send(.lifecycle(.transportDisconnected(sessionID: sessionID, errorDescription: "flap"))) }
    }
    if accountEventAfterOpen {
      let events = self.events
      Task { await events.send(.account(.ack(msgId: 1), originatingSessionID: sessionID)) }
    }
  }

  func sendPing(nonce: UInt64) async {
    pingCount += 1
    guard answersLatestPingOnly else { return }
    latestPing = nonce
    pongTask?.cancel()
    pongTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(40))
      guard !Task.isCancelled else { return }
      await self?.deliverPong(nonce: nonce)
    }
  }

  private func deliverPong(nonce: UInt64) async {
    guard latestPing == nonce else { return }
    await events.send(.lifecycle(.pong(nonce: nonce)))
  }

  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 { 0 }
  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result? { nil }
}

private actor SlowCollector {
  private let holdFor: Duration
  private(set) var received = 0

  init(holdFor: Duration) {
    self.holdFor = holdFor
  }

  func collect(from channel: AsyncChannel<ProtocolSessionEventEnvelope>) async {
    for await envelope in channel {
      received += 1
      try? await Task.sleep(for: holdFor)
      await envelope.markProcessed()
    }
  }
}

private final class WarningRecordingSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  func messages(containing text: String) -> [String] {
    lock.withLock { recorded.filter { $0.contains(text) } }
  }

  func write(_ event: LogEvent) {
    lock.withLock { recorded.append(event.entry.message) }
  }
}

private func makeManager(
  session: ResilienceSession,
  timeProvider: ConnectionTimeProvider = SystemConnectionTimeProvider(),
  policy: ConnectionPolicy
) -> ConnectionManager {
  ConnectionManager(
    session: session,
    policy: policy,
    timeProvider: timeProvider,
    constraints: .init(authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true),
    telemetry: ConnectionTelemetry { _ in }
  )
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(3)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

@Suite("Persisted transaction expiry", .serialized)
struct PersistedTransactionExpiryTests {
  @Test("replay-safe work survives a long offline relaunch; other work still expires")
  func replaySafeWorkSurvivesLongRelaunch() async throws {
    let owner = TransactionOwner(accountID: 9_101, generation: 1)
    let now = Date()
    let replaySafeHoursOld = TransactionWrapper(
      id: .generate(), date: now.addingTimeInterval(-2 * 3600),
      transaction: ExpiryMutation(tag: "replay-safe-2h", replaySafe: true)
    )
    let neverReplayHoursOld = TransactionWrapper(
      id: .generate(), date: now.addingTimeInterval(-2 * 3600),
      transaction: ExpiryMutation(tag: "never-replay-2h", replaySafe: false)
    )
    let replaySafeDayOld = TransactionWrapper(
      id: .generate(), date: now.addingTimeInterval(-25 * 3600),
      transaction: ExpiryMutation(tag: "replay-safe-25h", replaySafe: true)
    )
    let persistence = PreloadedPersistence(owner: owner, wrappers: [
      replaySafeHoursOld, neverReplayHoursOld, replaySafeDayOld,
    ])

    let transactions = Transactions(persistenceHandler: persistence)
    await transactions.activate(owner: owner)

    #expect(ExpiryMutation.failures.snapshot.sorted() == ["never-replay-2h", "replay-safe-25h"])
    let dequeued = await transactions.dequeue()
    guard case let .ready(wrapper)? = dequeued else {
      Issue.record("Expected the replay-safe transaction to be dispatchable")
      return
    }
    #expect(wrapper.id == replaySafeHoursOld.id)
    #expect(await persistence.ids == [replaySafeHoursOld.id])
  }
}

private final class FailureLog: @unchecked Sendable {
  private let lock = NSLock()
  private var tags: [String] = []
  var snapshot: [String] { lock.withLock { tags } }
  func append(_ tag: String) { lock.withLock { tags.append(tag) } }
}

private struct ExpiryMutation: Transaction2, Codable {
  static let failures = FailureLog()

  struct Context: Sendable, Codable {
    var tag: String
    var replaySafe: Bool
  }

  enum CodingKeys: String, CodingKey { case context }

  var method: InlineProtocol.Method = .UNRECOGNIZED(9_999_970)
  var type: TransactionKindType = .mutation()
  var context: Context

  init(tag: String, replaySafe: Bool) {
    context = Context(tag: tag, replaySafe: replaySafe)
  }

  var reconnectReplayPolicy: TransactionReconnectPolicy? {
    context.replaySafe ? .replaySafe : .neverReplay
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? { nil }
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
  func failed(error: TransactionError) async { Self.failures.append(context.tag) }
}

private actor PreloadedPersistence: TransactionPersistenceHandler {
  private var storage: [TransactionId: TransactionWrapper]
  private let owner: TransactionOwner

  init(owner: TransactionOwner, wrappers: [TransactionWrapper]) {
    self.owner = owner
    storage = Dictionary(uniqueKeysWithValues: wrappers.map { ($0.id, $0) })
  }

  var ids: [TransactionId] { Array(storage.keys) }

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    storage[transaction.id] = transaction
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {
    storage.removeValue(forKey: transactionId)
  }

  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] {
    owner == self.owner ? Array(storage.values) : []
  }

  func deleteAllTransactions(for owner: TransactionOwner) async throws {
    storage.removeAll()
  }
}
