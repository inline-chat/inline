import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import Logger
import Testing

@testable import RealtimeV2

@Suite("Legacy protocol upgrade", .serialized)
struct LegacyProtocolUpgradeTests {
  private let source = AuthCredentials(userId: 7, token: "7:legacy-fixture")

  @Test("real upgrade outcomes reach release logs without leaking source or server error text")
  func migrationOutcomesAreObservable() async throws {
    let sink = UpgradeLogRecorder()
    let sinkID = "legacy-upgrade-test-\(UUID())"
    Log.addSink(sink, id: sinkID)
    defer { Log.removeSink(id: sinkID) }

    for scenario in 0..<4 {
      sink.clear()
      let harness = try UpgradeAttemptHarness()
      if scenario == 1 {
        await harness.respondToUpgrade(.with { $0.body = .authUpgradeSession(.with {
          $0.state = .declined(.with { $0.reason = .disabled })
        }) })
      } else if scenario == 2 {
        // An older server rejects an unknown operation. The original bearer and staged
        // candidate remain usable, and remote text must not reach logs or Sentry.
        await harness.respondToUpgrade(.with { $0.body = .rpcError(.with {
          $0.code = 400
          $0.message = "private-server-message-sentinel"
        }) })
      } else if scenario == 3 {
        await harness.returnWrongIdentity()
      }
      let snapshots = UpgradeSnapshotSource(.init(status: .authenticated(source), didHydrate: true))
      let operation = attempt(harness)
      let coordinator = LegacyProtocolUpgradeCoordinator(snapshots: { snapshots.stream() }) {
        try await operation.run(source: $0)
      }
      await coordinator.start()
      #expect(await eventually { sink.finished != nil })
      let entry = try #require(sink.finished)
      #expect(entry.level == [LogLevel.info, .info, .warning, .error][scenario])
      #expect(entry.message.contains(scenario == 0 ? "outcome=prepared" : "outcome=deferred"))
      #expect(entry.message.contains(["reason=verified", "reason=disabled", "reason=realtime_v3:rpc:", "reason=realtime_v3:unexpected_response"][scenario]))
      #expect(entry.message.contains("duration_ms="))
      #expect(await harness.staged != nil)
      #expect((await harness.committed != nil) == (scenario == 0))
      #expect(sink.entries.allSatisfy { entry in
        [entry.message, entry.error ?? ""].allSatisfy {
          !$0.contains(source.token) && !$0.contains("private-server-message-sentinel")
        }
      })
      // Error-level outcomes carry a fixed category so Sentry groups them by cause.
      #expect(sink.errorCategories == (scenario == 3 ? ["legacy_v3_upgrade:realtime_v3:unexpected_response"] : []))
      await coordinator.stop()
    }
  }

  @Test("startup authority rejects a replaced bearer while allowing temporary and salt refresh")
  func startupChecksExactSessionAuthority() async throws {
    let harness = try UpgradeAttemptHarness()
    let credentials = InlineProtocolSessionCredentials(
      userId: source.userId, accountSessionId: 42,
      permanent: harness.permanent, temporary: harness.temporary
    )
    var snapshot = AuthSnapshot(status: .authenticated(source), didHydrate: true, inlineProtocol: credentials)
    #expect(InlineProtocolV3Transport.matchesAccount(snapshot, credentials: credentials, bearerToken: source.token))
    snapshot.inlineProtocol?.temporary = nil
    let permanent = credentials.permanent
    snapshot.inlineProtocol?.permanent = try InlineProtocolAuthorization(
      key: permanent.key, keyID: permanent.keyID, serverSalt: permanent.serverSalt + 1,
      temporary: false, expiresAt: nil
    )
    #expect(InlineProtocolV3Transport.matchesAccount(snapshot, credentials: credentials, bearerToken: source.token))
    snapshot.status = .authenticated(.init(userId: source.userId, token: "7:replacement-fixture"))
    #expect(!InlineProtocolV3Transport.matchesAccount(snapshot, credentials: credentials, bearerToken: source.token))
    snapshot.status = .authenticated(source)
    snapshot.inlineProtocol?.accountSessionId = 43
    #expect(!InlineProtocolV3Transport.matchesAccount(snapshot, credentials: credentials, bearerToken: source.token))
  }

  @Test("a queued legacy connection-open cannot restart migration after stop begins")
  func queuedOpenDoesNotRestartStoppedUpgrade() async {
    let upgrade = UpgradeStopGate()
    let legacy = UpgradeTestTransport(authenticated: false)
    let transport = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { false },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { legacy },
      upgrade: upgrade
    )
    var events = transport.events.makeAsyncIterator()
    let starting = Task { await transport.start() }
    _ = await events.next() // connecting
    _ = await events.next() // connected
    await starting.value
    let open = Task { await legacy.authorize() }
    await open.value // handed to the forwarder, which is blocked on our next receive
    let stopping = Task {
      await transport.stop()
      await upgrade.markTransportStopped()
    }
    #expect(await eventually { await upgrade.stopping })
    _ = await events.next() // release the connectionOpen while stop owns the transport
    // The following message cannot reach this iterator until the forwarder has finished
    // processing connectionOpen. Keep upgrade.stop suspended through that boundary.
    let barrier = Task { await legacy.forwardingBarrier() }
    _ = await events.next()
    await barrier.value
    let drain = Task {
      for await _ in transport.events {
        guard !Task.isCancelled else { return }
      }
    }
    await upgrade.releaseStop()
    let stopped = await eventually { await upgrade.transportStopped }
    #expect(stopped)
    if stopped { await stopping.value } else { stopping.cancel() }
    drain.cancel()
    #expect(await upgrade.starts == 0)
  }

  @Test("lost upgrade response reuses the durable key, then verifies application identity before commit")
  func lostResponseResumesCandidate() async throws {
    let harness = try UpgradeAttemptHarness()
    await harness.loseNextResponse()
    do {
      try await attempt(harness).run(source: source)
      Issue.record("Expected uncertain first response")
    } catch {}
    #expect(await harness.staged != nil)
    #expect(await harness.committed == nil)
    #expect(await harness.freshPermanentCount == 1)

    try await attempt(harness).run(source: source)
    #expect(await harness.freshPermanentCount == 1)
    #expect(await harness.recoveredPermanentCount == 1)
    #expect(await harness.committed?.userId == source.userId)
    #expect(await harness.committed?.accountSessionId == 42)
    #expect(await harness.committed?.temporary != nil)
    #expect(await harness.trace == [
      "stage", "upgrade", "recover", "upgrade", "bind", "getMe", "commit",
    ])
  }

  @Test("failed durable stage sends no bearer; temporary proof failure never commits")
  func storageAndProofFailuresPreserveLegacy() async throws {
    let storageFailure = try UpgradeAttemptHarness()
    await storageFailure.failStage()
    await #expect(throws: UpgradeFixtureError.self) {
      try await attempt(storageFailure).run(source: source)
    }
    #expect(await storageFailure.trace == ["stage"])
    #expect(await storageFailure.committed == nil)

    let wrongIdentity = try UpgradeAttemptHarness()
    await wrongIdentity.returnWrongIdentity()
    await #expect(throws: InlineProtocolV3ConnectionError.self) {
      try await attempt(wrongIdentity).run(source: source)
    }
    #expect(await wrongIdentity.committed == nil)
    #expect(await wrongIdentity.staged != nil)
  }

  @Test("live V2 ignores newly prepared credentials, then reconnect switches without old stop events")
  func switchesOnlyAtConnectionBoundary() async {
    let availability = UpgradeAvailability()
    let legacy = UpgradeTestTransport(authenticated: false, stopMessage: true)
    let v3 = UpgradeTestTransport(authenticated: true)
    let transport = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { availability.isPrepared },
      hasLegacyCredentials: { true },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { v3 }
    )
    let events = UpgradeEventRecorder()
    let observer = observe(transport, into: events)
    await transport.start()
    #expect(await eventually { await events.connected == 1 })
    availability.prepare()
    await transport.start()
    #expect(await legacy.starts == 1)
    #expect(await v3.starts == 0)
    #expect(await transport.isApplicationAuthenticatedOnConnect() == false)

    await legacy.disconnect()
    #expect(await eventually { await events.disconnected == 1 })
    await transport.start()
    #expect(await eventually { await events.connected == 2 })
    #expect(await legacy.stops == 1)
    #expect(await v3.starts == 1)
    #expect(await transport.isApplicationAuthenticatedOnConnect())
    #expect(await events.disconnected == 1)
    #expect(await events.messages == 0)
    await transport.stop()
    observer.cancel()
  }

  @Test("hung background upgrade cannot delay V2 and stop cancels its single flight")
  func backgroundWorkDoesNotDelayLegacy() async {
    let snapshots = UpgradeSnapshotSource(.init(status: .authenticated(source), didHydrate: true))
    let probe = UpgradeRunProbe()
    let coordinator = LegacyProtocolUpgradeCoordinator(snapshots: { snapshots.stream() }) { _ in
      await probe.started()
      do { try await Task.sleep(for: .seconds(60)) } catch {
        await probe.cancelled()
        throw error
      }
    }
    let legacy = UpgradeTestTransport(authenticated: false)
    let transport = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { false },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { legacy },
      upgrade: coordinator
    )
    let events = UpgradeEventRecorder()
    let observer = observe(transport, into: events)
    await transport.start()
    #expect(await eventually { await events.connected == 1 })
    #expect(await probe.starts == 0)
    await legacy.authorize()
    #expect(await eventually {
      let connected = await events.connected
      let starts = await probe.starts
      return connected == 1 && starts == 1
    })
    await transport.start()
    await coordinator.start()
    #expect(await probe.starts == 1)
    await transport.stop()
    #expect(await probe.cancellations == 1)
    observer.cancel()
  }

  @Test("account switch cancels the old candidate before starting the new account")
  func accountSwitchCancelsCandidate() async {
    let snapshots = UpgradeSnapshotSource(.init(status: .authenticated(source), didHydrate: true))
    let probe = UpgradeRunProbe()
    let coordinator = LegacyProtocolUpgradeCoordinator(snapshots: { snapshots.stream() }) { _ in
      await probe.started()
      do { try await Task.sleep(for: .seconds(60)) } catch {
        await probe.cancelled()
        throw error
      }
    }
    await coordinator.start()
    #expect(await eventually { await probe.starts == 1 })
    snapshots.update(.init(status: .authenticated(.init(userId: 8, token: "8:fixture")), didHydrate: true))
    #expect(await eventually {
      let starts = await probe.starts
      let cancellations = await probe.cancellations
      return starts == 2 && cancellations == 1
    })
    #expect(await probe.maximumConcurrent == 1)
    await coordinator.stop()
    #expect(await probe.cancellations == 2)
  }

  @Test("a stalled or failed additive V3 startup falls back without a disconnected event")
  func fallbackIsBoundedAndQuiet() async {
    for mode in [UpgradeTestTransport.Mode.stalled, .failed] {
      let legacy = UpgradeTestTransport(authenticated: false)
      let v3 = UpgradeTestTransport(authenticated: true, mode: mode)
      let transport = NegotiatingRealtimeTransport(
        hasInlineProtocolCredentials: { true },
        hasLegacyCredentials: { true },
        makeLegacyTransport: { legacy },
        makeInlineProtocolTransport: { v3 },
        fallbackDeadline: .milliseconds(20)
      )
      let events = UpgradeEventRecorder()
      let observer = observe(transport, into: events)
      await transport.start()
      #expect(await eventually { await events.connected == 1 })
      #expect(await legacy.starts == 1)
      #expect(await v3.stops == 1)
      #expect(await events.disconnected == 0)
      await legacy.disconnect()
      #expect(await eventually { await events.disconnected == 1 })
      await transport.start()
      #expect(await eventually { await events.connected == 2 })
      #expect(await legacy.starts == 2)
      #expect(await v3.starts == 1)
      await transport.stop()
      observer.cancel()
    }
  }

  @Test("native V3 and real session revocation never downgrade")
  func authoritativeV3DoesNotDowngrade() async {
    for hasLegacy in [false, true] {
      let legacy = UpgradeTestTransport(authenticated: false)
      let v3 = UpgradeTestTransport(authenticated: true, mode: hasLegacy ? .revoked : .failed)
      let transport = NegotiatingRealtimeTransport(
        hasInlineProtocolCredentials: { true },
        hasLegacyCredentials: { hasLegacy },
        makeLegacyTransport: { legacy },
        makeInlineProtocolTransport: { v3 },
        fallbackDeadline: .milliseconds(20)
      )
      let events = UpgradeEventRecorder()
      let observer = observe(transport, into: events)
      await transport.start()
      #expect(await eventually { await events.disconnected == 1 })
      #expect(await legacy.starts == 0)
      #expect(await events.messages == (hasLegacy ? 1 : 0))
      await transport.stop()
      observer.cancel()
    }
  }

  @Test("scoped V3 revocation reaches the account owner without falling back to the retained bearer")
  func scopedRevocationDoesNotDowngrade() async throws {
    let auth = Auth.mocked(authenticated: true)
    let receipt = try auth.handle.makeInvalidationReceipt()
    let legacy = UpgradeTestTransport(authenticated: false)
    let v3 = UpgradeTestTransport(authenticated: true, mode: .revoked, revocationReceipt: receipt)
    let transport = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { true },
      hasLegacyCredentials: { true },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { v3 },
      fallbackDeadline: .milliseconds(20)
    )
    let events = UpgradeEventRecorder()
    let observer = observe(transport, into: events)
    await transport.start()
    #expect(await eventually { await events.disconnected == 1 })
    #expect(await events.invalidations == [receipt])
    #expect(await legacy.starts == 0)
    #expect(await events.connected == 0)
    await transport.stop()
    observer.cancel()
  }

  @Test("late fallback retirement cannot erase a connection started after stop")
  func stopRacingFallbackPreservesNewChild() async throws {
    let legacy = UpgradeTestTransport(authenticated: false)
    let v3 = UpgradeBlockingStopTransport()
    let transport = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { true },
      hasLegacyCredentials: { true },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { v3 }
    )
    let events = UpgradeEventRecorder()
    let observer = observe(transport, into: events)
    await transport.start()
    #expect(await eventually { await v3.firstStopStarted })
    await transport.stop()
    await transport.start()
    #expect(await eventually { await events.connected == 1 })
    await v3.releaseFirstStop()
    #expect(await eventually { await v3.firstStopFinished })
    try await transport.send(.init())
    await transport.start()
    #expect(await legacy.starts == 1)
    await transport.stop()
    observer.cancel()
  }

  @Test("real protocol session preserves the reconnect ID across V3 selection and rollback")
  func realSessionReconnectKeepsNewGeneration() async {
    for v3Mode in [UpgradeTestTransport.Mode.connected, .failed] {
      let availability = UpgradeAvailability()
      let legacy = UpgradeTestTransport(authenticated: false, stopMessage: true)
      let v3 = UpgradeTestTransport(authenticated: true, mode: v3Mode)
      let transport = NegotiatingRealtimeTransport(
        hasInlineProtocolCredentials: { availability.isPrepared },
        hasLegacyCredentials: { true },
        makeLegacyTransport: { legacy },
        makeInlineProtocolTransport: { v3 }
      )
      let session = ProtocolSession(transport: transport, auth: Auth.mocked(authenticated: true).handle)
      let manager = ConnectionManager(
        session: session,
        policy: .init(backoff: .init { _ in .milliseconds(10) }),
        constraints: .init(authAvailable: true, networkAvailable: true, appActive: true, userWantsConnection: true)
      )
      await session.start()
      await manager.start()
      #expect(await eventually { await manager.currentSnapshot().state == .open })
      let initialID = await manager.currentSnapshot().sessionID
      availability.prepare()
      await legacy.disconnect()
      #expect(await eventually {
        let snapshot = await manager.currentSnapshot()
        return snapshot.state == .open && snapshot.sessionID == initialID + 1
      })
      #expect(await v3.starts == 1)
      #expect(await legacy.stops == 1)
      #expect(await legacy.starts == (v3Mode == .connected ? 1 : 2))
      #expect(await transport.isApplicationAuthenticatedOnConnect() == (v3Mode == .connected))
      await manager.stop()
      await manager.shutdownForTesting()
      transport.events.finish()
    }
  }

  private func attempt(_ harness: UpgradeAttemptHarness) -> LegacyProtocolUpgradeAttempt {
    LegacyProtocolUpgradeAttempt(
      url: URL(string: "wss://example.invalid/realtime/v3")!,
      resolveRoots: { [] },
      connect: { await harness.connect($0) },
      candidate: { _ in await harness.staged },
      stage: { authorization, _ in try await harness.stage(authorization) },
      commit: { credentials, _ in await harness.commit(credentials) },
      validateSource: {}
    )
  }

  @Test("upgrade outcomes and fallbacks map to bounded rollout vocabularies")
  func rolloutHealthVocabularyIsBounded() {
    let cases: [((any Error)?, String)] = [
      (nil, "verified"),
      (CancellationError(), "cancelled"),
      (LegacyProtocolUpgradeDecline.declined(.disabled), "disabled"),
      (LegacyProtocolUpgradeDecline.declined(.ineligible), "ineligible"),
      (LegacyProtocolUpgradeDecline.declined(.sourceRejected), "source_rejected"),
      (LegacyProtocolUpgradeDecline.notBound, "not_bound"),
      (AuthStorageError.keychainWriteFailed, "storage"),
      (InlineProtocolV3ConnectionError.timeout, "timeout"),
      (InlineProtocolV3ConnectionError.rpc(.with { $0.code = 400 }), "server_rejected"),
      (InlineProtocolV3ConnectionError.protocolFailure, "protocol"),
      (URLError(.notConnectedToInternet), "network"),
      (UpgradeFixtureError.storage, "unexpected"),
    ]
    for (error, expected) in cases {
      let outcome = LegacyProtocolUpgradeOutcome(error: error)
      #expect(outcome.reasonClass == expected)
      #expect(PerformanceTrace.isAllowedEnumValue(outcome.reasonClass, for: "reason_class"))
      #expect(PerformanceTrace.isAllowedEnumValue(outcome.outcome, for: "outcome"))
    }
    for reason in ["deadline", "startup_failure", "operator_preference"] {
      #expect(PerformanceTrace.isAllowedEnumValue(reason, for: "fallback_reason"))
    }
    for cohort in ["legacy", "upgraded", "native"] {
      #expect(PerformanceTrace.isAllowedEnumValue(cohort, for: "cohort"))
    }
  }

  @Test("operator V2 preference keeps upgraded sessions on V2 and never affects native V3")
  func operatorPreferenceSelectsLegacyOnlyForBearerSessions() async {
    let preference = UpgradeTransportPreferenceBox(prefersLegacy: true)
    let legacy = UpgradeTestTransport(authenticated: false)
    let v3 = UpgradeTestTransport(authenticated: true)
    let upgraded = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { true },
      hasLegacyCredentials: { true },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { v3 },
      transportPreference: preference.store
    )
    let upgradedEvents = UpgradeEventRecorder()
    let upgradedObserver = observe(upgraded, into: upgradedEvents)
    await upgraded.start()
    #expect(await eventually { await upgradedEvents.connected == 1 })
    #expect(await legacy.starts == 1)
    #expect(await v3.starts == 0)
    await upgraded.stop()
    upgradedObserver.cancel()

    // A native V3 login has no bearer, so no V2 path exists to roll back to.
    let nativeV3 = UpgradeTestTransport(authenticated: true)
    let native = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { true },
      hasLegacyCredentials: { false },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { nativeV3 },
      transportPreference: preference.store
    )
    let nativeEvents = UpgradeEventRecorder()
    let nativeObserver = observe(native, into: nativeEvents)
    await native.start()
    #expect(await eventually { await nativeEvents.connected == 1 })
    #expect(await nativeV3.starts == 1)
    #expect(await legacy.starts == 1)
    await native.stop()
    nativeObserver.cancel()
  }

  @Test("a V3 open carrying the V2 preference reconnects through V2 until a V2 open allows V3 again")
  func operatorPreferenceRollsBackLiveV3() async {
    let preference = UpgradeTransportPreferenceBox(prefersLegacy: false)
    let legacy = UpgradeTestTransport(authenticated: false)
    let v3 = UpgradeTestTransport(authenticated: true)
    let transport = NegotiatingRealtimeTransport(
      hasInlineProtocolCredentials: { true },
      hasLegacyCredentials: { true },
      makeLegacyTransport: { legacy },
      makeInlineProtocolTransport: { v3 },
      transportPreference: preference.store
    )
    let events = UpgradeEventRecorder()
    let observer = observe(transport, into: events)
    await transport.start()
    #expect(await eventually { await events.connected == 1 })
    #expect(await v3.starts == 1)

    await v3.emit(.transportPreference(prefersLegacy: true))
    // One reconnect through the connection owner; the retired child's own stop event is dropped.
    #expect(await eventually { await events.disconnected == 1 })
    #expect(preference.prefersLegacy)
    #expect(await v3.stops == 1)

    await transport.start()
    #expect(await eventually { await events.connected == 2 })
    #expect(await legacy.starts == 1)
    #expect(await v3.starts == 1)

    await legacy.authorize(open: .with { $0.upgradedSessionTransport = .v3 })
    #expect(await eventually { !preference.prefersLegacy })
    // The live V2 owner keeps its requests; V3 returns only at the next connection boundary.
    #expect(await legacy.stops == 0)
    await transport.stop()
    observer.cancel()
  }

  @Test("connection opens decode the operator preference and persist it")
  func preferenceDecodingAndStorage() throws {
    #expect(UpgradedSessionTransportPreference.prefersLegacy(.init()) == false)
    #expect(UpgradedSessionTransportPreference.prefersLegacy(.with { $0.upgradedSessionTransport = .v3 }) == false)
    #expect(UpgradedSessionTransportPreference.prefersLegacy(.with { $0.upgradedSessionTransport = .legacy }))

    let suite = "LegacyProtocolUpgradeTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stored = UpgradedSessionTransportPreference.stored(in: defaults)
    #expect(stored.prefersLegacy() == false)
    stored.record(true)
    #expect(UpgradedSessionTransportPreference.stored(in: defaults).prefersLegacy())
    stored.record(false)
    #expect(stored.prefersLegacy() == false)
  }
}

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(1)
  while !(await predicate()) {
    if ContinuousClock.now >= deadline { return false }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return true
}

