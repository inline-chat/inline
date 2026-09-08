import AsyncAlgorithms
import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import Testing

@testable import InlineKit
@testable import RealtimeV2

@Suite("SyncTests", .serialized)
final class SyncTests {
  @Test("cursor conflict already covered durably completes without another request")
  func conflictReconcilesCoveredDemand() async throws {
    let storage = InMemorySyncStorage()
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 1))
    await storage.setBucketState(for: key, state: .init(date: 100, seq: 5))
    let apply = RecordingApplyUpdates()
    await apply.gateNextApply()
    await apply.setResult(.init(
      appliedCount: 0,
      failedCount: 1,
      failure: .cursorChanged(
        bucket: key,
        expected: .init(date: 100, seq: 5),
        actual: .init(date: 120, seq: 6)
      )
    ))
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 6, date: 120, updates: [makeChatInfoUpdate(seq: 6, date: 120)], final: true, resultType: .slice
    )])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 6)])
    await apply.waitUntilApplyGated()
    await storage.setBucketState(for: key, state: .init(date: 120, seq: 6))
    await apply.releaseApply()
    #expect(await waitForCondition {
      let stats = await sync.getStats()
      return stats.bucketApplyConflicts == 1 && stats.activeBucketFetches == 0
    })
    #expect(await client.getUpdatesStartSequences() == [5])
    #expect(await sync.getStats().bucketApplyFailures == 0)
    #expect(await sync.getStats().bucketUpdatesSkipped == 0)
    await sync.prepareForTermination()
  }

  @Test("a warm actor reloads a deleted cursor before dismissing an equal hint")
  func deletedCursorDoesNotSuppressHint() async throws {
    let storage = InMemorySyncStorage()
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 1))
    let apply = RecordingApplyUpdates()
    let response = makeGetUpdatesResult(
      seq: 1, date: 100, updates: [], final: true, resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let client = FakeProtocolClient(responses: [response, response])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    #expect(await waitForCondition {
      let stats = await sync.getStats()
      return stats.bucketFetchCount == 1 && stats.activeBucketFetches == 0
    })
    await storage.removeBucketState(for: key)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    #expect(await waitForCondition { await client.getUpdatesStartSequences().count == 2 })
    #expect(await client.getUpdatesStartSequences() == [0, 0])
    #expect(await waitForCondition { await storage.getBucketState(for: key).seq == 1 })
    await sync.prepareForTermination()
  }

  @Test("partially superseded catch-up retries from durable progress")
  func conflictRebuildsRemainingDemand() async throws {
    let storage = InMemorySyncStorage()
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 1))
    await storage.setBucketState(for: key, state: .init(date: 100, seq: 5))
    let apply = RecordingApplyUpdates()
    await apply.gateNextApply()
    await apply.setResultSequence([
      .init(appliedCount: 0, failedCount: 1, failure: .cursorChanged(
        bucket: key, expected: .init(date: 100, seq: 5), actual: .init(date: 120, seq: 6)
      )),
      .success(count: 1),
    ])
    let client = FakeProtocolClient(responses: [
      makeGetUpdatesResult(
        seq: 6,
        date: 120,
        updates: [makeChatInfoUpdate(seq: 6, date: 120)],
        final: false,
        resultType: .slice
      ),
      makeGetUpdatesResult(
        seq: 7,
        date: 130,
        updates: [makeChatInfoUpdate(seq: 7, date: 130)],
        final: true,
        resultType: .slice
      ),
    ])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 7)])
    await apply.waitUntilApplyGated()
    await storage.setBucketState(for: key, state: .init(date: 120, seq: 6))
    await apply.releaseApply()
    #expect(await waitForCondition(timeout: .seconds(4)) { await storage.getBucketState(for: key).seq == 7 })
    #expect(await client.getUpdatesStartSequences() == [5, 6])
    await sync.prepareForTermination()
  }

  @Test("queued child captures removal evidence only after acquiring a fetch slot")
  func queuedChildCapturesCurrentRemovalEvidence() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [],
      final: true,
      resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let client = FakeProtocolClient(responses: [response, response], gateFirstCall: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15, maxConcurrentBucketFetches: 1)
    )
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    await client.waitForFirstCallStarted()
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 2, updateSeq: 1)])
    #expect(await waitForCondition { await sync.getStats().activeBucketFetches == 2 })
    await storage.setRemovalRevision(1)
    await client.releaseFirstCall()
    #expect(await waitForCondition { await apply.bucketCommits.count == 2 })
    let commits = await apply.bucketCommits
    #expect(commits.first { $0.key == .chat(peer: makeChatPeer(chatId: 1)) }?.expectedRemovalRevision == 0)
    #expect(commits.first { $0.key == .chat(peer: makeChatPeer(chatId: 2)) }?.expectedRemovalRevision == 1)
    await sync.prepareForTermination()
  }

  @Test("durable progress past a frozen target completes without an invalid RPC")
  func durableOvershootRetiresFrozenTarget() async throws {
    let storage = InMemorySyncStorage()
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 1))
    await storage.setBucketState(for: key, state: .init(date: 130, seq: 7))
    let client = FakeProtocolClient(responses: [])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    let actor = BucketActor(
      key: key, seq: 5, date: 100, client: client, sync: sync,
      fetchLimiter: FetchLimiter(limit: 1), accountMutationToken: nil
    )
    await actor.setFetchTarget(upToSeq: 6)
    await actor.fetchNewUpdates()
    #expect(await actor.snapshot().seq == 7)
    #expect(await client.getUpdatesStartSequences().isEmpty)
    #expect(await sync.getStats().activeBucketFetches == 0)
    await sync.prepareForTermination()
  }

  @Test("sync config defaults")
  func testSyncConfigDefaults() {
    #expect(SyncConfig.default.lastSyncSafetyGapSeconds == 15)
    #expect(SyncConfig.default.maxConcurrentBucketFetches == 4)
  }

  @Test("retry cadence jitters fast attempts and remains bounded indefinitely")
  func testRetryCadenceBounds() {
    for (attempt, base) in [1_000, 2_000, 4_000, 5_000, 5_000, 5_000].enumerated() {
      let base = Int64(base)
      #expect(SyncRetryPolicy.delay(attempt: attempt, jitterUnit: 0) == .milliseconds(base * 8 / 10))
      #expect(SyncRetryPolicy.delay(attempt: attempt, jitterUnit: 0.5) == .milliseconds(base))
      #expect(SyncRetryPolicy.delay(attempt: attempt, jitterUnit: 1) == .milliseconds(base * 12 / 10))
    }
    for attempt in [0, 3, 100, Int.max] {
      #expect(SyncRetryPolicy.delay(attempt: attempt, rateLimited: true, jitterUnit: 0) == .seconds(60))
      #expect(SyncRetryPolicy.delay(attempt: attempt, rateLimited: true, jitterUnit: 0.5) == .seconds(70))
      #expect(SyncRetryPolicy.delay(attempt: attempt, rateLimited: true, jitterUnit: 1) == .seconds(80))
    }
  }

  @Test("only an accepted new session wakes discovery")
  func testAcceptedSessionIsSoleDiscoveryWake() async throws {
    let storage = InMemorySyncStorage()
    await storage.setState(SyncState(lastSyncDate: 100))
    let client = FakeProtocolClient(responses: [], methodResponses: [
      .getUpdatesState: [
        makeGetUpdatesStateResult(date: 120, updatesFound: false),
        makeGetUpdatesStateResult(date: 130, updatesFound: false),
      ],
    ])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { await activity.record($0) }
    await sync.connectionStateChanged(state: .connected)
    #expect(await client.getCallCount() == 0)
    await sync.acceptedSessionOpened(sessionID: 1)
    #expect(await activity.contains(true))
    #expect(await waitForCondition { await storage.getState().lastSyncDate == 105 })
    await sync.acceptedSessionOpened(sessionID: 1)
    #expect(await client.getCallCount() == 1)
    await sync.acceptedSessionOpened(sessionID: 2)
    #expect(await waitForCondition { await storage.getState().lastSyncDate == 115 })
    #expect(await client.getCallCount() == 2)
    await sync.prepareForTermination()
  }

  @Test("reconnect wakes rate-limited work without dormant bucket reads")
  func testReconnectWakesOnlyUnresolvedRuntimeBucket() async throws {
    let storage = InMemorySyncStorage()
    await storage.setState(SyncState(lastSyncDate: 100))
    var dormant: [BucketKey: BucketState] = [:]
    for id in 2 ... 10_001 {
      dormant[.chat(peer: makeChatPeer(chatId: Int64(id)))] = BucketState(date: 100, seq: 100)
    }
    await storage.setBucketStates(states: dormant)
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 120, updatesFound: false)],
        .getUpdates: [makeGetUpdatesResult(
          seq: 1, date: 120, updates: [makeChatInfoUpdate(seq: 1, date: 120)], final: true, resultType: .slice
        )],
      ],
      methodErrors: [.getUpdates: [ProtocolSessionError.rpcError(errorCode: .rateLimit, message: "rate limit", code: 429)]]
    )
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    #expect(await waitForCondition { await sync.getStats().bucketFetchFailures == 1 })
    #expect(await sync.getStats().activeBucketFetches == 1)
    await sync.acceptedSessionOpened(sessionID: 2)
    #expect(await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 1
    })
    #expect(await client.getCalledMethods().filter { $0 == .getUpdates }.count == 2)
    #expect(await storage.readBucketKeys().allSatisfy {
      $0 == .chat(peer: makeChatPeer(chatId: 1)) || $0 == .user
    })
    #expect(await sync.getStats().bucketsTracked == 1)
    await sync.prepareForTermination()
  }

  @Test("latest demand captures one fixed target across pages")
  func testLatestDemandCapturesFixedTarget() async throws {
    let storage = InMemorySyncStorage()
    let client = FakeProtocolClient(responses: [], methodResponses: [
      .getChat: [makeGetChatResult(chatId: 7, seq: 2)],
      .getUpdates: [
        makeGetUpdatesResult(seq: 1, date: 101, updates: [], final: false, resultType: .slice,
                             skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)),
        makeGetUpdatesResult(seq: 2, date: 102, updates: [], final: true, resultType: .slice,
                             skippedSequences: makeIrrelevantSkippedSequences(after: 1, through: 2)),
      ],
    ])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 0)])
    #expect(await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 7))).seq == 2
    })
    #expect(await client.getCalledMethods() == [.getChat, .getUpdates, .getUpdates])
    #expect(await client.getUpdatesStartSequences() == [0, 1])
    #expect(await client.getUpdatesEndSequences() == [2, 2])
    #expect(await sync.getStats().queuedDiscoveryTargets == 0)
    await sync.prepareForTermination()
  }

  @Test("latest arriving during a finite pass cannot borrow its completion")
  func testLatestDemandDoesNotBorrowEarlierFinitePass() async throws {
    let storage = InMemorySyncStorage()
    let client = FakeProtocolClient(responses: [], gateCallNumbers: [1, 2], methodResponses: [
      .getChat: [makeGetChatResult(chatId: 7, seq: 2)],
      .getUpdates: [
        makeGetUpdatesResult(seq: 1, date: 101, updates: [], final: true, resultType: .slice,
                             skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)),
        makeGetUpdatesResult(seq: 2, date: 102, updates: [], final: true, resultType: .slice,
                             skippedSequences: makeIrrelevantSkippedSequences(after: 1, through: 2)),
      ],
    ])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 1)])
    await client.waitForFirstCallStarted()
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 0)])
    await client.releaseCall(1)
    await client.waitForCallStarted(2)
    #expect(await client.getCalledMethods() == [.getUpdates, .getChat])
    #expect(await sync.getStats().queuedDiscoveryTargets == 1)
    await client.releaseCall(2)
    #expect(await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 7))).seq == 2
    })
    #expect(await client.getUpdatesEndSequences() == [1, 2])
    #expect(await sync.getStats().queuedDiscoveryTargets == 0)
    await sync.prepareForTermination()
  }

  @Test("initial child page carries removal evidence independently of User traffic")
  func testInitialChildPageCarriesUserAdmissionFence() async throws {
    let storage = InMemorySyncStorage()
    await storage.setBucketState(for: .user, state: BucketState(date: 100, seq: 4))
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 1, date: 110, updates: [], final: true, resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )], gateFirstCall: true)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 1)])
    await client.waitForFirstCallStarted()
    // Ordinary User progress must not change the destructive revision captured
    // before this RPC. The real writer tests also verify admission.
    await storage.setBucketState(for: .user, state: BucketState(date: 120, seq: 5))
    await client.releaseFirstCall()
    #expect(await waitForCondition { await apply.bucketCommits.count == 1 })
    let commit = try #require(await apply.bucketCommits.first)
    #expect(commit.expectedRemovalRevision == 0)
    await sync.prepareForTermination()
  }

  @Test("duplicate live update satisfies its already-durable active discovery target")
  func testDuplicateLiveUpdateDoesNotPinDiscovery() async throws {
    let storage = InMemorySyncStorage()
    await storage.setState(SyncState(lastSyncDate: 10))
    await storage.setBucketState(for: .chat(peer: makeChatPeer(chatId: 1)), state: BucketState(date: 20, seq: 5))
    let client = FakeProtocolClient(responses: [], gateFirstCall: true, methodResponses: [
      .getUpdatesState: [makeGetUpdatesStateResult(date: 60, updatesFound: false)],
    ])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    await sync.acceptedSessionOpened(sessionID: 1)
    await client.waitForFirstCallStarted()
    await sync.process(updates: [makeChatInfoUpdate(seq: 5, date: 20)])
    await client.releaseFirstCall()
    #expect(await waitForCondition { await storage.getState().lastSyncDate == 45 })
    #expect(await client.getCalledMethods() == [.getUpdatesState])
    #expect(await sync.getStats().discoveryTargetsPending == 0)
    await sync.prepareForTermination()
  }

  @Test("contiguous live suffix arriving during apply drains without a catch-up RPC")
  func testContiguousLiveSuffixDuringApplyStaysLocal() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.gateNextApply()
    let client = FakeProtocolClient(responses: [])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    let first = Task { await sync.process(updates: [makeChatInfoUpdate(seq: 1, date: 100)]) }
    await apply.waitUntilApplyGated()
    await sync.process(updates: [makeChatInfoUpdate(seq: 2, date: 101)])
    await apply.releaseApply()
    await first.value
    #expect(await apply.appliedUpdates.map(\.seq) == [1, 2])
    #expect(await client.getCallCount() == 0)
    #expect(await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 2)
    await sync.prepareForTermination()
  }

  @Test("snapshot rejects an invalidated account lease before actor or RPC work")
  func testSnapshotRejectsStaleAccountLease() async throws {
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()
    let storage = InMemorySyncStorage()
    let client = FakeProtocolClient(responses: [])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client,
                    config: .default, auth: auth.handle)
    await sync.activateGeneration()
    _ = try auth.beginLogoutSynchronously()
    do {
      try await sync.installSnapshotOutcome(seededStates: [:], catchUpTargets: [.space(id: 10): 5], expectedAccount: token)
      Issue.record("stale account snapshot was admitted")
    } catch {}
    #expect(await client.getCallCount() == 0)
    #expect(await sync.getStats().bucketsTracked == 0)
    await sync.prepareForTermination()
  }

  @Test("realtime config store returns sync defaults")
  func testRealtimeConfigStoreInitialConfig() {
    let config = RealtimeConfigStore.initialSyncConfig()
    #expect(config.lastSyncSafetyGapSeconds == SyncConfig.default.lastSyncSafetyGapSeconds)
    #expect(config.maxConcurrentBucketFetches == SyncConfig.default.maxConcurrentBucketFetches)
  }

  @Test("bucket commits dynamically dispatch through the apply-updates owner")
  func testBucketCommitExistentialDispatch() async {
    let recorder = BucketCommitApplyRecorder()
    let owner: any ApplyUpdates = recorder
    let commit = UpdateBucketCommit(
      key: .space(id: 42),
      state: BucketState(date: 100, seq: 7)
    )

    let result = await owner.apply(
      updates: [],
      source: .syncCatchup,
      sidecars: nil,
      bucketCommit: commit
    )

    #expect(result.committedBucketState?.seq == commit.state.seq)
    #expect(result.committedBucketState?.date == commit.state.date)
    let received = await recorder.receivedCommit()
    #expect(received?.seq == commit.state.seq)
    #expect(received?.date == commit.state.date)
  }

  @Test("direct bucket updates do not advance the discovery checkpoint")
  func testDirectBucketUpdatePreservesDiscoveryCheckpoint() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    var status = InlineProtocol.UpdateUserStatus()
    status.userID = 1
    var userStatus = InlineProtocol.UserStatus()
    userStatus.online = .online
    status.status = userStatus

    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 100
    update.update = .updateUserStatus(status)

    await sync.process(updates: [update])

    let state = await storage.getState()
    #expect(state.lastSyncDate == 0)
  }

  @Test("account mutation token reaches direct, sequenced, and catch-up apply boundaries")
  func testAccountMutationTokenPropagation() async throws {
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()

    let directRecorder = RecordingApplyUpdates()
    let directSync = Sync(
      applyUpdates: directRecorder,
      syncStorage: InMemorySyncStorage(),
      client: FakeProtocolClient(responses: []),
      config: .default,
      auth: auth.handle
    )
    await directSync.process(
      updates: [makeNewMessageUpdate(seq: 0, date: 100)],
      mutationToken: token
    )
    #expect(await directRecorder.receivedMutationTokens().contains(token))

    let sequencedRecorder = RecordingApplyUpdates()
    let sequencedSync = Sync(
      applyUpdates: sequencedRecorder,
      syncStorage: InMemorySyncStorage(),
      client: FakeProtocolClient(responses: []),
      config: .default,
      auth: auth.handle
    )
    await sequencedSync.process(
      updates: [makeChatInfoUpdate(seq: 1, date: 101)],
      mutationToken: token
    )
    #expect(await sequencedRecorder.receivedMutationTokens().contains(token))

    let catchupRecorder = RecordingApplyUpdates()
    let catchupUpdate = makeChatInfoUpdate(seq: 1, date: 102)
    let catchupClient = FakeProtocolClient(responses: [
      makeGetUpdatesResult(
        seq: 1,
        date: 102,
        updates: [catchupUpdate],
        final: true,
        resultType: .slice
      ),
    ])
    let catchupSync = Sync(
      applyUpdates: catchupRecorder,
      syncStorage: InMemorySyncStorage(),
      client: catchupClient,
      config: .default,
      auth: auth.handle
    )
    await catchupSync.activateGeneration()
    await catchupSync.process(
      updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)]
    )
    _ = await waitForCondition {
      await catchupRecorder.appliedUpdates.isEmpty == false
    }
    #expect(await catchupRecorder.receivedMutationTokens().contains(token))
  }

  @Test("coalesces bucket fetches while in-flight")
  func testCoalescedFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let firstResponse = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let secondResponse = makeGetUpdatesResult(
      seq: 2,
      date: 101,
      updates: [],
      final: true,
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 1, through: 2)
    )

    let client = FakeProtocolClient(responses: [firstResponse, secondResponse], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let chatId: Int64 = 1
    let firstSignal = makeChatHasNewUpdatesSignal(chatId: chatId, updateSeq: 1)
    async let firstProcess: Void = sync.process(updates: [firstSignal])
    await client.waitForFirstCallStarted()

    let secondSignal = makeChatHasNewUpdatesSignal(chatId: chatId, updateSeq: 2)
    await sync.process(updates: [secondSignal])
    _ = await waitForCondition {
      let stats = await sync.getStats()
      return stats.bucketFetchFollowups == 1
    }

    await client.releaseFirstCall()
    await firstProcess
    _ = await waitForCondition {
      await client.getCallCount() == 2
    }

    let callCount = await client.getCallCount()
    #expect(callCount == 2)
  }

  @Test("stale hasNewUpdates hint does not trigger fetch")
  func testStaleHasNewUpdatesDoesNotFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    // If a fetch happens unexpectedly, this response makes it complete (instead of retrying).
    let response = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: true,
      resultType: .empty
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100)],
        .getUpdates: [response],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 150, seq: 10))

    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 10 // stale (<= current)

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])

    let fetchStarted = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 0
    }
    #expect(fetchStarted == false)
    #expect(await client.getCallCount() == 0)
  }

  @Test("sequenced chatInfo updates advance bucket state")
  func testSequencedChatInfoAdvancesBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    var payload = InlineProtocol.UpdateChatInfo()
    payload.chatID = 1
    payload.title = "New Title"

    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 100
    update.update = .chatInfo(payload)

    await sync.process(updates: [update])

    let peer = makeChatPeer(chatId: 1)
    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 1)
    #expect(bucketState.date == 100)
  }

  @Test("sequenced chat permission updates advance user bucket state")
  func testSequencedChatPermissionsAdvanceUserBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    var permissions = InlineProtocol.ChatPermissions()
    permissions.canUpdateInfo = true
    var payload = InlineProtocol.UpdateChatPermissions()
    payload.chatID = 1
    payload.permissions = permissions

    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 100
    update.update = .chatPermissions(payload)

    await sync.process(updates: [update])

    let bucketState = await storage.getBucketState(for: .user)
    #expect(bucketState.seq == 1)
    #expect(bucketState.date == 100)
  }

  @Test("sequenced durable user updates advance the user bucket")
  func testSequencedDurableUserUpdateAdvancesUserBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    var payload = InlineProtocol.UpdateMessageActionAnswered()
    payload.interactionID = 42
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 100
    update.update = .messageActionAnswered(payload)

    await sync.process(updates: [update])

    #expect(await apply.appliedUpdates.count == 1)
    let bucketState = await storage.getBucketState(for: .user)
    #expect(bucketState.seq == 1)
    #expect(bucketState.date == 100)
  }

  @Test("sequenced space settings advance the space bucket")
  func testSequencedSpaceSettingsAdvanceSpaceBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    var payload = InlineProtocol.UpdateSpaceSettings()
    payload.spaceID = 10
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 100
    update.update = .spaceSettings(payload)

    await sync.process(updates: [update])

    #expect(await apply.appliedUpdates.count == 1)
    let bucketState = await storage.getBucketState(for: .space(id: 10))
    #expect(bucketState.seq == 1)
    #expect(bucketState.date == 100)
  }

  @Test("message updates apply during catch-up")
  func testMessageUpdatesApplyDuringCatchUp() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let messageUpdate = makeNewMessageUpdate(seq: 1, date: 100)
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [messageUpdate],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100)],
        .getUpdates: [response],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 1

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
  }

  @Test("message updates apply from chat bucket hints")
  func testMessageUpdatesApplyFromChatBucketHints() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let messageUpdate = makeNewMessageUpdate(seq: 1, date: 100)
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [messageUpdate],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100)],
        .getUpdates: [response],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 1

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    _ = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
  }

  @Test("chatSkipPts applies during catch-up and advances bucket")
  func testChatSkipPtsCatchupAdvancesBucket() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let skip = makeChatSkipPtsUpdate(seq: 1, date: 100, chatId: 1)
    let message = makeNewMessageUpdate(seq: 2, date: 110)
    let response = makeGetUpdatesResult(
      seq: 2,
      date: 110,
      updates: [skip, message],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 2)
    await sync.process(updates: [signal])

    _ = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 2
    }

    let applied = await apply.appliedUpdates
    #expect(applied.map { Int($0.seq) } == [1, 2])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
    #expect(bucketState.date == 110)
  }

  @Test("sync activity callback toggles during full sync fetch")
  func testSyncActivityCallbackTogglesDuringFullSyncFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let client = FakeProtocolClient(responses: [response], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)
    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { isActive in
      await activity.record(isActive)
    }

    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = makeChatPeer(chatId: 1)
    payload.updateSeq = 1

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    await client.waitForFirstCallStarted()

    let didEnterUpdating = await waitForCondition(timeout: .seconds(1)) {
      await activity.contains(true)
    }
    #expect(didEnterUpdating)

    await client.releaseFirstCall()
    let didLeaveUpdating = await waitForCondition(timeout: .seconds(1)) {
      await activity.sequence == [true, false]
    }
    #expect(didLeaveUpdating)
  }

  @Test("sync activity callback stays active during bucket fetch")
  func testSyncActivityCallbackStaysActiveDuringBucketFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let client = FakeProtocolClient(responses: [response], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)
    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { isActive in
      await activity.record(isActive)
    }

    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = makeChatPeer(chatId: 1)
    payload.updateSeq = 1

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    await client.waitForFirstCallStarted()

    let didEnterUpdating = await waitForCondition(timeout: .seconds(1)) {
      await activity.contains(true)
    }
    #expect(didEnterUpdating)

    await client.releaseFirstCall()
    let didLeaveUpdating = await waitForCondition(timeout: .seconds(1)) {
      await activity.sequence == [true, false]
    }
    #expect(didLeaveUpdating)
  }

  @Test("sync activity stays active when config changes during fetch")
  func testSyncActivityStaysActiveWhenConfigChangesDuringFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let client = FakeProtocolClient(responses: [response], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)
    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { isActive in
      await activity.record(isActive)
    }

    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = makeChatPeer(chatId: 1)
    payload.updateSeq = 1

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    await client.waitForFirstCallStarted()

    let didEnterUpdating = await waitForCondition(timeout: .seconds(1)) {
      await activity.contains(true)
    }
    #expect(didEnterUpdating)

    await sync.updateConfig(SyncConfig(lastSyncSafetyGapSeconds: 15))
    let didLeaveBeforeFetchCompleted = await waitForCondition(timeout: .milliseconds(200)) {
      await activity.sequence == [true, false]
    }
    #expect(didLeaveBeforeFetchCompleted == false)

    await client.releaseFirstCall()
    let didLeaveAfterFetch = await waitForCondition(timeout: .seconds(1)) {
      await activity.sequence == [true, false]
    }
    #expect(didLeaveAfterFetch)
  }

  @Test("warm chat TOO_LONG repairs an authoritative snapshot")
  func testWarmChatTooLongRepairsAndAdvances() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [
          tooLong,
          makeGetUpdatesResult(
            seq: 12,
            date: 220,
            updates: [],
            final: true,
            resultType: .empty
          ),
        ],
        .getChat: [makeGetChatResult(chatId: 1, seq: 10)],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: config,
      auth: auth.handle
    )
    await sync.activateGeneration()

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 150, seq: 5))
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 10

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    _ = await waitForCondition { await apply.repairedChats.count == 1 }

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let repaired = await apply.repairedChats
    #expect(repaired.first?.reason == "too_long")

    let callCount = await client.getCallCount()
    #expect(callCount == 2)

    let methods = await client.getCalledMethods()
    #expect(methods == [.getUpdates, .getChat])
    #expect(await client.getChatRecentMessageRequests() == [true])

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
  }

  @Test("cold chat TOO_LONG repairs chat snapshot and advances")
  func testColdChatTooLongRepairsAndAdvances() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [tooLong],
        // Pin state is independent from the bounded 100-message repair window.
        .getChat: [makeGetChatResult(
          chatId: 1,
          seq: 10,
          pinnedMessageIds: (1 ... 101).map(Int64.init)
        )],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: config,
      auth: auth.handle
    )
    await sync.activateGeneration()

    let peer = makeChatPeer(chatId: 1)
    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 10)
    await sync.process(updates: [signal])
    _ = await waitForCondition {
      await apply.repairedChats.count == 1
    }

    let repaired = await apply.repairedChats
    #expect(repaired.count == 1)
    let snapshot = try #require(repaired.first)
    #expect(snapshot.reason == "too_long")
    #expect(snapshot.pinnedMessages.isEmpty)
    #expect(snapshot.chat.pinnedMessageIds.count == 101)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let callCount = await client.getCallCount()
    #expect(callCount == 2)

    let methods = await client.getCalledMethods()
    #expect(methods == [.getUpdates, .getChat])
  }

  @Test("chat TOO_LONG retains its cursor when authoritative repair fails")
  func testChatTooLongRetainsCursorWhenRepairFails() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [tooLong],
        .getChat: [nil],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: config,
      auth: auth.handle
    )
    await sync.activateGeneration()

    let peer = makeChatPeer(chatId: 1)
    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 10)
    await sync.process(updates: [signal])

    _ = await waitForCondition { await client.getCallCount() == 2 }

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 0)
    #expect(bucketState.date == 0)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let callCount = await client.getCallCount()
    #expect(callCount == 2)
    await sync.prepareForTermination()
  }

  @Test("chat TOO_LONG rejects a metadata-only response that omits the current tail")
  func testChatTooLongRejectsMissingRecentWindow() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 10,
          date: 200,
          updates: [],
          final: false,
          resultType: .tooLong
        )],
        .getChat: [makeGetChatResult(chatId: 1, seq: 10, lastMessageId: 99)],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: Auth.mocked(authenticated: true).handle
    )
    await sync.activateGeneration()

    let peer = makeChatPeer(chatId: 1)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 10)])
    #expect(await waitForCondition { await client.getCallCount() == 2 })
    #expect(await apply.repairedChats.isEmpty)
    #expect(await storage.getBucketState(for: .chat(peer: peer)).seq == 0)
    #expect(await client.getChatRecentMessageRequests() == [true])
    await sync.prepareForTermination()
  }

  @Test("space TOO_LONG repairs its authoritative snapshot and advances")
  func testSpaceTooLongRepairsAndAdvances() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    await storage.setBucketState(
      for: .space(id: 10),
      state: BucketState(date: 150, seq: 5)
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 10,
          date: 200,
          updates: [],
          final: false,
          resultType: .tooLong
        )],
        .getSpace: [makeGetSpaceResult(spaceId: 10, seq: 10)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.process(updates: [makeSpaceHasNewUpdatesSignal(spaceId: 10, updateSeq: 10)])
    let repaired = await waitForCondition { await apply.repairedSpaces.count == 1 }

    #expect(repaired)
    let repairs = await apply.repairedSpaces
    let repair = try #require(repairs.first)
    #expect(repair.reason == "too_long")
    #expect(repair.targetState.date == 200)
    #expect(repair.targetState.seq == 10)
    let bucketState = await storage.getBucketState(for: .space(id: 10))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)
    let methods = await client.getCalledMethods()
    #expect(methods.first == .getUpdates)
    #expect(methods == [.getUpdates, .getSpace])
  }

  @Test("space TOO_LONG retains its cursor when authoritative repair fails")
  func testSpaceTooLongRetainsCursorWhenRepairFails() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    await apply.setRepairResult(false)
    await storage.setBucketState(
      for: .space(id: 10),
      state: BucketState(date: 150, seq: 5)
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 10,
          date: 200,
          updates: [],
          final: false,
          resultType: .tooLong
        )],
        .getSpace: [makeGetSpaceResult(spaceId: 10, seq: 10)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.process(updates: [makeSpaceHasNewUpdatesSignal(spaceId: 10, updateSeq: 10)])
    let attempted = await waitForCondition { await apply.repairedSpaces.count == 1 }

    #expect(attempted)
    let bucketState = await storage.getBucketState(for: .space(id: 10))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 150)
    await sync.prepareForTermination()
  }

  @Test("user TOO_LONG captures state before fetching account projections")
  func testUserTooLongCapturesStateBeforeSnapshot() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    var user = InlineProtocol.User()
    user.id = 42
    var me = InlineProtocol.GetMeResult()
    me.user = user
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [
          tooLong,
          makeGetUpdatesResult(
            seq: 14,
            date: 230,
            updates: [],
            final: true,
            resultType: .slice,
            skippedSequences: makeIrrelevantSkippedSequences(after: 12, through: 14)
          ),
        ],
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 220, seq: 12),
          makeGetUpdatesStateResult(date: 230, seq: 14),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )
    await sync.activateGeneration()

    let trigger = makeDurableUpdate(seq: 10, date: 200, payload: .updatedUser(.init()))
    await sync.process(updates: [trigger])
    let repaired = await waitForCondition {
      let repairCount = await apply.repairedUsers.count
      let callCount = await client.getCallCount()
      let state = await storage.getBucketState(for: .user)
      return repairCount == 1 && callCount == 7 && state.seq == 14
    }

    #expect(repaired)
    let repairs = await apply.repairedUsers
    let snapshot = try #require(repairs.first)
    #expect(snapshot.targetState.date == 200)
    #expect(snapshot.targetState.seq == 10)
    #expect(snapshot.checkpointState.date == 220)
    #expect(snapshot.checkpointState.seq == 12)
    #expect(snapshot.replayThroughState?.date == 230)
    #expect(snapshot.replayThroughState?.seq == 14)
    #expect(snapshot.replacesActiveCatalog)
    let storedState = await storage.getBucketState(for: .user)
    #expect(storedState.date == 230)
    #expect(storedState.seq == 14)
    let methods = await client.getCalledMethods()
    #expect(Array(methods.prefix(2)) == [.getUpdates, .getUpdatesState])
    #expect(Set(methods[2 ... 4]) == Set([.getChats, .getMe, .getUserSettings]))
    #expect(Array(methods.suffix(2)) == [.getUpdatesState, .getUpdates])
    #expect(await client.getUpdatesStateDates() == [nil, nil])
    #expect(await client.getUpdatesStartSequences() == [0, 12])
    #expect(await client.getUpdatesEndSequences() == [10, 14])
    await sync.prepareForTermination()
  }

  @Test("user TOO_LONG rejects a post-projection checkpoint behind its first checkpoint")
  func testUserTooLongRejectsRegressedReplayBound() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)

    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 42 }
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 10,
          date: 200,
          updates: [],
          final: false,
          resultType: .tooLong
        )],
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 220, seq: 12),
          makeGetUpdatesStateResult(date: 219, seq: 11),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: .default,
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.process(updates: [
      makeDurableUpdate(seq: 10, date: 200, payload: .updatedUser(.init())),
    ])
    #expect(await waitForCondition { await client.getCallCount() == 6 })
    #expect(await apply.repairedUsers.isEmpty)
    let stored = await storage.getBucketState(for: .user)
    #expect(stored.date == 0)
    #expect(stored.seq == 0)
    let methods = await client.getCalledMethods()
    #expect(Array(methods.suffix(1)) == [.getUpdatesState])
    await sync.prepareForTermination()
  }

  @Test("account catalog rebase retires only its exact omitted bucket actor")
  func testUserTooLongRetiresExactCatalogBucketActor() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let retiredKey = BucketKey.chat(peer: makeChatPeer(chatId: 1))
    let retainedKey = BucketKey.chat(peer: makeChatPeer(chatId: 2))
    await apply.setUserRepairOutcome(.applied(
      state: BucketState(date: 220, seq: 12),
      seededStates: [:],
      replayThroughState: nil,
      retiredBucketKeys: [retiredKey]
    ))

    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 42 }
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 10,
          date: 200,
          updates: [],
          final: false,
          resultType: .tooLong
        )],
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 220, seq: 12),
          makeGetUpdatesStateResult(date: 220, seq: 12),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: .default,
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.process(updates: [
      makeChatInfoUpdate(seq: 1, date: 100, chatId: 1),
      makeChatInfoUpdate(seq: 1, date: 100, chatId: 2),
    ])
    #expect(await waitForCondition {
      let stats = await sync.getStats()
      let keys = Set(stats.buckets.map(\.key))
      return keys.contains(retiredKey) && keys.contains(retainedKey)
    })

    await sync.process(updates: [
      makeDurableUpdate(seq: 10, date: 200, payload: .updatedUser(.init())),
    ])
    #expect(await waitForCondition {
      let stats = await sync.getStats()
      let keys = Set(stats.buckets.map(\.key))
      return !keys.contains(retiredKey) && keys.contains(retainedKey)
    })
    #expect(await storage.getBucketState(for: retiredKey).seq == 1)
    #expect(await storage.getBucketState(for: retainedKey).seq == 1)
    await sync.prepareForTermination()
  }

  @Test("user repair waits for exact child targets before advancing its cursor")
  func testUserRepairFinalizationWaitsForChildTargets() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()
    let childKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    let finalization = UserRepairFinalization(
      expectedUserState: BucketState(date: 0, seq: 0),
      expectedUserStateExists: false,
      proposedUserState: BucketState(date: 220, seq: 12),
      // Zero is the explicit latest/authoritative target; it must not be
      // treated as already satisfied by the child's current cursor.
      catchUpTargets: [childKey: 0],
      mutationToken: token
    )
    await apply.setUserRepairOutcome(.pending(finalization: finalization, seededStates: [:]))

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    let childPage = makeGetUpdatesResult(
      seq: 2,
      date: 210,
      updates: [],
      final: true,
      resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 2)
    )
    var user = InlineProtocol.User()
    user.id = 42
    var me = InlineProtocol.GetMeResult()
    me.user = user
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [tooLong, childPage],
        .getChat: [makeGetChatResult(chatId: 7, seq: 2)],
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 220, seq: 12),
          makeGetUpdatesStateResult(date: 220, seq: 12),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: .default,
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.process(updates: [makeDurableUpdate(seq: 10, date: 200, payload: .updatedUser(.init()))])
    let finalized = await waitForCondition {
      await storage.getBucketState(for: .user).seq == 12
    }

    #expect(finalized)
    #expect(await storage.getBucketState(for: childKey).seq == 2)
    #expect(await apply.repairedUsers.count == 1)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdates }.count == 2)
    #expect(await client.getUpdatesStartSequences() == [0, 0])
  }

  @Test("failed user finalization retries retained evidence without another User fetch")
  func testFailedUserRepairFinalizationSchedulesRetry() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    await apply.setFinalizeUserRepairResult(false)
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()
    let childKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    let finalization = UserRepairFinalization(
      expectedUserState: BucketState(date: 0, seq: 0),
      expectedUserStateExists: false,
      proposedUserState: BucketState(date: 230, seq: 12),
      catchUpTargets: [childKey: 5],
      mutationToken: token
    )
    await apply.setUserRepairOutcome(.pending(finalization: finalization, seededStates: [:]))

    var user = InlineProtocol.User()
    user.id = 42
    var me = InlineProtocol.GetMeResult()
    me.user = user
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [
          makeGetUpdatesResult(
            seq: 10,
            date: 200,
            updates: [],
            final: false,
            resultType: .tooLong
          ),
          makeGetUpdatesResult(
            seq: 5,
            date: 210,
            updates: [],
            final: true,
            resultType: .slice,
            skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 5)
          ),
          makeGetUpdatesResult(
            seq: 12,
            date: 230,
            updates: [],
            final: true,
            resultType: .slice,
            skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 12)
          ),
        ],
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 230, seq: 12),
          makeGetUpdatesStateResult(date: 230, seq: 12),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: .default,
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.process(updates: [makeDurableUpdate(seq: 10, date: 200, payload: .updatedUser(.init()))])
    #expect(await waitForCondition { await apply.finalizationAttempts > 0 })
    await apply.setFinalizeUserRepairResult(true)
    let recovered = await waitForCondition(timeout: .seconds(4)) {
      await storage.getBucketState(for: .user).seq == 12
    }

    #expect(recovered)
    #expect(await storage.getBucketState(for: childKey).seq == 5)
    #expect(await client.getUpdatesStartSequences() == [0, 0])
    #expect(await waitForCondition {
      let stats = await sync.getStats()
      return stats.queuedDiscoveryTargets == 0 && stats.discoveryTargetsPending == 0 && stats.activeBucketFetches == 0
    })
    await sync.prepareForTermination()
  }

  @Test("inaccessible finite repair child re-admits the account without faking child progress")
  func testInaccessibleFiniteUserRepairChildRestartsProjection() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()
    let childKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    await storage.setBucketState(for: childKey, state: BucketState(date: 100, seq: 2))
    await apply.setUserRepairOutcome(.pending(finalization: UserRepairFinalization(
      expectedUserState: BucketState(date: 0, seq: 0), expectedUserStateExists: false,
      proposedUserState: BucketState(date: 220, seq: 12), catchUpTargets: [childKey: 5], mutationToken: token
    ), seededStates: [:]))
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = token.userID }
    let client = FakeProtocolClient(responses: [], methodResponses: [
      .getUpdates: [makeGetUpdatesResult(seq: 10, date: 200, updates: [], final: false, resultType: .tooLong)],
      .getUpdatesState: [
        makeGetUpdatesStateResult(date: 220, seq: 12),
        makeGetUpdatesStateResult(date: 220, seq: 12),
        makeGetUpdatesStateResult(date: 230, seq: 12),
      ],
      .getChats: [.getChats(.init()), .getChats(.init())],
      .getMe: [.getMe(me), .getMe(me)],
      .getUserSettings: [.getUserSettings(.init()), .getUserSettings(.init())],
    ])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default, auth: auth.handle)
    await sync.activateGeneration()
    // Gate just the child response so the first user TOO_LONG can succeed.
    await client.setError(afterGetUpdatesCalls: 1, error: .rpcError(errorCode: .peerIDInvalid, message: "no access", code: 400))
    await sync.process(updates: [makeDurableUpdate(seq: 10, date: 200, payload: .updatedUser(.init()))])
    #expect(await waitForCondition { await client.getCalledMethods().filter { $0 == .getUpdates }.count == 2 })
    await apply.setUserRepairOutcome(.applied(
      state: BucketState(date: 230, seq: 12),
      seededStates: [:],
      replayThroughState: nil,
      retiredBucketKeys: []
    ))
    #expect(await waitForCondition(timeout: .seconds(4)) { await storage.getBucketState(for: .user).seq == 12 })
    #expect(await storage.getBucketState(for: childKey).seq == 2)
    #expect(await waitForCondition {
      let stats = await sync.getStats()
      return stats.queuedDiscoveryTargets == 0 && stats.discoveryTargetsPending == 0 && stats.activeBucketFetches == 0
    })
    #expect(await apply.repairedUsers.count == 2)
    await sync.prepareForTermination()
  }

  @Test("new demand during inactive publication receives a successor fetch")
  func testDemandDuringInactivePublicationIsNotStranded() async throws {
    let storage = InMemorySyncStorage()
    let client = FakeProtocolClient(responses: [
      makeGetUpdatesResult(seq: 1, date: 100, updates: [], final: true, resultType: .slice,
                           skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)),
      makeGetUpdatesResult(seq: 2, date: 101, updates: [], final: true, resultType: .slice,
                           skippedSequences: makeIrrelevantSkippedSequences(after: 1, through: 2)),
    ])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    let gate = InactiveSyncActivityGate()
    await sync.setSyncActivityListener { await gate.record($0) }
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    await gate.waitUntilInactive()
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 2)])
    await gate.release()
    #expect(await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 2
    })
    #expect(await client.getUpdatesEndSequences() == [1, 2])
    await sync.prepareForTermination()
  }

  @Test("transient cursor load failure retries only the exact target")
  func testTransientBucketStateLoadRetainsRetryOwner() async throws {
    let base = InMemorySyncStorage()
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    let storage = TransientBucketReadFailureStorage(base: base, failingKey: key)
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 1, date: 100, updates: [], final: true, resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 1)])
    #expect(await waitForCondition { await base.getBucketState(for: key).seq == 1 })
    // Two child reads (failed + retry) and one user-admission capture before
    // the initial child page. No inventory reads are involved.
    #expect(await storage.attempts == 3)
    #expect(await client.getCalledMethods() == [.getUpdates])
    await sync.prepareForTermination()
  }

  @Test("malformed TOO_LONG cannot fast-forward a bucket")
  func testMalformedTooLongCannotFastForward() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let tooLong = makeGetUpdatesResult(
      seq: 5,
      date: 500,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    let client = FakeProtocolClient(responses: [tooLong])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 150, seq: 5))
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 6

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    _ = await waitForCondition { await client.getCallCount() == 1 }

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let callCount = await client.getCallCount()
    #expect(callCount == 1)
    await sync.prepareForTermination()
  }

  @Test("getUpdatesState response with missing child hints cannot borrow a user target", arguments: [Int32(0), Int32(10)])
  func testGetUpdatesStateWithUpdatesDoesNotAdvanceLastSyncDate(userSeq: Int32) async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let now = Int64(Date().timeIntervalSince1970)
    let initialDate = now - 60
    await storage.setState(SyncState(lastSyncDate: initialDate))

    let getUpdatesState = makeGetUpdatesStateResult(date: now, updatesFound: true, seq: userSeq)

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [getUpdatesState, getUpdatesState],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.acceptedSessionOpened(sessionID: 1)
    let didRetryState = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.filter { $0 == .getUpdatesState }.count == 2
    }
    #expect(didRetryState)

    let state = await storage.getState()
    #expect(state.lastSyncDate == initialDate)
    #expect(await client.getCalledMethods().allSatisfy { $0 == .getUpdatesState })
    await sync.prepareForTermination()
  }

  @Test("discovery checkpoint waits for every hinted bucket to apply")
  func testDiscoveryCheckpointWaitsForHintedBucketApplication() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResult(UpdateApplyResult(appliedCount: 0, failedCount: 1))
    await apply.setRepairResult(false)
    await storage.setState(SyncState(lastSyncDate: 10))

    let failedChatUpdate = makeChatInfoUpdate(seq: 1, date: 100)
    let client = FakeProtocolClient(
      responses: [],
      gateMethods: [.getUpdatesState],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 120, updatesFound: true)],
        .getUpdates: [
          makeGetUpdatesResult(
            seq: 1,
            date: 100,
            updates: [failedChatUpdate],
            final: true,
            resultType: .slice
          ),
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    try #require(await waitForCondition {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState)
    })
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    let attemptedHintedUpdate = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }
    #expect(attemptedHintedUpdate)
    await client.releaseMethod(.getUpdatesState)
    let didDiscover = await waitForCondition {
      await client.getCalledMethods().contains(.getUpdatesState)
    }

    #expect(didDiscover)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(await storage.getState().lastSyncDate == 10)
    #expect(await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 0)
    await sync.prepareForTermination()
  }

  @Test("non-fresh checkpoint retries a transient global cursor write failure")
  func testNonFreshCheckpointRetriesGlobalWriteFailure() async throws {
    let storage = InMemorySyncStorage()
    await storage.setState(SyncState(lastSyncDate: 10))
    await storage.failNextStateWrites(1)
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, updatesFound: false),
          makeGetUpdatesStateResult(date: 101, updatesFound: false),
        ],
        .getUpdates: [makeGetUpdatesResult(
          seq: 0,
          date: 10,
          updates: [],
          final: true,
          resultType: .empty
        )],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 86
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2)
    await sync.prepareForTermination()
  }

  @Test("empty getUpdatesState response advances lastSyncDate")
  func testEmptyGetUpdatesStateAdvancesLastSyncDate() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let now = Int64(Date().timeIntervalSince1970)
    let initialDate = now - 60
    await storage.setState(SyncState(lastSyncDate: initialDate))

    let getUpdatesState = makeGetUpdatesStateResult(date: now, updatesFound: false)
    let getUpdates = makeGetUpdatesResult(
      seq: 0,
      date: now,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [getUpdatesState],
        .getUpdates: [getUpdates],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.acceptedSessionOpened(sessionID: 1)
    let didAdvance = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == max(0, now - 15)
    }
    #expect(didAdvance)
  }

  @Test("catch-up applies updates in seq order")
  func testCatchupOrdersUpdatesBySeq() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let update3 = makeNewMessageUpdate(seq: 3, date: 100)
    let update1 = makeNewMessageUpdate(seq: 1, date: 80)
    let update2 = makeNewMessageUpdate(seq: 2, date: 90)

    let response = makeGetUpdatesResult(
      seq: 3,
      date: 100,
      updates: [update3, update1, update2],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 3

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    _ = await waitForCondition {
      await apply.appliedUpdates.count == 3
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    #expect(seqs == [1, 2, 3])
  }

  @Test("direct updates advance bucket state")
  func testDirectUpdateAdvancesBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 42)
    var payload = InlineProtocol.UpdateDeleteMessages()
    payload.peerID = peer
    payload.messageIds = [1]

    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 100
    update.update = .deleteMessages(payload)

    await sync.process(updates: [update])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 1)
    #expect(bucketState.date == 100)
  }

  @Test("sync config update does not disable existing buckets")
  func testSyncConfigUpdateDoesNotDisableExistingBuckets() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 100, seq: 5))

    let messageUpdate = makeNewMessageUpdate(seq: 6, date: 120)
    let messageSlice = makeGetUpdatesResult(
      seq: 6,
      date: 120,
      updates: [messageUpdate],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [messageSlice])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let stale = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 5)
    await sync.process(updates: [stale])

    let didFetchStaleHint = await waitForCondition(timeout: .milliseconds(200)) {
      await client.getCallCount() > 0
    }
    #expect(didFetchStaleHint == false)

    await sync.updateConfig(SyncConfig(lastSyncSafetyGapSeconds: 15))

    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 6)
    await sync.process(updates: [signal])
    _ = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 6)
    #expect(bucketState.date == 120)
  }

  @Test("fresh connection captures a later bound and replays B plus one")
  func testFreshConnectionInstallsCurrentCheckpoint() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let checkpoint = makeGetUpdatesStateResult(date: 100, seq: 42)
    let update43 = makeDurableUpdate(seq: 43, date: 110, payload: .updateUserSettings(.init()))
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [checkpoint, makeGetUpdatesStateResult(date: 110, seq: 43)],
        .getUpdates: [makeGetUpdatesResult(
          seq: 43,
          date: 110,
          updates: [update43],
          final: true,
          resultType: .slice
        )],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { await activity.record($0) }
    await sync.acceptedSessionOpened(sessionID: 1)
    await Task.yield()
    let didInstallCheckpoint = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 100
    }
    #expect(didInstallCheckpoint)
    let didProbeUser = await waitForCondition(timeout: .seconds(1)) {
      await client.getCalledMethods().contains(.getUpdates)
    }
    #expect(didProbeUser)

    let methods = await client.getCalledMethods()
    #expect(methods.contains(.getUpdatesState))
    #expect(methods.contains(.getUpdates))
    #expect(await client.getUpdatesStateDates() == [nil, nil])
    #expect(await client.getUpdatesStartSequences() == [42])
    #expect(await client.getUpdatesEndSequences() == [43])
    #expect(await storage.getState().lastSyncDate == 100)
    #expect(await storage.getBucketState(for: .user).seq == 43)
    #expect(await waitForCondition {
      let sequence = await activity.sequence
      return sequence.contains(true) && sequence.last == false
    })
    #expect(await storage.getBucketState(for: .user).date == 110)
    #expect(await apply.appliedUpdates == [update43])
    #expect(await apply.bucketCommits.count == 2) // checkpoint B, then bounded (B,C] replay
    #expect(await client.getCalledMethods() == [.getUpdatesState, .getUpdatesState, .getUpdates])
    await sync.prepareForTermination()
  }

  @Test("authenticated fresh connection installs an account snapshot before its exact checkpoint")
  func testAuthenticatedFreshConnectionRepairsAccountSnapshot() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let checkpoint = makeGetUpdatesStateResult(date: 100, seq: 42)
    let replayThrough = makeGetUpdatesStateResult(date: 110, seq: 43)
    let update43 = makeDurableUpdate(seq: 43, date: 110, payload: .updateUserSettings(.init()))
    var user = InlineProtocol.User()
    user.id = 1
    var me = InlineProtocol.GetMeResult()
    me.user = user
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [checkpoint, replayThrough],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
        .getUpdates: [makeGetUpdatesResult(
          seq: 43,
          date: 110,
          updates: [update43],
          final: true,
          resultType: .slice
        )],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    let mutationToken = try auth.handle.beginAccountMutation()
    await sync.acceptedSessionOpened(sessionID: 1, mutationToken: mutationToken)
    #expect(await waitForCondition(timeout: .seconds(3)) {
      let state = await storage.getBucketState(for: .user)
      let global = await storage.getState()
      return state.seq == 43 && global.lastSyncDate == 100
    })

    let repairs = await apply.repairedUsers
    let repair = try #require(repairs.first)
    #expect(repairs.count == 1)
    #expect(repair.reason == "fresh_account_bootstrap")
    #expect(repair.targetState.date == 0)
    #expect(repair.targetState.seq == 0)
    #expect(repair.checkpointState.date == 100)
    #expect(repair.checkpointState.seq == 42)
    #expect(repair.replayThroughState?.date == 110)
    #expect(repair.replayThroughState?.seq == 43)
    #expect(repair.replacesActiveCatalog)
    #expect(repair.requiresProjectionAudit)
    let persistedProjectionKinds = await apply.persistedBootstrapProjectionKinds
    #expect(Set(persistedProjectionKinds) == ["chats", "me", "settings"])
    let methods = await client.getCalledMethods()
    #expect(methods.first == .getUpdatesState)
    #expect(Set(methods[1 ... 3]) == Set([.getChats, .getMe, .getUserSettings]))
    #expect(Array(methods.suffix(2)) == [.getUpdatesState, .getUpdates])
    #expect(await client.getUpdatesStartSequences() == [42])
    #expect(await client.getUpdatesEndSequences() == [43])
    #expect(await apply.appliedUpdates == [update43])
    await sync.prepareForTermination()
  }

  @Test("fresh bootstrap carries a child hint through P1 until its persisted seed is reported")
  func testFreshBootstrapDoesNotCommitPastQueuedChildHint() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let chatKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    await apply.setBootstrapSeededStates([
      chatKey: BucketState(date: 90, seq: 5),
    ])
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 1 }
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      gateCallNumbers: [5],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 42),
          makeGetUpdatesStateResult(date: 110, seq: 42),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    try await sync.acceptedSessionOpened(
      sessionID: 1,
      mutationToken: auth.handle.beginAccountMutation()
    )
    await client.waitForCallStarted(5)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 5)])
    #expect(await storage.getState().lastSyncDate == 0)
    await client.releaseCall(5)

    #expect(await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 100
    })
    #expect(await storage.getBucketState(for: .user).seq == 42)
    await sync.prepareForTermination()
  }

  @Test("failed fresh repair handoff requeues its exact discovery targets")
  func testFailedFreshRepairHandoffRequeuesDiscoveryTargets() async throws {
    let baseStorage = InMemorySyncStorage()
    let storage = FailNextUserReadSyncStorage(base: baseStorage)
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 1 }
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      gateCallNumbers: [5],
      gateMethods: [.getUpdates],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 42),
          makeGetUpdatesStateResult(date: 110, seq: 42),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    try await sync.acceptedSessionOpened(
      sessionID: 1,
      mutationToken: auth.handle.beginAccountMutation()
    )
    await client.waitForCallStarted(5)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 5)])
    await client.waitForCallStarted(6)
    await storage.failNextUserRead()
    await client.releaseCall(5)

    #expect(await waitForCondition(timeout: .seconds(1)) {
      let stats = await sync.getStats()
      return await apply.repairedUsers.count == 1 && stats.queuedDiscoveryTargets == 2
    })
    #expect(await baseStorage.getState().lastSyncDate == 0)
    await client.releaseMethod(.getUpdates)
    await sync.prepareForTermination()
  }

  @Test("authenticated fresh bootstrap crosses Sync and the real database admission boundary")
  func testAuthenticatedFreshBootstrapWithRealDatabase() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let storage = GRDBSyncStorage(db: database)
    let engine = UpdatesEngine(
      database: database,
      authenticatedUserID: { 1 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )
    var me = InlineProtocol.GetMeResult()
    me.user = .with {
      $0.id = 1
      $0.firstName = "Recovered"
    }
    var chat = InlineProtocol.Chat()
    chat.id = 8
    chat.date = 90
    chat.title = "Recovered chat"
    chat.peerID = makeChatPeer(chatId: 8)
    chat.seq = 7
    var chats = InlineProtocol.GetChatsResult()
    chats.chats = [chat]
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    var updatedUser = InlineProtocol.UpdateUpdatedUser()
    updatedUser.user = .with {
      $0.id = 1
      $0.firstName = "Caught up after snapshot"
    }
    let update43 = makeDurableUpdate(
      seq: 43,
      date: 110,
      payload: .updatedUser(updatedUser)
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 42),
          makeGetUpdatesStateResult(date: 110, seq: 43),
        ],
        .getChats: [.getChats(chats)],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
        .getUpdates: [makeGetUpdatesResult(
          seq: 43,
          date: 110,
          updates: [update43],
          final: true,
          resultType: .slice
        )],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: InlineApplyUpdates(engine: engine),
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    try await sync.acceptedSessionOpened(
      sessionID: 1,
      mutationToken: auth.handle.beginAccountMutation()
    )

    #expect(await waitForCondition(timeout: .seconds(3)) {
      let global = try? await storage.getState()
      let user = try? await storage.getBucketState(for: .user)
      return global?.lastSyncDate == 100 && user?.seq == 43
    })
    #expect(try await storage.getBucketState(for: .user).seq == 43)
    #expect(try await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 8))).seq == 7)
    try await queue.read { (db: Database) throws in
      #expect(try User.fetchOne(db, id: 1)?.firstName == "Caught up after snapshot")
      #expect(try Chat.fetchOne(db, id: 8)?.title == "Recovered chat")
    }
    let methods = await client.getCalledMethods()
    #expect(methods.count(where: { $0 == .getUpdatesState }) == 2)
    #expect(methods.count(where: { $0 == .getChats }) == 1)
    #expect(methods.count(where: { $0 == .getMe }) == 1)
    #expect(methods.count(where: { $0 == .getUserSettings }) == 1)
    #expect(await client.getUpdatesStartSequences() == [42])
    #expect(await client.getUpdatesEndSequences() == [43])
    await sync.prepareForTermination()
  }

  enum BootstrapProjectionFailure: CaseIterable, Equatable, Sendable {
    case chats
    case me
    case settings
  }

  @Test(
    "authenticated fresh connection retains zero while preserving successful projections",
    arguments: BootstrapProjectionFailure.allCases
  )
  func testAuthenticatedFreshConnectionRetainsZeroWhenSnapshotFails(
    _ failedProjection: BootstrapProjectionFailure
  ) async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    var user = InlineProtocol.User()
    user.id = 1
    var me = InlineProtocol.GetMeResult()
    me.user = user
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let chatsResponse: InlineProtocol.RpcResult.OneOf_Result? = failedProjection == .chats
      ? nil
      : .getChats(.init())
    let meResponse: InlineProtocol.RpcResult.OneOf_Result? = failedProjection == .me
      ? nil
      : .getMe(me)
    let settingsResponse: InlineProtocol.RpcResult.OneOf_Result? = failedProjection == .settings
      ? nil
      : .getUserSettings(settings)
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100, seq: 42)],
        .getChats: [chatsResponse],
        .getMe: [meResponse],
        .getUserSettings: [settingsResponse],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    let mutationToken = try auth.handle.beginAccountMutation()
    await sync.acceptedSessionOpened(sessionID: 1, mutationToken: mutationToken)
    #expect(await waitForCondition(timeout: .seconds(1)) {
      let callCount = await client.getCallCount()
      let projectionCount = await apply.persistedBootstrapProjectionKinds.count
      return callCount >= 4 && projectionCount == 2
    })
    #expect(await storage.getState().lastSyncDate == 0)
    let userState = await storage.getBucketState(for: .user)
    #expect(userState.date == 0)
    #expect(userState.seq == 0)
    #expect(await apply.repairedUsers.isEmpty)
    let persistedProjectionKinds = await apply.persistedBootstrapProjectionKinds
    let expectedProjectionKinds: Set<String> = switch failedProjection {
      case .chats: ["me", "settings"]
      case .me: ["chats", "settings"]
      case .settings: ["chats", "me"]
    }
    #expect(Set(persistedProjectionKinds) == expectedProjectionKinds)
    await sync.prepareForTermination()
  }

  @Test(
    "authenticated fresh bootstrap retries a transient projection failure without admitting its baseline",
    arguments: BootstrapProjectionFailure.allCases
  )
  func testAuthenticatedFreshConnectionRetriesProjectionFailure(
    _ failedProjection: BootstrapProjectionFailure
  ) async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 1 }
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let failedMethod: InlineProtocol.Method = switch failedProjection {
      case .chats: .getChats
      case .me: .getMe
      case .settings: .getUserSettings
    }
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 42),
          makeGetUpdatesStateResult(date: 100, seq: 42),
          makeGetUpdatesStateResult(date: 110, seq: 42),
        ],
        .getChats: [.getChats(.init()), .getChats(.init())],
        .getMe: [.getMe(me), .getMe(me)],
        .getUserSettings: [.getUserSettings(settings), .getUserSettings(settings)],
      ],
      methodErrors: [failedMethod: [URLError(.timedOut)]]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    await sync.acceptedSessionOpened(
      sessionID: 1,
      mutationToken: try auth.handle.beginAccountMutation()
    )
    #expect(await waitForCondition(timeout: .seconds(1)) {
      await apply.persistedBootstrapProjectionKinds.count == 2
    })
    #expect(await storage.getState().lastSyncDate == 0)
    #expect(await storage.getBucketState(for: .user).seq == 0)

    #expect(await waitForCondition(timeout: .seconds(4)) {
      await storage.getState().lastSyncDate == 100
    })
    #expect(await storage.getBucketState(for: .user).seq == 42)
    #expect(await apply.repairedUsers.count == 1)
    let methods = await client.getCalledMethods()
    #expect(methods.filter { $0 == .getUpdatesState }.count == 3)
    #expect(methods.filter { $0 == .getChats }.count == 2)
    #expect(methods.filter { $0 == .getMe }.count == 2)
    #expect(methods.filter { $0 == .getUserSettings }.count == 2)
    await sync.prepareForTermination()
  }

  @Test("cancelled fresh bootstrap may keep partial projections but never admits a baseline")
  func testCancelledFreshBootstrapDoesNotAdmitBaseline() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 1 }
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      gateMethods: [.getUserSettings],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100, seq: 42)],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    await sync.acceptedSessionOpened(
      sessionID: 1,
      mutationToken: try auth.handle.beginAccountMutation()
    )
    #expect(await waitForCondition(timeout: .seconds(1)) {
      let methods = await client.getCalledMethods()
      let projectionCount = await apply.persistedBootstrapProjectionKinds.count
      return methods.contains(.getUserSettings) && projectionCount == 2
    })
    #expect(await storage.getState().lastSyncDate == 0)
    #expect(await storage.getBucketState(for: .user).seq == 0)

    let termination = Task { await sync.prepareForTermination() }
    try? await Task.sleep(for: .milliseconds(10))
    await client.releaseMethod(.getUserSettings)
    await termination.value

    #expect(await storage.getState().lastSyncDate == 0)
    #expect(await storage.getBucketState(for: .user).seq == 0)
    #expect(await apply.repairedUsers.isEmpty)
  }

  @Test("authenticated zero-date bootstrap preserves a user cursor ahead of its captured checkpoint")
  func testAuthenticatedFreshConnectionAcceptsCheckpointBehindUserCursor() async throws {
    let storage = InMemorySyncStorage()
    await storage.setBucketState(for: .user, state: BucketState(date: 300, seq: 75))
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 1 }
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 200, seq: 50),
          makeGetUpdatesStateResult(date: 220, seq: 55),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )

    await sync.activateGeneration()
    await sync.acceptedSessionOpened(
      sessionID: 1,
      mutationToken: try auth.handle.beginAccountMutation()
    )
    #expect(await waitForCondition(timeout: .seconds(3)) {
      let globalDate = await storage.getState().lastSyncDate
      let repairCount = await apply.repairedUsers.count
      return globalDate == 200 && repairCount == 1
    })

    let repair = try #require(await apply.repairedUsers.first)
    #expect(repair.targetState.seq == 75)
    #expect(repair.checkpointState.seq == 50)
    #expect(repair.replayThroughState?.seq == 55)
    #expect(repair.allowsCheckpointBehindTarget)
    #expect(await storage.getBucketState(for: .user).seq == 75)
    let persistedProjectionKinds = await apply.persistedBootstrapProjectionKinds
    #expect(Set(persistedProjectionKinds) == ["chats", "me", "settings"])
    #expect(await client.getCalledMethods().contains(.getUpdates) == false)
    await sync.prepareForTermination()
  }

  @Test("fresh empty checkpoint captures the first concurrent user update")
  func testFreshEmptyCheckpointCapturesFirstConcurrentUpdate() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let update1 = makeDurableUpdate(seq: 1, date: 110, payload: .updateUserSettings(.init()))
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 0),
          makeGetUpdatesStateResult(date: 110, seq: 1),
        ],
        .getUpdates: [makeGetUpdatesResult(
          seq: 1,
          date: 110,
          updates: [update1],
          final: true,
          resultType: .slice
        )],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    #expect(await waitForCondition(timeout: .seconds(3)) {
      await storage.getBucketState(for: .user).seq == 1
    })
    #expect(await client.getUpdatesStateDates() == [nil, nil])
    #expect(await client.getUpdatesStartSequences() == [0])
    #expect(await client.getUpdatesEndSequences() == [1])
    #expect(await apply.appliedUpdates == [update1])
    #expect(await apply.bucketCommits.count == 2)
    await sync.prepareForTermination()
  }

  enum InvalidEmptyCompletion: CaseIterable, Sendable {
    case nonfinal, belowTarget, advancing, negativeDate, slice, sidecars, updates, skips
  }

  @Test("date-less completion never admits mutations or unresolved targets", arguments: InvalidEmptyCompletion.allCases)
  func testInvalidEmptyCompletionIsRejected(_ invalid: InvalidEmptyCompletion) async throws {
    let storage = InMemorySyncStorage()
    await storage.setBucketState(for: .user, state: BucketState(date: 100, seq: 42))
    let apply = RecordingApplyUpdates()
    var page = InlineProtocol.GetUpdatesResult.with {
      $0.seq = 42; $0.date = 0; $0.final = true; $0.resultType = .empty
    }
    var target: Int64 = 42
    switch invalid {
    case .nonfinal: page.final = false
    case .belowTarget: target = 43
    case .advancing:
      target = 43
      page.seq = 43
      page.skippedSequences = makeIrrelevantSkippedSequences(after: 42, through: 43)
    case .negativeDate: page.date = -1
    case .slice: page.resultType = .slice
    case .sidecars: page.sidecars = .init()
    case .updates: page.updates = [makeChatInfoUpdate(seq: 43, date: 110)]
    case .skips: page.skippedSequences = makeIrrelevantSkippedSequences(after: 42, through: 43)
    }
    let client = FakeProtocolClient(responses: [.getUpdates(page)])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    let actor = BucketActor(
      key: .user, seq: 42, date: 100, client: client, sync: sync,
      fetchLimiter: FetchLimiter(limit: 1), accountMutationToken: nil
    )
    await actor.setFetchTarget(upToSeq: target)
    await actor.fetchNewUpdates()
    #expect(await apply.bucketCommits.isEmpty)
    #expect(await apply.appliedUpdates.isEmpty)
    #expect(await apply.appliedSidecars.isEmpty)
    #expect(await storage.getBucketState(for: .user).seq == 42)
    #expect(await storage.getBucketState(for: .user).date == 100)
    await actor.invalidate()
    await actor.waitUntilIdle()
    await sync.prepareForTermination()
  }

  @Test("repeated malformed pages retain the cursor without inferring snapshot repair")
  func testRepeatedMalformedPagesDoNotInferRepair() async throws {
    let sink = MatchingLogSink(
      fragment: "start=5|target=6|seq=6|result=slice|final=true|updates=0|skipped=0|accounted=0"
    )
    Log.addSink(sink, id: "sync-malformed-page-tests")
    defer { Log.removeSink(id: "sync-malformed-page-tests") }
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let peer = makeChatPeer(chatId: 7)
    let key = BucketKey.chat(peer: peer)
    await storage.setBucketState(for: key, state: BucketState(date: 100, seq: 5))
    let malformed = makeGetUpdatesResult(
      seq: 6,
      date: 110,
      updates: [],
      final: true,
      resultType: .slice
    )
    let client = FakeProtocolClient(responses: [
      malformed,
      malformed,
      malformed,
    ])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    let actor = BucketActor(
      key: key,
      seq: 5,
      date: 100,
      client: client,
      sync: sync,
      fetchLimiter: FetchLimiter(limit: 1),
      accountMutationToken: nil
    )
    await actor.setFetchTarget(upToSeq: 6)

    for attempt in 0 ..< 3 {
      await actor.fetchNewUpdates()
      if attempt < 2 {
        #expect(await actor.wakeRetryIfNeeded())
      }
    }

    #expect(await client.getCalledMethods() == [
      InlineProtocol.Method.getUpdates,
      .getUpdates,
      .getUpdates,
    ])
    #expect(await apply.repairedChats.isEmpty)
    #expect(await apply.bucketCommits.isEmpty)
    #expect(sink.matchCount == 1)
    let retained = await storage.getBucketState(for: key)
    #expect(retained.date == 100)
    #expect(retained.seq == 5)
    await actor.invalidate()
    await actor.waitUntilIdle()
    await sync.prepareForTermination()
  }

  @Test("fresh checkpoint does not regress a partially persisted user cursor")
  func testFreshCheckpointPreservesNewerUserCursor() async throws {
    let storage = InMemorySyncStorage()
    await storage.setBucketState(for: .user, state: BucketState(date: 110, seq: 50))
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 42),
          makeGetUpdatesStateResult(date: 110, seq: 50),
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    let didInstallCheckpoint = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 85
    }

    #expect(didInstallCheckpoint)
    let didCaptureCurrentUser = await waitForCondition(timeout: .seconds(1)) {
      await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2
    }
    #expect(didCaptureCurrentUser)
    let userState = await storage.getBucketState(for: .user)
    #expect(userState.seq == 50)
    #expect(userState.date == 110)
    #expect(await client.getUpdatesStartSequences().isEmpty)
    #expect(await client.getUpdatesEndSequences().isEmpty)
  }

  @Test("connected event during checkpoint discovery schedules one follow-up")
  func testConnectedEventDuringCheckpointDiscoverySchedulesFollowUp() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      gateCallNumbers: [1],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 42),
          makeGetUpdatesStateResult(date: 101, seq: 42),
          makeGetUpdatesStateResult(date: 101, seq: 42),
        ],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.acceptedSessionOpened(sessionID: 1)
    await client.waitForFirstCallStarted()
    await sync.acceptedSessionOpened(sessionID: 2)
    await Task.yield()

    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 1)

    await client.releaseCall(1)
    let didRunFollowUp = await waitForCondition(timeout: .seconds(3)) {
      await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 3
    }
    #expect(didRunFollowUp)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 3)
  }

  @Test("overlapping discovery rounds cannot borrow an earlier round target")
  func testOverlappingDiscoveryRoundsRequireIndependentTargets() async throws {
    let storage = InMemorySyncStorage()
    await storage.setState(SyncState(lastSyncDate: 10))
    let client = FakeProtocolClient(
      responses: [],
      gateCallNumbers: [1],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, updatesFound: true),
          makeGetUpdatesStateResult(date: 200, updatesFound: true),
        ],
        .getUpdates: [makeGetUpdatesResult(
          seq: 1,
          date: 100,
          updates: [makeNewMessageUpdate(seq: 1, date: 100)],
          final: true,
          resultType: .slice
        )],
      ]
    )
    let sync = Sync(
      applyUpdates: RecordingApplyUpdates(),
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    await client.waitForFirstCallStarted()
    let peer = makeChatPeer(chatId: 1)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    // Complete the first round's target deterministically; the bucket actor's
    // eventual fetch is intentionally outside this round-accounting assertion.
    await sync.bucketDidAdvance(
      key: .chat(peer: peer),
      state: BucketState(date: 100, seq: 1)
    )

    // Queue a second discovery while the first result is still in flight. Its
    // updatesFound=true result has no same-round hint and must not reuse the
    // first round's chat target.
    await sync.acceptedSessionOpened(sessionID: 2)
    await client.releaseFirstCall()
    let secondRoundStarted = await waitForCondition {
      await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2
    }
    #expect(secondRoundStarted)
    try? await Task.sleep(for: .milliseconds(50))

    // Round one is allowed to commit; round two is not.
    #expect(await storage.getState().lastSyncDate == 85)
    await sync.prepareForTermination()
  }

  @Test("fresh checkpoint retries a response missing user sequence")
  func testFreshCheckpointRetriesMissingUserSequence() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    var missingSequence = InlineProtocol.GetUpdatesStateResult()
    missingSequence.date = 100
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          .getUpdatesState(missingSequence),
          makeGetUpdatesStateResult(date: 101, seq: 55),
          makeGetUpdatesStateResult(date: 101, seq: 55),
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 101
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 3)
    #expect(await storage.getBucketState(for: .user).seq == 55)
  }

  @Test("fresh checkpoint retries an invalid RPC result")
  func testFreshCheckpointRetriesInvalidResult() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          nil,
          makeGetUpdatesStateResult(date: 102, seq: 56),
          makeGetUpdatesStateResult(date: 102, seq: 56),
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 102
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 3)
    #expect(await storage.getBucketState(for: .user).seq == 56)
  }

  @Test("fresh checkpoint retries a negative user sequence")
  func testFreshCheckpointRetriesNegativeUserSequence() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: -1),
          makeGetUpdatesStateResult(date: 101, seq: 0),
          makeGetUpdatesStateResult(date: 101, seq: 0),
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    #expect(await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 101
    })
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 3)
    #expect(await storage.getBucketState(for: .user).seq == 0)
    await sync.prepareForTermination()
  }

  @Test("fresh checkpoint retries a transient bucket cursor write failure")
  func testFreshCheckpointRetriesBucketWriteFailure() async throws {
    let storage = InMemorySyncStorage()
    await storage.failNextBucketStateWrites(1)
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 21),
          makeGetUpdatesStateResult(date: 101, seq: 22),
          makeGetUpdatesStateResult(date: 101, seq: 22),
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 101
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 3)
    #expect(await storage.getBucketState(for: .user).seq == 22)
  }

  @Test("fresh checkpoint retries a transient global cursor write failure")
  func testFreshCheckpointRetriesGlobalWriteFailure() async throws {
    let storage = InMemorySyncStorage()
    await storage.failNextStateWrites(1)
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 100, seq: 31),
          makeGetUpdatesStateResult(date: 101, seq: 32),
          makeGetUpdatesStateResult(date: 101, seq: 32),
        ],
        .getUpdates: [makeGetUpdatesResult(
          seq: 32, date: 101, updates: [], final: true, resultType: .slice,
          skippedSequences: makeIrrelevantSkippedSequences(after: 31, through: 32)
        )],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 86
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 3)
    #expect(await storage.getBucketState(for: .user).seq == 32)
    #expect(await client.getUpdatesStartSequences() == [31])
  }

  @Test("partial fresh checkpoint replays an existing lower user cursor")
  func testPartialFreshCheckpointReplaysExistingUserCursor() async throws {
    let storage = InMemorySyncStorage()
    await storage.setBucketState(for: .user, state: BucketState(date: 100, seq: 10))
    let client = FakeProtocolClient(responses: [], methodResponses: [
      .getUpdatesState: [
        makeGetUpdatesStateResult(date: 200, seq: 20),
        makeGetUpdatesStateResult(date: 200, seq: 20),
      ],
      .getUpdates: [makeGetUpdatesResult(
        seq: 20, date: 200, updates: [], final: true, resultType: .slice,
        skippedSequences: makeIrrelevantSkippedSequences(after: 10, through: 20)
      )],
    ])
    let sync = Sync(applyUpdates: RecordingApplyUpdates(), syncStorage: storage, client: client, config: .default)
    await sync.acceptedSessionOpened(sessionID: 1)
    #expect(await waitForCondition { await storage.getState().lastSyncDate == 185 })
    #expect(await client.getUpdatesStartSequences() == [10])
    #expect(await client.getUpdatesEndSequences() == [20])
    #expect(await storage.getBucketState(for: .user).seq == 20)
    await sync.prepareForTermination()
  }

  @Test("snapshot advances an actor that was already fetching from an older cursor")
  func testSnapshotAdvancesExistingBucketActor() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let peer = makeChatPeer(chatId: 1)
    let client = FakeProtocolClient(
      responses: [],
      gateCallNumbers: [1],
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 1,
          date: 100,
          updates: [makeNewMessageUpdate(seq: 1, date: 100)],
          final: true,
          resultType: .slice
        )],
      ]
    )
    let activity = SyncActivityRecorder()
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )
    await sync.setSyncActivityListener { isActive in
      await activity.record(isActive)
    }

    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    await client.waitForFirstCallStarted()

    let snapshotState = BucketState(date: 0, seq: 100)
    await storage.setBucketState(for: .chat(peer: peer), state: snapshotState)
    await sync.installSnapshotBucketStates([.chat(peer: peer): snapshotState])
    await client.releaseFirstCall()

    let fetchFinished = await waitForCondition(timeout: .seconds(3)) {
      await activity.sequence == [true, false]
    }
    #expect(fetchFinished)
    #expect(await apply.appliedUpdates.isEmpty)
    #expect(await storage.getBucketState(for: .chat(peer: peer)).seq == 100)
    let stats = await sync.getStats()
    #expect(stats.buckets.first(where: { $0.key == .chat(peer: peer) })?.seq == 100)
  }

  @Test("old sync state keeps its real discovery cursor")
  func testOldSyncStateKeepsDiscoveryCursor() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let day: Int64 = 24 * 60 * 60
    let before = Int64(Date().timeIntervalSince1970)
    let storedDate = before - 15 * day
    await storage.setState(SyncState(lastSyncDate: storedDate))

    await sync.acceptedSessionOpened(sessionID: 1)
    let didCaptureCurrentUser = await waitForCondition(timeout: .seconds(3)) {
      await client.getCalledMethods()
        .filter { $0 == .getUpdatesState }
        .count == 2
    }
    #expect(didCaptureCurrentUser)

    let state = await storage.getState()
    #expect(state.lastSyncDate == storedDate)
    let requestedDates = await client.getUpdatesStateDates()
    // A failed dated discovery retries from the same durable cursor.
    #expect(requestedDates == [storedDate, storedDate])
    await sync.prepareForTermination()
  }

  @Test("a server-regressed checkpoint enters admitted user repair before rewinding global state")
  func testServerRegressedCheckpointUsesUserRepair() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let auth = Auth.mocked(authenticated: true)
    await storage.setState(SyncState(lastSyncDate: 300))
    await storage.setBucketState(for: .user, state: BucketState(date: 300, seq: 30))

    var user = InlineProtocol.User()
    user.id = 42
    var me = InlineProtocol.GetMeResult()
    me.user = user
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          // The warm response is explicitly behind the persisted checkpoint.
          makeGetUpdatesStateResult(date: 200, updatesFound: false, seq: 40),
          // The admitted user repair captures a fresh account checkpoint.
          makeGetUpdatesStateResult(date: 220, seq: 40),
        ],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.acceptedSessionOpened(sessionID: 1, mutationToken: try auth.handle.beginAccountMutation())
    let repaired = await waitForCondition {
      await storage.getState().lastSyncDate == 185
    }

    #expect(repaired)
    #expect(await client.getUpdatesStateDates() == [300, nil])
    let repairedUser = await storage.getBucketState(for: .user)
    #expect(repairedUser.seq == 40)
    #expect(repairedUser.date == 300)
    #expect((await apply.repairedUsers).first?.requiresProjectionAudit == true)
    #expect((await apply.repairedUsers).first?.replacesActiveCatalog == false)
    // Regression is admitted only after repair convergence and uses the
    // server's explicit regressed marker (200), not the monotonic user cursor
    // date retained by the repair owner (300).
    #expect(await storage.getState().lastSyncDate == 185)
    #expect(await client.getCalledMethods().filter { $0 == .getChats }.count == 1)
    #expect(await client.getCalledMethods().contains(.getUpdates) == false)
    await sync.prepareForTermination()
  }

  @Test("regression audits an equal user cursor and catches only the returned child")
  func testServerRegressedCheckpointAuditsEqualUserCursorAndChildTarget() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()
    let childKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))

    // The global cursor is poisoned into the future, while the user cursor is
    // already equal to the server's repair checkpoint. The child still needs
    // an exact replay target from the account projection.
    await storage.setState(SyncState(lastSyncDate: 500))
    await storage.setBucketState(for: .user, state: BucketState(date: 500, seq: 40))
    await storage.setBucketState(for: childKey, state: BucketState(date: 500, seq: 3))
    await apply.setUserRepairOutcome(.pending(
      finalization: UserRepairFinalization(
        expectedUserState: BucketState(date: 500, seq: 40),
        expectedUserStateExists: true,
        proposedUserState: BucketState(date: 500, seq: 40),
        catchUpTargets: [childKey: 5],
        mutationToken: token
      ),
      seededStates: [:]
    ))

    var user = InlineProtocol.User()
    user.id = 42
    var me = InlineProtocol.GetMeResult()
    me.user = user
    var settings = InlineProtocol.GetUserSettingsResult()
    settings.userSettings = .init()
    let childPage = makeGetUpdatesResult(
      seq: 5,
      date: 210,
      updates: [],
      final: true,
      resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 3, through: 5)
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 200, updatesFound: false, seq: 40),
          makeGetUpdatesStateResult(date: 220, seq: 40),
        ],
        .getUpdates: [childPage],
        .getChats: [.getChats(.init())],
        .getMe: [.getMe(me)],
        .getUserSettings: [.getUserSettings(settings)],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.acceptedSessionOpened(sessionID: 1, mutationToken: token)
    let converged = await waitForCondition {
      let child = await storage.getBucketState(for: childKey)
      let state = await storage.getState()
      return child.seq == 5 && state.lastSyncDate == 185
    }

    #expect(converged)
    let repairs = await apply.repairedUsers
    let repair = try #require(repairs.first)
    #expect(repair.requiresProjectionAudit)
    #expect(repair.targetState.date == 500)
    #expect(repair.targetState.seq == 40)
    let userState = await storage.getBucketState(for: .user)
    #expect(userState.date == 500)
    #expect(userState.seq == 40)
    #expect(await storage.getState().lastSyncDate <= 220)
    #expect(await client.getCalledMethods().filter { $0 == .getChats }.count == 1)
    #expect(await client.getUpdatesStartSequences() == [3])
    #expect(await client.getUpdatesEndSequences() == [5])
  }

  @Test("catalog snapshot resolves seeded finite targets without sweeping buckets")
  func testCatalogSnapshotInstallsSeededFiniteTargetWithoutSweep() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()
    let targetKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    let unrelatedKey = BucketKey.chat(peer: makeChatPeer(chatId: 8))
    let seededState = BucketState(date: 210, seq: 5)
    await storage.setBucketState(for: targetKey, state: seededState)
    await storage.setBucketState(for: unrelatedKey, state: BucketState(date: 210, seq: 99))
    let client = FakeProtocolClient(responses: [])
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: .default,
      auth: auth.handle
    )
    await sync.activateGeneration()

    let resolutions = try await sync.installSnapshotOutcome(
      seededStates: [targetKey: seededState],
      catchUpTargets: [targetKey: 5],
      expectedAccount: token
    )

    #expect(resolutions[targetKey]?.state.seq == 5)
    #expect(resolutions[targetKey]?.authoritative == false)
    #expect(await client.getCalledMethods().isEmpty)
    let stats = await sync.getStats()
    #expect(stats.buckets.map(\.key) == [targetKey])
    #expect(stats.queuedDiscoveryTargets == 0)
  }

  @Test("catalog seed retires a waiting finite hint without a new target")
  func testCatalogSeedRetiresWaitingFiniteHint() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let auth = Auth.mocked(authenticated: true)
    let token = try auth.handle.beginAccountMutation()
    let targetKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    let seededState = BucketState(date: 210, seq: 5)
    let client = FakeProtocolClient(
      responses: [],
      gateFirstCall: true,
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 5,
          date: 210,
          updates: [],
          final: true,
          resultType: .slice,
          skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 5)
        )]
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: .default,
      auth: auth.handle
    )
    await sync.activateGeneration()

    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 5)])
    await client.waitForFirstCallStarted()
    await storage.setBucketState(for: targetKey, state: seededState)
    let resolutions = try await sync.installSnapshotOutcome(
      seededStates: [targetKey: seededState],
      catchUpTargets: [:],
      expectedAccount: token
    )
    #expect(resolutions.isEmpty)
    #expect((await sync.getStats()).queuedDiscoveryTargets == 0)

    await client.releaseFirstCall()
    let settled = await waitForCondition {
      await storage.getBucketState(for: targetKey).seq == 5
    }
    #expect(settled)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdates }.count == 1)
  }

  @Test("global storage read failure does not become a fresh checkpoint")
  func testGlobalStorageReadFailureDoesNotBootstrap() async throws {
    let storage = ReadFailingSyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100, seq: 50)],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.acceptedSessionOpened(sessionID: 1)
    let didCallState = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCalledMethods().contains(.getUpdatesState)
    }

    #expect(didCallState == false)
    #expect(await client.getCallCount() == 0)
    await sync.prepareForTermination()
  }