private func observe(_ transport: any Transport, into recorder: UpgradeEventRecorder) -> Task<Void, Never> {
  Task {
    for await event in transport.events {
      guard !Task.isCancelled else { return }
      await recorder.record(event)
    }
  }
}

private actor UpgradeEventRecorder {
  private(set) var connected = 0
  private(set) var disconnected = 0
  private(set) var messages = 0
  private(set) var invalidations: [AuthInvalidationReceipt] = []
  func record(_ event: TransportEvent) {
    switch event {
    case .connected: connected += 1
    case .disconnected: disconnected += 1
    case .message: messages += 1
    case let .authInvalidated(receipt): invalidations.append(receipt)
    default: break
    }
  }
}

private final class UpgradeTransportPreferenceBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool
  init(prefersLegacy: Bool) { value = prefersLegacy }
  var prefersLegacy: Bool { lock.withLock { value } }
  var store: UpgradedSessionTransportPreference {
    .init(
      prefersLegacy: { [self] in prefersLegacy },
      record: { [self] next in lock.withLock { value = next } }
    )
  }
}

private final class UpgradeAvailability: @unchecked Sendable {
  private let lock = NSLock()
  private var prepared = false
  var isPrepared: Bool { lock.withLock { prepared } }
  func prepare() { lock.withLock { prepared = true } }
}