#if DEBUG || DEBUG_BUILD
  @Test("debug zero-date scenario requests a fresh current checkpoint")
  func testDebugZeroDateScenarioRequestsFreshCheckpoint() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [
          makeGetUpdatesStateResult(date: 777, seq: 12),
          makeGetUpdatesStateResult(date: 777, seq: 12),
        ],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let result = await sync.runDebugScenario(.seedZeroDateAndFetch)
    #expect(result.succeeded)

    let didCallState = await waitForCondition(timeout: .seconds(3)) {
      let dates = await client.getUpdatesStateDates()
      let state = await storage.getState()
      let user = await storage.getBucketState(for: .user)
      return dates.count == 2 && state.lastSyncDate == 777 && user.seq == 12
    }
    #expect(didCallState)

    #expect(await client.getUpdatesStateDates() == [nil, nil])
    #expect(await storage.getState().lastSyncDate == 777)
    #expect(await storage.getBucketState(for: .user).seq == 12)
    await sync.prepareForTermination()
  }

  @Test("debug clear-state scenario clears storage and queues discovery")
  func testDebugClearStateScenarioClearsStorageAndQueuesDiscovery() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await storage.setState(SyncState(lastSyncDate: 123))
    let result = await sync.runDebugScenario(.clearStateAndFetch)
    #expect(result.succeeded)
    #expect(await storage.getClearCount() == 1)

    let didCallState = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState)
    }
    #expect(didCallState)
    await sync.prepareForTermination()
  }

  @Test("debug user rewind does not sweep chat buckets")
  func testDebugUserRewindDoesNotSweepChatBuckets() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let userDate: Int64 = 500
    let chatDate: Int64 = 600
    let chatKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    await storage.setBucketState(for: .user, state: BucketState(date: userDate, seq: 50))
    await storage.setBucketState(for: chatKey, state: BucketState(date: chatDate, seq: 100))
    let client = FakeProtocolClient(responses: [], methodResponses: [
      .getUpdatesState: [makeGetUpdatesStateResult(date: 700, seq: 50)],
      .getUpdates: [makeGetUpdatesResult(
        seq: 50, date: 700, updates: [], final: true, resultType: .slice,
        skippedSequences: makeIrrelevantSkippedSequences(after: 25, through: 50)
      )],
    ])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let result = await sync.runDebugScenario(.rewindUserBucketAndFetch)

    #expect(result.succeeded)
    #expect(await storage.getBucketState(for: .user).seq == 50)
    #expect(await storage.getBucketState(for: chatKey).seq == 100)
    #expect(await client.getUpdatesStartSequences() == [25])
    #expect(await client.getUpdatesEndSequences() == [50])
    #expect(await client.getUpdatesStateDates() == [nil])
    await sync.prepareForTermination()
  }

  @Test("debug buffer overflow uses the normal bounded recovery path")
  func testDebugBufferOverflowUsesBoundedRecovery() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let initialPage = makeGetUpdatesResult(
      seq: 1, date: 100, updates: [], final: true, resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    // Starting at seq1, the debug helper buffers 4,097 updates beginning at3.
    let overflowTarget: Int64 = 4_099
    let recoveryPages = stride(from: Int64(2), through: overflowTarget, by: 100).map { start in
      let end = min(overflowTarget, start + 99)
      return makeGetUpdatesResult(
        seq: end, date: 101, updates: [], final: end == overflowTarget, resultType: .slice,
        skippedSequences: makeIrrelevantSkippedSequences(after: start - 1, through: end)
      )
    }
    let client = FakeProtocolClient(responses: [initialPage] + recoveryPages)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 7))

    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 7, updateSeq: 1)])
    let actorReady = await waitForCondition {
      let bucket = await sync.getStats().buckets.first(where: { $0.key == key })
      return bucket?.isFetching == false && bucket?.needsFetch == false
    }
    #expect(actorReady)

    let result = await sync.runDebugBucketScenario(.overflowBufferAndRecover, key: key)
    let stats = await sync.getStats()

    #expect(result.succeeded)
    #expect(stats.realtimeBufferRecoveries == 1)
    #expect(stats.buckets.first(where: { $0.key == key })?.needsFetch == false)
    #expect(await client.getCallCount() == 1 + recoveryPages.count)
    #expect(stats.buckets.first(where: { $0.key == key })?.seq == overflowTarget)
    await sync.prepareForTermination()
  }
#endif

  @Test("user bucket catch-up applies updateReadMaxId")
  func testUserBucketAppliesUpdateReadMaxId() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let now = Int64(Date().timeIntervalSince1970)
    await storage.setState(SyncState(lastSyncDate: now - 60))
    let getUpdatesState = makeGetUpdatesStateResult(date: now, seq: 1)
    let readUpdate = makeUpdateReadMaxIdUpdate(
      seq: 1,
      date: now,
      peer: makeChatPeer(chatId: 1),
      readMaxId: 10,
      unreadCount: 0
    )
    let getUpdates = makeGetUpdatesResult(
      seq: 1,
      date: now,
      updates: [readUpdate],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [getUpdatesState],
        .getUpdates: [getUpdates],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.acceptedSessionOpened(sessionID: 1)
    let didApply = await waitForCondition(timeout: .seconds(3)) {
      await apply.appliedUpdates.count == 1
    }
    #expect(didApply)

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
    guard let first = applied.first else { return }
    if case .updateReadMaxID = first.update {
      // ok
    } else {
      #expect(Bool(false), "Expected updateReadMaxID")
    }
  }

  @Test("chatMoved catch-up updates are applied")
  func testChatMovedCatchupApplies() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let moved = makeChatMovedUpdate(seq: 1, date: 100, chatId: 1, oldSpaceId: 10, newSpaceId: 11)
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [moved],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = makeChatPeer(chatId: 1)
    payload.updateSeq = 1

    var trigger = InlineProtocol.Update()
    trigger.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [trigger])
    let didApply = await waitForCondition(timeout: .seconds(1)) {
      await apply.appliedUpdates.count == 1
    }
    #expect(didApply)

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
    guard let first = applied.first else { return }
    if case .chatMoved = first.update {
      // ok
    } else {
      #expect(Bool(false), "Expected chatMoved")
    }
  }

  @Test("user bucket catch-up applies chatOpen")
  func testUserBucketAppliesChatOpen() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await storage.setState(SyncState(lastSyncDate: 50))

    let chatOpen = makeChatOpenUpdate(seq: 1, date: 100, chatId: 1)
    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [chatOpen],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100, seq: 1)],
        .getUpdates: [response],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.acceptedSessionOpened(sessionID: 1)
    let didApply = await waitForCondition(timeout: .seconds(1)) {
      await apply.appliedUpdates.count == 1
    }
    #expect(didApply)

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
    guard let first = applied.first else { return }
    if case .chatOpen = first.update {
      // ok
    } else {
      #expect(Bool(false), "Expected chatOpen")
    }

    let bucketState = await storage.getBucketState(for: .user)
    #expect(bucketState.seq == 1)
    #expect(bucketState.date == 100)
  }

  @Test("user catch-up applies every durable user update kind")
  func testUserCatchUpAppliesEveryDurableUserUpdateKind() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await storage.setState(SyncState(lastSyncDate: 50))

    var participant = InlineProtocol.ChatParticipant()
    participant.userID = 42
    participant.date = 100
    var participantAdd = InlineProtocol.UpdateChatParticipantAdd()
    participantAdd.chatID = 7
    participantAdd.participant = participant
    let updates: [InlineProtocol.Update] = [
      makeDurableUpdate(seq: 1, date: 100, payload: .participantAdd(participantAdd)),
      makeDurableUpdate(seq: 2, date: 101, payload: .messageActionInvoked(.init())),
      makeDurableUpdate(seq: 3, date: 102, payload: .messageActionAnswered(.init())),
      makeDurableUpdate(seq: 4, date: 103, payload: .dialogFollowMode(.init())),
      makeDurableUpdate(seq: 5, date: 104, payload: .updatedUser(.init())),
      makeDurableUpdate(seq: 6, date: 105, payload: .dialogCollapsedMaxID(.init())),
      makeDurableUpdate(seq: 7, date: 106, payload: .updateUserSettings(.init())),
      makeDurableUpdate(seq: 8, date: 107, payload: .dialogFolder(.init())),
    ]
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 107, seq: 8)],
        .getUpdates: [makeGetUpdatesResult(
          seq: 8,
          date: 107,
          updates: updates,
          final: true,
          resultType: .slice
        )],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.acceptedSessionOpened(sessionID: 1)
    let didApply = await waitForCondition {
      await apply.appliedUpdates.count == updates.count
    }

    #expect(didApply)
    #expect(await apply.appliedUpdates.map(\.seq) == [1, 2, 3, 4, 5, 6, 7, 8])
    let bucketState = await storage.getBucketState(for: .user)
    #expect(bucketState.seq == 8)
    #expect(bucketState.date == 107)
  }

  @Test("catch-up advances past a forward-compatible unknown update")
  func testCatchUpAdvancesPastUnknownFutureUpdate() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    var unknown = InlineProtocol.Update()
    unknown.seq = 1
    unknown.date = 100
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [makeGetUpdatesResult(
          seq: 1,
          date: 100,
          updates: [unknown],
          final: true,
          resultType: .slice
        )],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    let advanced = await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 1
    }

    #expect(advanced)
    #expect(await apply.appliedUpdates.count == 1)
    #expect(await apply.appliedUpdates.first?.update == nil)
  }

  @Test("large catch-up keeps global Updating through background pages")
  func testLargeCatchUpKeepsSyncActivityThroughBackgroundPages() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    var pages: [InlineProtocol.RpcResult.OneOf_Result?] = []
    for page in 1 ... 20 {
      let startSeq = Int64((page - 1) * 100)
      let endSeq = Int64(page * 100)
      let pageDate = Int64(100 + page)
      let skipped = makeIrrelevantSkippedSequences(after: startSeq, through: endSeq)
      let result = makeGetUpdatesResult(
        seq: endSeq, date: pageDate, updates: [], final: page == 20,
        resultType: .slice,
        skippedSequences: skipped
      )
      pages.append(result)
    }
    let client = FakeProtocolClient(
      responses: [],
      gateCallNumbers: [2],
      methodResponses: [
        .getUpdates: pages,
      ]
    )
    let activity = SyncActivityRecorder()
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )
    await sync.setSyncActivityListener { isActive in
      await activity.record(isActive)
    }

    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 2_000)])
    await client.waitForCallStarted(2)

    let activityWhileBackgroundFetchIsBlocked = await activity.sequence
    let stateWhileBackgroundFetchIsBlocked = await storage.getBucketState(
      for: .chat(peer: makeChatPeer(chatId: 1))
    )
    #expect(activityWhileBackgroundFetchIsBlocked == [true])
    #expect(stateWhileBackgroundFetchIsBlocked.seq == 100)

    await client.releaseCall(2)
    let completed = await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 2_000
    }
    #expect(completed)
    #expect(await waitForCondition { await activity.sequence == [true, false] })
    let finalActivity = await activity.sequence
    #expect(finalActivity == [true, false])
    #expect(await client.getUpdatesEndSequences() == Array<Int64?>(repeating: 2_000, count: 20))
    await sync.prepareForTermination()
  }

  @Test("ACK catch-up and live delivery advance the correct DM or group bucket", arguments: [false, true])
  func testAcknowledgementSyncRouting(directMessage: Bool) async throws {
    let peer: InlineProtocol.Peer = directMessage
      ? .with { $0.user = .with { $0.userID = 7 } }
      : makeChatPeer(chatId: 42)
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let cursor = InlineProtocol.ChatAcknowledgement.with {
      $0.chatID = 42; $0.userID = 9; $0.maxID = 10; $0.peerID = peer
    }
    let first = makeDurableUpdate(seq: 1, date: 100, payload: .acknowledgement(cursor))
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 1, date: 100, updates: [first], final: true, resultType: .slice
    )])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    let signal = InlineProtocol.Update.with {
      $0.chatHasNewUpdates = .with { $0.peerID = peer; $0.updateSeq = 1 }
    }
    await sync.process(updates: [signal])
    let caughtUp = await waitForCondition { await storage.getBucketState(for: .chat(peer: peer)).seq == 1 }
    #expect(caughtUp)
    #expect(await apply.appliedUpdates.count == 1)
    var secondCursor = cursor
    secondCursor.maxID = 12
    await sync.process(updates: [makeDurableUpdate(seq: 2, date: 101, payload: .acknowledgement(secondCursor))])
    #expect(await storage.getBucketState(for: .chat(peer: peer)).seq == 2)
    #expect(await apply.appliedUpdates.count == 2)
    if directMessage {
      #expect(await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 42))).seq == 0)
    }
  }

  @Test("legacy sequenced reaction records remain replayable without making reactions durable")
  func testChatCatchUpAppliesDurableReactionUpdates() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let updates = [
      makeDurableUpdate(seq: 1, date: 100, payload: .updateReaction(.init())),
      makeDurableUpdate(seq: 2, date: 101, payload: .deleteReaction(.init())),
    ]
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 2,
      date: 101,
      updates: updates,
      final: true,
      resultType: .slice
    )])
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 2)])
    let didApply = await waitForCondition {
      await apply.appliedUpdates.count == updates.count
    }

    #expect(didApply)
    #expect(await apply.appliedUpdates.map(\.seq) == [1, 2])
    let peer = makeChatPeer(chatId: 1)
    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
    #expect(bucketState.date == 101)
  }

  @Test("space catch-up accounts for durable space settings")
  func testSpaceCatchUpAccountsForSpaceSettings() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    var payload = InlineProtocol.UpdateSpaceSettings()
    payload.spaceID = 10
    let update = makeDurableUpdate(seq: 1, date: 100, payload: .spaceSettings(payload))
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [update],
      final: true,
      resultType: .slice
    )])
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.process(updates: [makeSpaceHasNewUpdatesSignal(spaceId: 10, updateSeq: 1)])
    let didApply = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }

    #expect(didApply)
    let bucketState = await storage.getBucketState(for: .space(id: 10))
    #expect(bucketState.seq == 1)
    #expect(bucketState.date == 100)
  }

  @Test("chat catch-up apply failure retains cursor without snapshot repair")
  func testChatCatchUpApplyFailureRepairsAndAdvancesBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResult(UpdateApplyResult(appliedCount: 0, failedCount: 1))

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 100, seq: 5))

    let update = makeChatInfoUpdate(seq: 6, date: 120)
    let response = makeGetUpdatesResult(
      seq: 6,
      date: 120,
      updates: [update],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 6)
    await sync.process(updates: [signal])

    let didApply = await waitForCondition(timeout: .milliseconds(500)) {
      await apply.appliedUpdates.count == 1
    }
    #expect(didApply)

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
    #expect(await apply.repairedChats.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 100)
    #expect(await waitForCondition { await sync.getStats().bucketApplyFailures == 1 })
    #expect(await sync.getStats().bucketUpdatesSkipped == 0)
    #expect(await sync.getStats().bucketApplyConflicts == 0)
    await sync.prepareForTermination()
  }

  @Test("space catch-up apply failure does not advance bucket state")
  func testSpaceCatchUpApplyFailureDoesNotAdvanceBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResult(UpdateApplyResult(appliedCount: 0, failedCount: 1))
    await storage.setBucketState(for: .space(id: 10), state: BucketState(date: 100, seq: 5))

    let update = makeSpaceMemberDeleteUpdate(
      seq: 6,
      date: 120,
      spaceId: 10,
      userId: 100
    )
    let response = makeGetUpdatesResult(
      seq: 6,
      date: 120,
      updates: [update],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let signal = makeSpaceHasNewUpdatesSignal(spaceId: 10, updateSeq: 6)
    await sync.process(updates: [signal])

    let didApply = await waitForCondition(timeout: .milliseconds(500)) {
      await apply.appliedUpdates.count == 1
    }
    #expect(didApply)

    let bucketState = await storage.getBucketState(for: .space(id: 10))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 100)
    await sync.prepareForTermination()
  }

  @Test("catch-up bucket state storage failure does not advance bucket state")
  func testCatchUpBucketStateStorageFailureDoesNotAdvanceBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let peer = makeChatPeer(chatId: 1)
    await storage.setState(SyncState(lastSyncDate: 90))
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 100, seq: 5))
    await storage.setFailBucketStateWrites(true)

    let update = makeChatInfoUpdate(seq: 6, date: 120)
    let response = makeGetUpdatesResult(
      seq: 6,
      date: 120,
      updates: [update],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 6)
    await sync.process(updates: [signal])

    let didApply = await waitForCondition(timeout: .milliseconds(500)) {
      await apply.appliedUpdates.count == 1
    }
    #expect(didApply)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 100)
    let globalState = await storage.getState()
    #expect(globalState.lastSyncDate == 90)

    let refetchedImmediately = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(refetchedImmediately == false)
    await sync.prepareForTermination()
  }

  @Test("non-retryable bucket error retires actor but preserves bucket state")
  func testNonRetryableBucketErrorClearsBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 100, seq: 5))

    let client = FakeProtocolClient(
      responses: [],
      methodErrors: [
        .getUpdates: [
          ProtocolSessionError.rpcError(
            errorCode: .peerIDInvalid,
            message: "Peer ID is invalid",
            code: 400
          ),
        ],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 6)
    await sync.process(updates: [signal])

    let didRetire = await waitForCondition(timeout: .milliseconds(500)) {
      let stats = await sync.getStats()
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return stats.buckets.contains(where: { $0.key == .chat(peer: peer) }) == false &&
        bucketState.seq == 5 && bucketState.date == 100
    }
    #expect(didRetire)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 100)
  }

  @Test("isolated realtime apply failure keeps bucket state for repair")
  func testIsolatedRealtimeApplyFailureKeepsBucketStateForRepair() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResult(UpdateApplyResult(appliedCount: 0, failedCount: 1))

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 100, seq: 5))

    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let update = makeChatInfoUpdate(seq: 6, date: 120)
    await sync.process(updates: [update])

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 100)
    await sync.prepareForTermination()
  }

  @Test("non-retryable fetch clears buffered realtime")
  func testNonRetryableFetchClearsBufferedRealtime() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let peer = makeChatPeer(chatId: 1)
    let invalidPeer = ProtocolSessionError.rpcError(
      errorCode: .peerIDInvalid,
      message: "Peer ID is invalid",
      code: 400
    )
    let client = FakeProtocolClient(
      responses: [],
      methodErrors: [
        .getUpdates: Array(repeating: invalidPeer, count: 5),
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let update = makeNewMessageUpdate(seq: 2, date: 100)
    await sync.process(updates: [update])

    let didClear = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 0 && bucketState.date == 0
    }
    #expect(didClear)

    let refetched = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(refetched == false)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 0)
    #expect(bucketState.date == 0)
  }

  @Test("non-retryable fetch invalidates queued bucket actor work")
  func testNonRetryableFetchInvalidatesQueuedBucketActorWork() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let invalidPeer = ProtocolSessionError.rpcError(
      errorCode: .peerIDInvalid,
      message: "Peer ID is invalid",
      code: 400
    )
    let client = FakeProtocolClient(
      responses: [],
      gateFirstCall: true,
      methodErrors: [
        .getUpdates: Array(repeating: invalidPeer, count: 5),
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)
    await sync.process(updates: [signal])
    await client.waitForFirstCallStarted()

    let second = makeNewMessageUpdate(seq: 2, date: 101)
    await sync.process(updates: [second])

    await client.releaseFirstCall()

    let refetched = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(refetched == false)
  }

  @Test("sequenced updateReadMaxId realtime update advances user bucket state")
  func testRealtimeUpdateReadMaxIdAdvancesUserBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let update = makeUpdateReadMaxIdUpdate(
      seq: 1,
      date: 100,
      peer: makeChatPeer(chatId: 1),
      readMaxId: 42,
      unreadCount: 0
    )

    await sync.process(updates: [update])
    let didAdvance = await waitForCondition(timeout: .seconds(1)) {
      let state = await storage.getBucketState(for: .user)
      return state.seq == 1 && state.date == 100
    }
    #expect(didAdvance)

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
  }

  @Test("buffers out-of-order realtime updates and repairs gap via fetch")
  func testRealtimeOutOfOrderIsBufferedUntilGapRepair() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let update1 = makeNewMessageUpdate(seq: 1, date: 80)
    let update2 = makeNewMessageUpdate(seq: 2, date: 90)
    let getUpdates = makeGetUpdatesResult(
      seq: 2,
      date: 90,
      updates: [update1, update2],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [getUpdates])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    // Receiving seq2 first freezes the gap repair target at 2. Chat replay
    // returns both rows, and the fetched duplicate retains catch-up semantics.
    await sync.process(updates: [update2])
    _ = await waitForCondition {
      await apply.appliedUpdates.count == 2
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    let sources = await apply.appliedSources
    #expect(seqs == [1, 2])
    #expect(sources == [.syncCatchup, .syncCatchup])

    let peer = makeChatPeer(chatId: 1)
    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
    #expect(await client.getUpdatesEndSequences() == [2])
    await sync.prepareForTermination()
  }

  @Test("oversized realtime buffer falls back to authoritative repair")
  func testRealtimeBufferLimitUsesAuthoritativeRepair() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
    let tooLong = makeGetUpdatesResult(
      seq: 4_098,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [tooLong],
        .getChat: [makeGetChatResult(chatId: 1, seq: 4_098)],
      ]
    )
    let auth = Auth.mocked(authenticated: true)
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15),
      auth: auth.handle
    )
    await sync.activateGeneration()

    let oversizedGap = (2 ... 4_098).map {
      makeNewMessageUpdate(seq: Int64($0), date: 100)
    }
    await sync.process(updates: oversizedGap)

    let repaired = await waitForCondition {
      await apply.repairedChats.count == 1
    }
    #expect(repaired)
    #expect(await sync.getStats().realtimeBufferRecoveries == 1)

    let peer = makeChatPeer(chatId: 1)
    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 4_098)
  }

  @Test("catch-up forwards sidecars with fetched updates")
  func testCatchupForwardsSidecarsWithFetchedUpdates() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let update = makeNewMessageUpdate(seq: 1, date: 80)
    var user = InlineProtocol.User()
    user.id = 100
    user.min = true

    var chat = InlineProtocol.Chat()
    chat.id = 1
    chat.peerID = makeChatPeer(chatId: 1)

    var space = InlineProtocol.Space()
    space.id = 10
    space.name = "Sidecar Space"

    var sidecars = InlineProtocol.UpdateSidecars()
    sidecars.users = [user]
    sidecars.chats = [chat]
    sidecars.spaces = [space]

    let getUpdates = makeGetUpdatesResult(
      seq: 1,
      date: 80,
      updates: [update],
      final: true,
      resultType: .slice,
      sidecars: sidecars
    )

    let client = FakeProtocolClient(responses: [getUpdates])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)
    await sync.process(updates: [signal])

    _ = await waitForCondition {
      await apply.appliedSidecars.count == 1
    }

    let appliedSidecars = await apply.appliedSidecars
    #expect(appliedSidecars.count == 1)
    let firstSidecar = try #require(appliedSidecars.first)
    #expect(firstSidecar.users.map(\.id) == [100])
    #expect(firstSidecar.chats.map(\.id) == [1])
    #expect(firstSidecar.spaces.map(\.id) == [10])
  }

  @Test("realtime updates do not overtake pending catch-up batch")
  func testRealtimeDoesNotOvertakePendingCatchupBatch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let update1 = makeNewMessageUpdate(seq: 1, date: 80)
    let firstSlice = makeGetUpdatesResult(
      seq: 1,
      date: 80,
      updates: [update1],
      final: false,
      resultType: .slice
    )
    let finalSlice = makeGetUpdatesResult(
      seq: 2,
      date: 90,
      updates: [makeNewMessageUpdate(seq: 2, date: 90)],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [firstSlice, finalSlice],
      gateCallNumbers: [2]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let firstSignal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 2)
    async let firstProcess: Void = sync.process(updates: [firstSignal])
    await client.waitForCallStarted(2)

    let realtime1 = makeNewMessageUpdate(seq: 1, date: 80)
    let realtime2 = makeNewMessageUpdate(seq: 2, date: 90)
    await sync.process(updates: [realtime1, realtime2])

    await client.releaseCall(2)
    await firstProcess

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 2
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    #expect(seqs == [1, 2])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
  }

  @Test("realtime structural updates do not overtake pending catch-up batch")
  func testRealtimeStructuralUpdatesDoNotOvertakePendingCatchupBatch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let update1 = makeChatInfoUpdate(seq: 1, date: 80)
    let firstSlice = makeGetUpdatesResult(
      seq: 1,
      date: 80,
      updates: [update1],
      final: false,
      resultType: .slice
    )
    let finalSlice = makeGetUpdatesResult(
      seq: 2,
      date: 90,
      updates: [makeChatInfoUpdate(seq: 2, date: 90)],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [firstSlice, finalSlice],
      gateCallNumbers: [2]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let firstSignal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 2)
    async let firstProcess: Void = sync.process(updates: [firstSignal])
    await client.waitForCallStarted(2)

    let realtime2 = makeChatInfoUpdate(seq: 2, date: 90)
    await sync.process(updates: [realtime2])

    await client.releaseCall(2)
    await firstProcess

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 2
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    #expect(seqs == [1, 2])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
  }

  @Test("stale getUpdates seq retains live updates until bounded catch-up retry succeeds")
  func testStaleServerSeqDoesNotLoopAndRealtimeContinues() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let stale = makeGetUpdatesResult(
      seq: 4,
      date: 120,
      updates: [],
      final: true,
      resultType: .empty
    )
    let realtime6 = makeNewMessageUpdate(seq: 6, date: 130)
    let retryPage = makeGetUpdatesResult(
      seq: 6, date: 130, updates: [realtime6], final: true, resultType: .slice
    )
    let client = FakeProtocolClient(responses: [stale, retryPage])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 100, seq: 5))

    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 6

    var signal = InlineProtocol.Update()
    signal.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [signal])
    _ = await waitForCondition {
      await client.getCallCount() == 1
    }

    // Ensure the backwards server cursor does not trigger an immediate loop.
    let looped = await waitForCondition(timeout: .milliseconds(200)) {
      await client.getCallCount() > 1
    }
    #expect(looped == false)

    await sync.process(updates: [realtime6])
    #expect(await apply.appliedUpdates.isEmpty)
    #expect(await client.getCallCount() == 1)
    #expect(await storage.getBucketState(for: .chat(peer: peer)).seq == 5)

    #expect(await waitForCondition {
      await storage.getBucketState(for: .chat(peer: peer)).seq == 6
    })
    let applied = await apply.appliedUpdates
    #expect(applied == [realtime6])
    #expect(await client.getUpdatesStartSequences() == [5, 5])
    #expect(await client.getUpdatesEndSequences() == [6, 6])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 6)
    await sync.prepareForTermination()
  }

  @Test("a stale hint cannot advance beyond an authoritative empty page")
  func testStaleHintDoesNotAdvanceBeyondEmptyPage() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let nonProgress = makeGetUpdatesResult(
      seq: 5,
      date: 120,
      updates: [],
      final: true,
      resultType: .empty
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [nonProgress],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 100, seq: 5))

    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 6

    var signal = InlineProtocol.Update()
    signal.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [signal])
    let completed = await waitForCondition {
      await client.getCallCount() == 1
    }
    #expect(completed)

    let spun = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(spun == false)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
    let repaired = await apply.repairedChats
    #expect(repaired.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 100)
    await sync.prepareForTermination()
  }

  @Test("declared-final page below a frozen target cannot apply rows or advance cursor date")
  func testFinalPageBelowTargetAppliesNothing() async throws {
    let storage = InMemorySyncStorage()
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 1))
    await storage.setBucketState(for: key, state: BucketState(date: 100, seq: 5))
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 6, date: 120, updates: [makeChatInfoUpdate(seq: 6, date: 120)], final: true, resultType: .slice
    )])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 7)])
    #expect(await waitForCondition {
      let callCount = await client.getCallCount()
      let bucket = await sync.getStats().buckets.first(where: { $0.key == key })
      return callCount == 1 && bucket?.isFetching == false && bucket?.needsFetch == true
    })
    #expect(await apply.appliedUpdates.isEmpty)
    #expect(await apply.bucketCommits.isEmpty)
    let state = await storage.getBucketState(for: key)
    #expect(state.seq == 5)
    #expect(state.date == 100)
    await sync.prepareForTermination()
  }

  @Test("non-progress does not skip a missing buffered sequence or busy-loop")
  func testNonProgressDoesNotSkipMissingBufferedSequence() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let nonProgress = makeGetUpdatesResult(
      seq: 0,
      date: 120,
      updates: [],
      final: false,
      resultType: .empty
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [nonProgress],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let realtime2 = makeNewMessageUpdate(seq: 2, date: 130)
    await sync.process(updates: [realtime2])

    let firstFetchStarted = await waitForCondition {
      await client.getCallCount() == 1
    }
    #expect(firstFetchStarted)

    let spun = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(spun == false)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
    let repaired = await apply.repairedChats
    #expect(repaired.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1)))
    #expect(bucketState.seq == 0)
    #expect(bucketState.date == 0)
    await sync.prepareForTermination()
  }

  @Test("buffered realtime applies after multi-slice catch-up in order")
  func testBufferedRealtimeAppliesAfterMultiSliceCatchup() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let update1 = makeNewMessageUpdate(seq: 1, date: 80)
    let update2 = makeNewMessageUpdate(seq: 2, date: 90)
    let update3 = makeNewMessageUpdate(seq: 3, date: 100)
    let firstSlice = makeGetUpdatesResult(
      seq: 3,
      date: 100,
      updates: [update1, update2, update3],
      final: false,
      resultType: .slice
    )
    let secondSlice = makeGetUpdatesResult(
      seq: 5,
      date: 120,
      updates: [makeNewMessageUpdate(seq: 4, date: 110), makeNewMessageUpdate(seq: 5, date: 120)],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [firstSlice, secondSlice],
      gateCallNumbers: [2]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let firstSignal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 5)
    async let firstProcess: Void = sync.process(updates: [firstSignal])
    await client.waitForCallStarted(2)

    let realtime4 = makeNewMessageUpdate(seq: 4, date: 110)
    let realtime5 = makeNewMessageUpdate(seq: 5, date: 120)
    await sync.process(updates: [realtime4, realtime5])

    await client.releaseCall(2)
    await firstProcess

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 5
    }
    let applied = await apply.appliedUpdates
    #expect(applied.map { Int($0.seq) } == [1, 2, 3, 4, 5])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 120)
  }

  @Test("catch-up begins after the realtime cursor without replaying older sequences")
  func testCatchupBeginsAfterRealtimeCursor() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let catchup3 = makeNewMessageUpdate(seq: 3, date: 100)
    let catchup4 = makeNewMessageUpdate(seq: 4, date: 110)
    let catchup = makeGetUpdatesResult(
      seq: 4,
      date: 110,
      updates: [catchup3, catchup4],
      final: true,
      resultType: .slice
    )
    let client = FakeProtocolClient(responses: [catchup])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let realtime1 = makeNewMessageUpdate(seq: 1, date: 80)
    let realtime2 = makeNewMessageUpdate(seq: 2, date: 90)
    await sync.process(updates: [realtime1, realtime2])

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 4

    var signal = InlineProtocol.Update()
    signal.update = .chatHasNewUpdates(payload)
    await sync.process(updates: [signal])

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 4
    }
    let applied = await apply.appliedUpdates
    #expect(applied.map { Int($0.seq) } == [1, 2, 3, 4])

    let stats = await sync.getStats()
    #expect(stats.bucketUpdatesDuplicateSkipped == 0)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 4)
  }

  @Test("fetch does not regress bucket state behind newer realtime updates")
  func testFetchDoesNotRegressAfterRealtimeAdvance() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let realtimeUpdate = makeNewMessageUpdate(seq: 1, date: 90)

    let getUpdates = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [realtimeUpdate],
      final: true,
      resultType: .slice
    )
    let client = FakeProtocolClient(responses: [getUpdates], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let firstSignal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)
    async let firstProcess: Void = sync.process(updates: [firstSignal])
    await client.waitForFirstCallStarted()

    // While the RPC is in flight, live seq1 waits behind the catch-up owner.
    // Its fetched duplicate must commit exactly once, not lose the message.
    await sync.process(updates: [realtimeUpdate])

    await client.releaseFirstCall()
    await firstProcess
    _ = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 1
    }

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 1)
    #expect(await apply.appliedUpdates == [realtimeUpdate])
    await sync.prepareForTermination()
  }

  @Test("authoritative user skip defeats a buffered obsolete grant across apply retry", arguments: [false, true])
  func testAuthoritativeSkipDropsBufferedGrant(failFirstApply: Bool) async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    if failFirstApply {
      await apply.setResultSequence([
        UpdateApplyResult(appliedCount: 0, failedCount: 1),
        .success(count: 1),
      ])
    }
    var grant = InlineProtocol.UpdateUserAddedToChat()
    grant.chatID = 7
    let obsoleteGrant = makeDurableUpdate(seq: 1, date: 90, payload: .userAddedToChat(grant))
    let update2 = makeDurableUpdate(seq: 2, date: 110, payload: .updateUserSettings(.init()))
    let update3 = makeDurableUpdate(seq: 3, date: 120, payload: .updateUserSettings(.init()))
    let firstPage = makeGetUpdatesResult(
      seq: 1, date: 100, updates: [], final: true, resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let retryPage = makeGetUpdatesResult(
      seq: 2, date: 110, updates: [update2], final: true, resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )
    let client = FakeProtocolClient(responses: [firstPage, retryPage], gateCallNumbers: [1, 2])
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { await activity.record($0) }
    // Current Sync ingress treats userAddedToChat as fetch-only. Exercise the
    // lower-level bucket authority invariant directly, without changing ingress.
    let actor = BucketActor(
      key: .user, seq: 0, date: 0, client: client, sync: sync,
      fetchLimiter: FetchLimiter(limit: 1), accountMutationToken: nil
    )
    _ = await actor.noteHasNewUpdates(upToSeq: 1)
    let firstFetch = Task { await actor.fetchNewUpdates() }
    await client.waitForCallStarted(1)
    await actor.processRealtimeUpdates([obsoleteGrant])
    #expect(await apply.appliedUpdates.isEmpty)
    await client.releaseCall(1)
    await firstFetch.value

    if failFirstApply {
      #expect(await storage.getBucketState(for: .user).seq == 0)
      #expect(await activity.sequence == [true])
      // The failed authoritative page still owns the retained grant. A new
      // contiguous event must not flush it or reset the delayed retry owner.
      await actor.processRealtimeUpdates([update2])
      #expect(await apply.appliedUpdates.isEmpty)
      #expect(await storage.getBucketState(for: .user).seq == 0)
      let immediateRefetch = await waitForCondition(timeout: .milliseconds(250)) {
        await client.getCallCount() > 1
      }
      #expect(immediateRefetch == false)
      #expect(await actor.wakeRetryIfNeeded())
      // Canceling the sleep does not release authority before the next fetch
      // owner has started; reconnect and live delivery can interleave here.
      await actor.processRealtimeUpdates([update2])
      #expect(await apply.appliedUpdates.isEmpty)
      #expect(await storage.getBucketState(for: .user).seq == 0)
      let retryFetch = Task { await actor.fetchNewUpdates() }
      await client.waitForCallStarted(2)
      await actor.processRealtimeUpdates([update3])
      await client.releaseCall(2)
      await retryFetch.value

      #expect(await apply.appliedUpdates == [update2, update3])
      #expect(await apply.appliedSources == [.syncCatchup, .realtime])
      #expect(await storage.getBucketState(for: .user).seq == 3)
      #expect(await client.getUpdatesEndSequences() == [1, 2])
    } else {
      #expect(await storage.getBucketState(for: .user).seq == 1)
      #expect(await apply.appliedUpdates.isEmpty)
      await actor.processRealtimeUpdates([update2])
      #expect(await apply.appliedUpdates == [update2])
      #expect(await apply.appliedSources == [.realtime])
      #expect(await storage.getBucketState(for: .user).seq == 2)
      #expect(await client.getUpdatesEndSequences() == [1])
    }
    #expect(await activity.sequence == [true, false])
    await actor.invalidate()
    await actor.waitUntilIdle()
    await sync.prepareForTermination()
  }

  @Test("future realtime messages wait for catch-up pointer")
  func testFutureRealtimeMessagesWaitForCatchupPointer() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let catchup1 = makeNewMessageUpdate(seq: 1, date: 80)
    let catchup2 = makeNewMessageUpdate(seq: 2, date: 90)
    let catchup3 = makeNewMessageUpdate(seq: 3, date: 100)
    let catchup = makeGetUpdatesResult(
      seq: 3,
      date: 100,
      updates: [catchup1, catchup2, catchup3],
      final: true,
      resultType: .slice
    )
    let client = FakeProtocolClient(responses: [catchup], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)
    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { await activity.record($0) }

    let peer = makeChatPeer(chatId: 1)
    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 3)
    async let fetch: Void = sync.process(updates: [signal])
    await client.waitForFirstCallStarted()

    let realtime4 = makeNewMessageUpdate(seq: 4, date: 110)
    let realtime5 = makeNewMessageUpdate(seq: 5, date: 120)
    await sync.process(updates: [realtime4, realtime5])

    let stateBeforeCatchup = await storage.getBucketState(for: .chat(peer: peer))
    #expect(stateBeforeCatchup.seq == 0)
    var applied = await apply.appliedUpdates
    #expect(applied.isEmpty)

    await client.releaseFirstCall()
    await fetch

    _ = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 5
    }

    applied = await apply.appliedUpdates
    let sources = await apply.appliedSources
    #expect(applied.map { Int($0.seq) } == [1, 2, 3, 4, 5])
    #expect(sources == [.syncCatchup, .syncCatchup, .syncCatchup, .realtime, .realtime])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(await client.getUpdatesStartSequences() == [0])
    #expect(await client.getUpdatesEndSequences() == [3])
    #expect(await waitForCondition { await activity.sequence == [true, false] })
    await sync.prepareForTermination()
  }

  @Test("failed live suffix after completed catch-up retains cursor, activity, and bounded retry")
  func testFailedRealtimeSuffixRetainsRetryAfterCatchup() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResultSequence([
      .success(count: 1),
      UpdateApplyResult(appliedCount: 0, failedCount: 1),
    ])
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 1, date: 100, updates: [makeNewMessageUpdate(seq: 1, date: 100)], final: true, resultType: .slice
    )], gateFirstCall: true)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: .default)
    let activity = SyncActivityRecorder()
    await sync.setSyncActivityListener { await activity.record($0) }
    let key = BucketKey.chat(peer: makeChatPeer(chatId: 1))
    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)])
    await client.waitForFirstCallStarted()
    await sync.process(updates: [makeNewMessageUpdate(seq: 2, date: 110)])
    await client.releaseFirstCall()

    #expect(await waitForCondition {
      let attemptedCount = await apply.appliedUpdates.count
      let bucket = await sync.getStats().buckets.first(where: { $0.key == key })
      return attemptedCount == 2 && bucket?.isFetching == false && bucket?.needsFetch == true
    })
    #expect(await storage.getBucketState(for: key).seq == 1)
    #expect(await apply.appliedSources == [.syncCatchup, .realtime])
    #expect(await activity.sequence == [true])
    #expect(await sync.getStats().activeBucketFetches == 1)
    let immediateRefetch = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(immediateRefetch == false)
    await sync.prepareForTermination()
  }

  @Test("each catch-up page commits its cursor and restarts from the last durable page")
  func testCatchupPageCommitAndRestart() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResultSequence([
      .success(count: 0),
      UpdateApplyResult(appliedCount: 0, failedCount: 1),
      .success(count: 0),
    ])
    let firstPage = makeGetUpdatesResult(
      seq: 100,
      date: 100,
      updates: [],
      final: false,
      resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 100)
    )
    let secondPage = makeGetUpdatesResult(
      seq: 150,
      date: 150,
      updates: [],
      final: true,
      resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 100, through: 150)
    )
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [.getUpdates: [firstPage, secondPage, secondPage]]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.process(updates: [makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 150)])
    let converged = await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 150
    }

    #expect(converged)
    #expect(await client.getUpdatesStartSequences() == [0, 100, 100])
    #expect(await client.getUpdatesEndSequences() == [150, 150, 150])
    let commits = await apply.bucketCommits
    #expect(commits.map(\.state.seq) == [100, 150, 150])
    #expect(commits.map(\.expectedStartState?.seq) == [0, 100, 100])
    #expect(await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 150)
  }

  @Test("global fetch limiter caps concurrent getUpdates RPCs across buckets")
  func testGlobalFetchLimiterCapsConcurrency() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1)
    )

    let client = FakeProtocolClient(responses: [response, response], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15, maxConcurrentBucketFetches: 1)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    var payload1 = InlineProtocol.UpdateChatHasNewUpdates()
    payload1.peerID = makeChatPeer(chatId: 1)
    payload1.updateSeq = 1

    var payload2 = InlineProtocol.UpdateChatHasNewUpdates()
    payload2.peerID = makeChatPeer(chatId: 2)
    payload2.updateSeq = 1

    var update1 = InlineProtocol.Update()
    update1.update = .chatHasNewUpdates(payload1)

    var update2 = InlineProtocol.Update()
    update2.update = .chatHasNewUpdates(payload2)

    await sync.process(updates: [update1, update2])
    await client.waitForFirstCallStarted()

    // The second fetch must not start while the first call is gated.
    let secondFetchStartedBeforeRelease = await waitForCondition(timeout: .milliseconds(150)) {
      await client.getCallCount() >= 2
    }
    #expect(secondFetchStartedBeforeRelease == false)
    let beforeRelease = await client.getCallCount()
    #expect(beforeRelease == 1)

    await client.releaseFirstCall()
    _ = await waitForCondition {
      await client.getCallCount() == 2
    }

    let afterRelease = await client.getCallCount()
    #expect(afterRelease == 2)
  }
}