private final class UpgradeSnapshotSource: @unchecked Sendable {
  private let lock = NSLock()
  private var current: AuthSnapshot
  private var subscribers: [UUID: AsyncStream<AuthSnapshot>.Continuation] = [:]
  init(_ snapshot: AuthSnapshot) { current = snapshot }
  func stream() -> AsyncStream<AuthSnapshot> {
    let id = UUID()
    let pair = AsyncStream.makeStream(of: AuthSnapshot.self)
    lock.withLock {
      subscribers[id] = pair.continuation
      pair.continuation.yield(current)
    }
    pair.continuation.onTermination = { [weak self] _ in
      _ = self?.lock.withLock { self?.subscribers.removeValue(forKey: id) }
    }
    return pair.stream
  }
  func update(_ snapshot: AuthSnapshot) {
    lock.withLock {
      current = snapshot
      for subscriber in subscribers.values { subscriber.yield(snapshot) }
    }
  }
}

private actor UpgradeRunProbe {
  private(set) var starts = 0
  private(set) var cancellations = 0
  private(set) var maximumConcurrent = 0
  func started() {
    starts += 1
    maximumConcurrent = max(maximumConcurrent, starts - cancellations)
  }
  func cancelled() { cancellations += 1 }
}

private actor UpgradeStopGate: LegacyProtocolUpgrading {
  private(set) var starts = 0
  private(set) var stopping = false
  private(set) var transportStopped = false
  private var release: CheckedContinuation<Void, Never>?
  func start() { starts += 1 }
  func stop() async {
    stopping = true
    await withCheckedContinuation { release = $0 }
  }
  func releaseStop() {
    release?.resume()
    release = nil
  }
  func markTransportStopped() { transportStopped = true }
}