// MARK: - Test Helpers

private func waitForCondition(
  timeout: Duration = .seconds(3),
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

final actor FakeProtocolClient: ProtocolClientType {
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()
  private let responseProvider: (@Sendable (InlineProtocol.Method, RpcCall.OneOf_Input?) async throws -> InlineProtocol.RpcResult.OneOf_Result?)?

  private var responses: [InlineProtocol.RpcResult.OneOf_Result?]
  private var methodResponses: [InlineProtocol.Method: [InlineProtocol.RpcResult.OneOf_Result?]]?
  private var methodErrors: [InlineProtocol.Method: [Error]]
  private var callCount = 0
  private var methods: [InlineProtocol.Method] = []
  private var updatesStateDates: [Int64?] = []
  private var updatesStartSequences: [Int64] = []
  private var updatesEndSequences: [Int64?] = []
  private var getChatRecentMessageFlags: [Bool] = []
  private var deferredGetUpdatesError: (afterCalls: Int, error: ProtocolSessionError)?

  func setError(afterGetUpdatesCalls count: Int, error: ProtocolSessionError) {
    deferredGetUpdatesError = (count, error)
  }

  private let gatedCalls: Set<Int>
  private let gatedMethods: Set<InlineProtocol.Method>
  private var startedCalls: Set<Int> = []
  private var callStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var callGates: [Int: CheckedContinuation<Void, Never>] = [:]
  private var methodGates: [InlineProtocol.Method: CheckedContinuation<Void, Never>] = [:]

  init(
    responses: [InlineProtocol.RpcResult.OneOf_Result?],
    gateFirstCall: Bool = false,
    gateCallNumbers: Set<Int> = [],
    gateMethods: Set<InlineProtocol.Method> = [],
    methodResponses: [InlineProtocol.Method: [InlineProtocol.RpcResult.OneOf_Result?]]? = nil,
    methodErrors: [InlineProtocol.Method: [Error]] = [:],
    responseProvider: (@Sendable (InlineProtocol.Method, RpcCall.OneOf_Input?) async throws -> InlineProtocol.RpcResult.OneOf_Result?)? = nil
  ) {
    self.responseProvider = responseProvider
    self.responses = responses
    var gates = gateCallNumbers
    if gateFirstCall {
      gates.insert(1)
    }
    gatedCalls = gates
    gatedMethods = gateMethods
    self.methodResponses = methodResponses
    self.methodErrors = methodErrors
  }

  func startTransport(sessionID _: UInt64) async {}

  func stopTransport() async {}

  func startHandshake(sessionID _: UInt64) async {}

  func sendPing(nonce: UInt64) async {}

  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 {
    0
  }

  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    callCount += 1
    let callNumber = callCount
    methods.append(method)
    if case let .getUpdatesState(payload)? = input {
      updatesStateDates.append(payload.hasDate ? payload.date : nil)
    } else if case let .getUpdates(payload)? = input {
      updatesStartSequences.append(payload.startSeq)
      updatesEndSequences.append(payload.seqEnd > 0 ? payload.seqEnd : nil)
    } else if case let .getChat(payload)? = input {
      getChatRecentMessageFlags.append(payload.includeRecentMessages)
    }
    signalCallStarted(callNumber)
    if gatedCalls.contains(callNumber) {
      await withCheckedContinuation { continuation in
        callGates[callNumber] = continuation
      }
    }
    if gatedMethods.contains(method) {
      await withCheckedContinuation { continuation in
        methodGates[method] = continuation
      }
    }

    if method == .getUpdates, let pending = deferredGetUpdatesError,
       updatesStartSequences.count > pending.afterCalls {
      deferredGetUpdatesError = nil
      throw pending.error
    }
    if let errorsForMethod = methodErrors[method], !errorsForMethod.isEmpty {
      var updated = errorsForMethod
      let error = updated.removeFirst()
      methodErrors[method] = updated
      throw error
    }

    if let responseProvider { return try await responseProvider(method, input) }
    if let responsesForMethod = methodResponses?[method], !responsesForMethod.isEmpty {
      var updated = responsesForMethod
      let value = updated.removeFirst()
      methodResponses?[method] = updated
      return value
    }

    if responses.isEmpty {
      return nil
    }
    return responses.removeFirst() ?? nil
  }

  func waitForFirstCallStarted() async {
    await waitForCallStarted(1)
  }

  func releaseFirstCall() {
    releaseCall(1)
  }

  func waitForCallStarted(_ callNumber: Int) async {
    if startedCalls.contains(callNumber) {
      return
    }
    await withCheckedContinuation { continuation in
      callStartWaiters[callNumber, default: []].append(continuation)
    }
  }

  func releaseCall(_ callNumber: Int) {
    guard let gate = callGates.removeValue(forKey: callNumber) else { return }
    gate.resume()
  }

  func releaseMethod(_ method: InlineProtocol.Method) {
    guard let gate = methodGates.removeValue(forKey: method) else { return }
    gate.resume()
  }

  func getCallCount() -> Int {
    callCount
  }

  func getCalledMethods() -> [InlineProtocol.Method] {
    methods
  }

  func getUpdatesStateDates() -> [Int64?] {
    updatesStateDates
  }

  func getUpdatesStartSequences() -> [Int64] {
    updatesStartSequences
  }

  func getUpdatesEndSequences() -> [Int64?] {
    updatesEndSequences
  }

  func getChatRecentMessageRequests() -> [Bool] {
    getChatRecentMessageFlags
  }

  private func signalCallStarted(_ callNumber: Int) {
    let inserted = startedCalls.insert(callNumber).inserted
    guard inserted else { return }
    for continuation in callStartWaiters[callNumber] ?? [] {
      continuation.resume()
    }
    callStartWaiters[callNumber] = nil
  }
}

actor RecordingApplyUpdates: ApplyUpdates {
  private(set) var appliedUpdates: [InlineProtocol.Update] = []
  private(set) var appliedSources: [UpdateApplySource] = []
  private(set) var appliedSidecars: [InlineProtocol.UpdateSidecars] = []
  private(set) var repairedChats: [ChatRepairSnapshot] = []
  private(set) var repairedSpaces: [SpaceRepairSnapshot] = []
  private(set) var repairedUsers: [UserRepairSnapshot] = []
  private(set) var persistedBootstrapProjectionKinds: [String] = []
  private(set) var bucketCommits: [UpdateBucketCommit] = []
  private var mutationTokens: [AuthAccountMutationToken] = []
  var result = UpdateApplyResult.success(count: 0)
  var resultSequence: [UpdateApplyResult] = []
  var repairResult = true
  var finalizationAttempts = 0
  var finalizeUserRepairResult = true
  var repairStorage: (any SyncStorage)?
  var userRepairOutcome: UserRepairOutcome?
  var bootstrapSeededStates: [BucketKey: BucketState] = [:]
  private var shouldGateNextApply = false
  private var applyGate: CheckedContinuation<Void, Never>?
  private var applyGateArrival: CheckedContinuation<Void, Never>?

  func gateNextApply() { shouldGateNextApply = true }

  func waitUntilApplyGated() async {
    if applyGate != nil { return }
    await withCheckedContinuation { applyGateArrival = $0 }
  }

  func releaseApply() {
    applyGate?.resume()
    applyGate = nil
  }

  func setResult(_ result: UpdateApplyResult) {
    self.result = result
  }

  func setResultSequence(_ results: [UpdateApplyResult]) {
    resultSequence = results
  }

  func setRepairResult(_ result: Bool) {
    repairResult = result
  }

  func setFinalizeUserRepairResult(_ result: Bool) {
    finalizeUserRepairResult = result
  }

  func setRepairStorage(_ storage: any SyncStorage) {
    repairStorage = storage
  }

  func setUserRepairOutcome(_ outcome: UserRepairOutcome?) {
    userRepairOutcome = outcome
  }

  func setBootstrapSeededStates(_ states: [BucketKey: BucketState]) {
    bootstrapSeededStates = states
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    if shouldGateNextApply {
      shouldGateNextApply = false
      await withCheckedContinuation { continuation in
        applyGate = continuation
        applyGateArrival?.resume()
        applyGateArrival = nil
      }
    }
    appliedUpdates.append(contentsOf: updates)
    appliedSources.append(contentsOf: Array(repeating: source, count: updates.count))
    if let sidecars {
      appliedSidecars.append(sidecars)
    }
    let nextResult: UpdateApplyResult
    if resultSequence.isEmpty {
      nextResult = result
    } else {
      nextResult = resultSequence.removeFirst()
    }
    guard nextResult.failedCount > 0 else {
      return .success(count: updates.count)
    }
    return nextResult
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?,
    mutationToken: AuthAccountMutationToken?
  ) async -> UpdateApplyResult {
    if let mutationToken {
      mutationTokens.append(mutationToken)
    }
    if let bucketCommit {
      bucketCommits.append(bucketCommit)
    }
    // This recorder does not own the SyncStorage transaction. Preserve the production fallback
    // by leaving committedBucketState nil while still observing the tokenized overload.
    return await apply(updates: updates, source: source, sidecars: sidecars)
  }

  func receivedMutationTokens() -> [AuthAccountMutationToken] {
    mutationTokens
  }

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> BucketState? {
    repairedChats.append(snapshot)
    guard repairResult else { return nil }
    await repairStorage?.setBucketState(
      for: .chat(peer: snapshot.peer),
      state: snapshot.targetState
    )
    return snapshot.targetState
  }

  func repairSpace(_ snapshot: SpaceRepairSnapshot) async -> BucketState? {
    repairedSpaces.append(snapshot)
    guard repairResult else { return nil }
    await repairStorage?.setBucketState(
      for: .space(id: snapshot.spaceID),
      state: snapshot.targetState
    )
    return snapshot.targetState
  }

  func repairUser(_ snapshot: UserRepairSnapshot) async -> UserRepairOutcome? {
    repairedUsers.append(snapshot)
    guard repairResult else { return nil }
    let outcome = userRepairOutcome ?? .applied(
      state: snapshot.checkpointState,
      seededStates: snapshot.bootstrapCatalogPersistence?.seededStates ?? [:],
      replayThroughState: snapshot.replayThroughState,
      retiredBucketKeys: []
    )
    if case let .applied(state, _, _, _) = outcome {
      _ = await repairStorage?.advanceBucketState(for: .user, state: state)
    }
    return outcome
  }

  func persistUserBootstrapProjection(
    _ snapshot: UserBootstrapProjectionSnapshot
  ) async -> UserBootstrapProjectionPersistence? {
    switch snapshot.projection {
      case .chats:
        persistedBootstrapProjectionKinds.append("chats")
        return .chats(UserBootstrapCatalogPersistence(
          checkpointState: snapshot.checkpointState,
          userStateAtPersistence: .init(date: 0, seq: 0),
          seededStates: bootstrapSeededStates,
          catchUpTargets: [:],
          retiredBucketKeys: []
        ))
      case .me:
        persistedBootstrapProjectionKinds.append("me")
        return .me
      case .settings:
        persistedBootstrapProjectionKinds.append("settings")
        return .settings
    }
  }

  func finalizeUserRepair(
    _ finalization: UserRepairFinalization,
    resolvedTargets: [BucketKey: UserRepairTargetResolution]
  ) async -> BucketState? {
    finalizationAttempts += 1
    guard repairResult,
          finalizeUserRepairResult,
          Set(resolvedTargets.keys) == Set(finalization.catchUpTargets.keys),
          finalization.catchUpTargets.allSatisfy({ key, target in
            guard let resolution = resolvedTargets[key] else { return false }
            return target == 0 ? resolution.authoritative : resolution.state.seq >= target
          })
    else { return nil }
    _ = await repairStorage?.advanceBucketState(
      for: .user,
      state: finalization.proposedUserState
    )
    return finalization.proposedUserState
  }
}