private actor UpgradeTestTransport: Transport {
  enum Mode: Sendable { case connected, stalled, failed, revoked }
  nonisolated let events = AsyncChannel<TransportEvent>()
  let authenticated: Bool
  let mode: Mode
  let stopMessage: Bool
  let revocationReceipt: AuthInvalidationReceipt?
  private(set) var starts = 0
  private(set) var stops = 0

  init(
    authenticated: Bool, mode: Mode = .connected, stopMessage: Bool = false,
    revocationReceipt: AuthInvalidationReceipt? = nil
  ) {
    self.authenticated = authenticated
    self.mode = mode
    self.stopMessage = stopMessage
    self.revocationReceipt = revocationReceipt
  }
  func start() async {
    starts += 1
    await events.send(.connecting)
    switch mode {
    case .connected: await events.send(.connected)
    case .stalled: break
    case .failed: await events.send(.disconnected(errorDescription: "unavailable"))
    case .revoked:
      if let revocationReceipt {
        await events.send(.authInvalidated(revocationReceipt))
      } else {
        await events.send(.message(.with { $0.body = .connectionError(.with { $0.reason = .sessionRevoked }) }))
      }
      await events.send(.disconnected(errorDescription: "revoked"))
    }
  }
  func stop() async {
    stops += 1
    await events.send(.disconnected(errorDescription: "stopped"))
    if stopMessage { await events.send(.message(.init())) }
  }
  func send(_ message: ClientMessage) async throws {
    switch message.body {
    case .connectionInit:
      await authorize()
    case let .ping(ping):
      await events.send(.message(.with { $0.body = .pong(.with { $0.nonce = ping.nonce }) }))
    default: break
    }
  }
  func isApplicationAuthenticatedOnConnect() -> Bool { authenticated }
  func authorize(open: ConnectionOpen = .init()) async {
    await events.send(.message(.with { $0.body = .connectionOpen(open) }))
  }
  func emit(_ event: TransportEvent) async { await events.send(event) }
  func forwardingBarrier() async { await events.send(.message(.init())) }
  func disconnect() async { await events.send(.disconnected(errorDescription: "lost")) }
}