actor BucketCommitApplyRecorder: ApplyUpdates {
  private var commit: BucketState?

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    .success(count: updates.count)
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?
  ) async -> UpdateApplyResult {
    commit = bucketCommit?.state
    return UpdateApplyResult(
      appliedCount: updates.count,
      failedCount: 0,
      committedBucketState: bucketCommit?.state
    )
  }

  func receivedCommit() -> BucketState? {
    commit
  }
}

private actor InactiveSyncActivityGate {
  private var reachedInactive = false
  private var didGate = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var gate: CheckedContinuation<Void, Never>?

  func record(_ active: Bool) async {
    guard !active, !didGate else { return }
    didGate = true
    reachedInactive = true
    arrival?.resume()
    arrival = nil
    await withCheckedContinuation { gate = $0 }
  }

  func waitUntilInactive() async {
    if reachedInactive { return }
    await withCheckedContinuation { arrival = $0 }
  }

  func release() {
    gate?.resume()
    gate = nil
  }
}

private actor TransientBucketReadFailureStorage: SyncStorage {
  private struct ReadFailure: Error {}
  let base: InMemorySyncStorage
  let failingKey: BucketKey
  private(set) var attempts = 0

  init(base: InMemorySyncStorage, failingKey: BucketKey) {
    self.base = base
    self.failingKey = failingKey
  }

  func getState() async throws -> SyncState { await base.getState() }
  func setState(_ state: SyncState) async -> Bool { await base.setState(state) }
  func getBucketState(for key: BucketKey) async throws -> BucketState {
    attempts += 1
    if key == failingKey, attempts == 1 { throw ReadFailure() }
    return await base.getBucketState(for: key)
  }

  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    await base.setBucketState(for: key, state: state)
  }
  func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState? {
    await base.advanceBucketState(for: key, state: state)
  }
  func removeBucketState(for key: BucketKey) async -> Bool { await base.removeBucketState(for: key) }
  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool { await base.setBucketStates(states: states) }
  func clearSyncState() async -> Bool { await base.clearSyncState() }
}

actor SyncActivityRecorder {
  private(set) var sequence: [Bool] = []

  func record(_ value: Bool) {
    sequence.append(value)
  }

  func contains(_ value: Bool) -> Bool {
    sequence.contains(value)
  }
}

actor InMemorySyncStorage: SyncStorage {
  private var removalRevision: Int64 = 0
  func getRemovalRevision() -> Int64 {
    removalRevision
  }

  func setRemovalRevision(_ value: Int64) {
    removalRevision = value
  }
  private var state = SyncState(lastSyncDate: 0)
  private var bucketStates: [BucketKey: BucketState] = [:]
  private var stateWriteFailuresRemaining = 0
  private var failBucketStateWrites = false
  private var bucketStateWriteFailuresRemaining = 0
  private var clearCount = 0
  private var bucketReadKeys: [BucketKey] = []

  func readBucketKeys() -> [BucketKey] { bucketReadKeys }

  func setFailBucketStateWrites(_ value: Bool) {
    failBucketStateWrites = value
  }

  func failNextBucketStateWrites(_ count: Int) {
    bucketStateWriteFailuresRemaining = max(0, count)
  }

  func failNextStateWrites(_ count: Int) {
    stateWriteFailuresRemaining = max(0, count)
  }

  func getClearCount() -> Int {
    clearCount
  }

  func getState() async -> SyncState {
    state
  }

  @discardableResult
  func setState(_ state: SyncState) async -> Bool {
    if stateWriteFailuresRemaining > 0 {
      stateWriteFailuresRemaining -= 1
      return false
    }
    self.state = state
    return true
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    bucketReadKeys.append(key)
    return bucketStates[key] ?? BucketState(date: 0, seq: 0)
  }

  @discardableResult
  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    guard !shouldFailBucketStateWrite() else { return false }
    bucketStates[key] = state
    return true
  }

  func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState? {
    guard !shouldFailBucketStateWrite() else { return nil }
    if let existing = bucketStates[key], existing.seq > state.seq {
      return existing
    }
    let effective = BucketState(
      date: max(bucketStates[key]?.date ?? 0, state.date),
      seq: state.seq
    )
    bucketStates[key] = effective
    return effective
  }

  @discardableResult
  func removeBucketState(for key: BucketKey) async -> Bool {
    bucketStates.removeValue(forKey: key)
    return true
  }

  @discardableResult
  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool {
    guard !shouldFailBucketStateWrite() else { return false }
    for (key, state) in states {
      if let existing = bucketStates[key], existing.seq > state.seq {
        continue
      }
      bucketStates[key] = BucketState(
        date: max(bucketStates[key]?.date ?? 0, state.date),
        seq: state.seq
      )
    }
    return true
  }

  @discardableResult
  func clearSyncState() async -> Bool {
    clearCount += 1
    state = SyncState(lastSyncDate: 0)
    bucketStates.removeAll()
    return true
  }

  private func shouldFailBucketStateWrite() -> Bool {
    if failBucketStateWrites { return true }
    guard bucketStateWriteFailuresRemaining > 0 else { return false }
    bucketStateWriteFailuresRemaining -= 1
    return true
  }
}