private enum UpgradeFixtureError: Error { case lostResponse, storage }

private actor UpgradeBlockingStopTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private var stops = 0
  private var release: CheckedContinuation<Void, Never>?
  private(set) var firstStopStarted = false
  private(set) var firstStopFinished = false
  func start() async {
    await events.send(.connecting)
    await events.send(.disconnected(errorDescription: "unavailable"))
  }
  func stop() async {
    stops += 1
    if stops == 1 {
      firstStopStarted = true
      await withCheckedContinuation { release = $0 }
      firstStopFinished = true
    } else {
      await events.send(.disconnected(errorDescription: "stopped"))
    }
  }
  func releaseFirstStop() {
    release?.resume()
    release = nil
  }
  func send(_ message: ClientMessage) async throws {}
}

private actor UpgradeAttemptHarness {
  let permanent: InlineProtocolAuthorization
  let temporary: InlineProtocolAuthorization
  private(set) var staged: InlineProtocolAuthorization?
  private(set) var committed: InlineProtocolSessionCredentials?
  private(set) var freshPermanentCount = 0
  private(set) var recoveredPermanentCount = 0
  private(set) var trace: [String] = []
  private var loseResponse = false
  private var stageFails = false
  private var wrongIdentity = false
  private var upgradeResponse: RealtimeV3Response?

  init() throws {
    func authorization(temporary: Bool) throws -> InlineProtocolAuthorization {
      let key = [UInt8](repeating: temporary ? 0x41 : 0x31, count: 256)
      return try InlineProtocolAuthorization(
        key: key, keyID: InlineSecureTransport.authKeyID(key), serverSalt: 7,
        temporary: temporary, expiresAt: temporary ? 1_900_000_000 : nil
      )
    }
    permanent = try authorization(temporary: false)
    temporary = try authorization(temporary: true)
  }
  func loseNextResponse() { loseResponse = true }
  func failStage() { stageFails = true }
  func returnWrongIdentity() { wrongIdentity = true }
  func respondToUpgrade(_ response: RealtimeV3Response) { upgradeResponse = response }
  func stage(_ authorization: InlineProtocolAuthorization) throws -> InlineProtocolAuthorization {
    trace.append("stage")
    if stageFails { throw UpgradeFixtureError.storage }
    staged = authorization
    return authorization
  }
  func connect(_ options: InlineProtocolV3Options) -> any LegacyProtocolUpgradeConnection {
    if options.authorization != nil {
      recoveredPermanentCount += 1
      trace.append("recover")
    } else if !options.temporary {
      freshPermanentCount += 1
    }
    return UpgradeTestConnection(
      authorization: options.temporary ? temporary : permanent,
      harness: self
    )
  }
  func invoke(_ request: RealtimeV3Request) throws -> RealtimeV3Response {
    switch request.body {
    case let .authUpgradeSession(upgrade):
      trace.append("upgrade")
      #expect(staged != nil)
      #expect(upgrade.bearerToken == "7:legacy-fixture")
      if let upgradeResponse { return upgradeResponse }
      if loseResponse {
        loseResponse = false
        throw UpgradeFixtureError.lostResponse
      }
      return .with { $0.body = .authUpgradeSession(.with {
        $0.state = .authorized(.with {
          $0.user = .with { $0.id = 7 }
          $0.accountSessionID = 42
        })
      }) }
    case .rpc:
      trace.append("getMe")
      let userID: Int64 = wrongIdentity ? 9 : 7
      return .with { $0.body = .rpcResult(.with { $0.result = .getMe(.with {
        $0.user = .with { $0.id = userID }
      }) }) }
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }
  func record(_ value: String) { trace.append(value) }
  func commit(_ credentials: InlineProtocolSessionCredentials) {
    trace.append("commit")
    committed = credentials
  }
}

private final class UpgradeLogRecorder: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [LogEntry] = []
  private var recordedCategories: [String] = []
  var entries: [LogEntry] { lock.withLock { recorded } }
  var errorCategories: [String] { lock.withLock { recordedCategories } }
  var finished: LogEntry? {
    entries.first { $0.message.contains("outcome=prepared") || $0.message.contains("outcome=deferred") }
  }
  func clear() { lock.withLock { recorded.removeAll(); recordedCategories.removeAll() } }
  func write(_ event: LogEvent) {
    guard event.entry.scope == "Realtime.ProtocolUpgrade" else { return }
    lock.withLock {
      recorded.append(event.entry)
      if let category = (event.error as? any PrivacySafeErrorCategoryProviding)?.privacySafeErrorCategory {
        recordedCategories.append(category)
      }
    }
  }
}

private struct UpgradeTestConnection: LegacyProtocolUpgradeConnection {
  let authorization: InlineProtocolAuthorization
  let harness: UpgradeAttemptHarness
  func invoke(_ request: RealtimeV3Request) async throws -> RealtimeV3Response {
    try await harness.invoke(request)
  }
  func bindTemporary(to permanent: InlineProtocolAuthorization) async throws { await harness.record("bind") }
  func close() async {}
}