private actor FailNextUserReadSyncStorage: SyncStorage {
  private struct InjectedReadFailure: Error {}

  private let base: InMemorySyncStorage
  private var shouldFailNextUserRead = false

  init(base: InMemorySyncStorage) {
    self.base = base
  }

  func failNextUserRead() {
    shouldFailNextUserRead = true
  }

  func getState() async throws -> SyncState {
    await base.getState()
  }

  func setState(_ state: SyncState) async -> Bool {
    await base.setState(state)
  }

  func getBucketState(for key: BucketKey) async throws -> BucketState {
    if key == .user, shouldFailNextUserRead {
      shouldFailNextUserRead = false
      throw InjectedReadFailure()
    }
    return await base.getBucketState(for: key)
  }

  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    await base.setBucketState(for: key, state: state)
  }

  func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState? {
    await base.advanceBucketState(for: key, state: state)
  }

  func removeBucketState(for key: BucketKey) async -> Bool {
    await base.removeBucketState(for: key)
  }

  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool {
    await base.setBucketStates(states: states)
  }

  func clearSyncState() async -> Bool {
    await base.clearSyncState()
  }
}

private actor ReadFailingSyncStorage: SyncStorage {
  private struct ReadFailure: Error {}

  func getState() async throws -> SyncState {
    throw ReadFailure()
  }

  func setState(_: SyncState) async -> Bool {
    true
  }

  func getBucketState(for _: BucketKey) async throws -> BucketState {
    throw ReadFailure()
  }

  func setBucketState(for _: BucketKey, state _: BucketState) async -> Bool {
    true
  }

  func advanceBucketState(for _: BucketKey, state: BucketState) async -> BucketState? {
    state
  }

  func removeBucketState(for _: BucketKey) async -> Bool {
    true
  }

  func setBucketStates(states _: [BucketKey: BucketState]) async -> Bool {
    true
  }

  func clearSyncState() async -> Bool {
    true
  }
}

private func makeChatPeer(chatId: Int64) -> InlineProtocol.Peer {
  var peer = InlineProtocol.Peer()
  var chat = InlineProtocol.PeerChat()
  chat.chatID = chatId
  peer.chat = chat
  return peer
}

private func makeChatHasNewUpdatesSignal(chatId: Int64, updateSeq: Int32) -> InlineProtocol.Update {
  var payload = InlineProtocol.UpdateChatHasNewUpdates()
  payload.peerID = makeChatPeer(chatId: chatId)
  payload.updateSeq = updateSeq

  var update = InlineProtocol.Update()
  update.update = .chatHasNewUpdates(payload)
  return update
}

private func makeSpaceHasNewUpdatesSignal(spaceId: Int64, updateSeq: Int32) -> InlineProtocol.Update {
  var payload = InlineProtocol.UpdateSpaceHasNewUpdates()
  payload.spaceID = spaceId
  payload.updateSeq = updateSeq

  var update = InlineProtocol.Update()
  update.update = .spaceHasNewUpdates(payload)
  return update
}

private func makeGetChatResult(
  chatId: Int64 = 1,
  seq: Int32,
  lastMessageId: Int64? = nil,
  pinnedMessageIds: [Int64] = []
) -> InlineProtocol.RpcResult.OneOf_Result {
  let peer = makeChatPeer(chatId: chatId)

  var chat = InlineProtocol.Chat()
  chat.id = chatId
  chat.title = "Chat \(chatId)"
  chat.peerID = peer
  chat.seq = seq
  if let lastMessageId {
    chat.lastMsgID = lastMessageId
  }

  var dialog = InlineProtocol.Dialog()
  dialog.peer = peer
  dialog.chatID = chatId
  dialog.unreadCount = 0

  var result = InlineProtocol.GetChatResult()
  result.chat = chat
  result.dialog = dialog
  result.pinnedMessageIds = pinnedMessageIds
  return .getChat(result)
}

private func makeGetSpaceResult(
  spaceId: Int64,
  seq: Int32
) -> InlineProtocol.RpcResult.OneOf_Result {
  var space = InlineProtocol.Space()
  space.id = spaceId
  space.name = "Space \(spaceId)"
  space.date = 100
  space.seq = seq
  var membership = InlineProtocol.Member()
  membership.id = 1
  membership.spaceID = spaceId
  membership.userID = 1
  membership.date = 100
  var result = InlineProtocol.GetSpaceResult()
  result.space = space
  result.membership = membership
  return .getSpace(result)
}

private func makeGetSpaceMembersResult(
  spaceId: Int64
) -> InlineProtocol.RpcResult.OneOf_Result {
  var user = InlineProtocol.User()
  user.id = 1
  user.firstName = "Member"
  var member = InlineProtocol.Member()
  member.id = 1
  member.spaceID = spaceId
  member.userID = 1
  member.date = 100
  var result = InlineProtocol.GetSpaceMembersResult()
  result.users = [user]
  result.members = [member]
  return .getSpaceMembers(result)
}

private func makeGetChatHistoryResult(
  messages: [InlineProtocol.Message] = []
) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetChatHistoryResult()
  result.messages = messages
  return .getChatHistory(result)
}

private func makeGetChatParticipantsResult() -> InlineProtocol.RpcResult.OneOf_Result {
  .getChatParticipants(InlineProtocol.GetChatParticipantsResult())
}

private func makeGetUpdatesResult(
  seq: Int64,
  date: Int64,
  updates: [InlineProtocol.Update],
  final: Bool,
  resultType: InlineProtocol.GetUpdatesResult.ResultType,
  sidecars: InlineProtocol.UpdateSidecars? = nil,
  skippedSequences: [InlineProtocol.SyncSkippedSequence] = []
) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetUpdatesResult()
  result.updates = updates
  result.seq = seq
  result.date = date
  result.final = final
  result.resultType = resultType
  result.skippedSequences = skippedSequences
  if let sidecars {
    result.sidecars = sidecars
  }
  return .getUpdates(result)
}

private func makeIrrelevantSkippedSequences(
  after startSeq: Int64,
  through endSeq: Int64
) -> [InlineProtocol.SyncSkippedSequence] {
  guard endSeq > startSeq else { return [] }
  return ((startSeq + 1) ... endSeq).map { seq in
    .with {
      $0.seq = seq
      $0.reason = .irrelevantToBucket
    }
  }
}

private func makeGetUpdatesStateResult(
  date: Int64,
  updatesFound: Bool? = nil,
  seq: Int32 = 0
) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetUpdatesStateResult()
  result.date = date
  result.seq = seq
  if let updatesFound {
    result.updatesFound = updatesFound
  }
  return .getUpdatesState(result)
}

private func makeNewMessageUpdate(seq: Int64, date: Int64) -> InlineProtocol.Update {
  let message = makeProtocolMessage(id: 1, chatId: 1)

  var payload = InlineProtocol.UpdateNewMessage()
  payload.message = message

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .newMessage(payload)
  return update
}

private func makeDurableUpdate(
  seq: Int64,
  date: Int64,
  payload: InlineProtocol.Update.OneOf_Update
) -> InlineProtocol.Update {
  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = payload
  return update
}

private func makeProtocolMessage(id: Int64, chatId: Int64) -> InlineProtocol.Message {
  var message = InlineProtocol.Message()
  message.id = id
  message.chatID = chatId
  message.peerID = makeChatPeer(chatId: chatId)
  return message
}

private final class MatchingLogSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private let fragment: String
  private var count = 0

  init(fragment: String) {
    self.fragment = fragment
  }

  var matchCount: Int {
    lock.withLock { count }
  }

  func write(_ event: LogEvent) {
    guard event.entry.message.contains(fragment) else { return }
    lock.withLock { count += 1 }
  }
}

private func makeChatSkipPtsUpdate(seq: Int64, date: Int64, chatId: Int64) -> InlineProtocol.Update {
  var payload = InlineProtocol.UpdateChatSkipPts()
  payload.chatID = chatId

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .chatSkipPts(payload)
  return update
}

private func makeUpdateReadMaxIdUpdate(
  seq: Int64,
  date: Int64,
  peer: InlineProtocol.Peer,
  readMaxId: Int64,
  unreadCount: Int32
) -> InlineProtocol.Update {
  var payload = InlineProtocol.UpdateReadMaxId()
  payload.peerID = peer
  payload.readMaxID = readMaxId
  payload.unreadCount = unreadCount

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .updateReadMaxID(payload)
  return update
}

private func makeSpaceMemberDeleteUpdate(
  seq: Int64,
  date: Int64,
  spaceId: Int64,
  userId: Int64
) -> InlineProtocol.Update {
  var payload = InlineProtocol.UpdateSpaceMemberDelete()
  payload.spaceID = spaceId
  payload.userID = userId

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .spaceMemberDelete(payload)
  return update
}

private func makeChatInfoUpdate(seq: Int64, date: Int64, chatId: Int64 = 1) -> InlineProtocol.Update {
  var payload = InlineProtocol.UpdateChatInfo()
  payload.chatID = chatId
  payload.title = "chat-\(seq)"

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .chatInfo(payload)
  return update
}

private func makeChatMovedUpdate(
  seq: Int64,
  date: Int64,
  chatId: Int64,
  oldSpaceId: Int64,
  newSpaceId: Int64
) -> InlineProtocol.Update {
  var chat = InlineProtocol.Chat()
  chat.id = chatId
  chat.peerID = makeChatPeer(chatId: chatId)

  var payload = InlineProtocol.UpdateChatMoved()
  payload.chat = chat
  payload.oldSpaceID = oldSpaceId
  payload.newSpaceID = newSpaceId

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .chatMoved(payload)
  return update
}

private func makeChatOpenUpdate(seq: Int64, date: Int64, chatId: Int64) -> InlineProtocol.Update {
  var chat = InlineProtocol.Chat()
  chat.id = chatId
  chat.peerID = makeChatPeer(chatId: chatId)

  var dialog = InlineProtocol.Dialog()
  dialog.chatID = chatId

  var payload = InlineProtocol.UpdateChatOpen()
  payload.chat = chat
  payload.dialog = dialog

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .chatOpen(payload)
  return update
}
