import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("SyncTests")
class SyncTests {
  @Test("updates lastSyncDate with safety gap")
  func testLastSyncDateSafetyGap() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
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
    #expect(state.lastSyncDate == 85)
  }

  @Test("coalesces bucket fetches while in-flight")
  func testCoalescedFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let response = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(responses: [response, response], gateFirstCall: true)
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 1

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    Task { await sync.process(updates: [update]) }
    await client.waitForFirstCallStarted()

    await sync.process(updates: [update])

    await client.releaseFirstCall()
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
    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
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
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
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

  @Test("message updates are gated by config")
  func testMessageUpdatesToggle() async throws {
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

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 1

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])

    _ = await waitForCondition {
      await client.getCallCount() == 1
    }

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
  }

  @Test("message updates apply when enabled")
  func testMessageUpdatesEnabled() async throws {
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

    let client = FakeProtocolClient(responses: [response])
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
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

  @Test("TOO_LONG slices within max total and updates bucket state")
  func testTooLongSlicesWhenWarm() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    let slice = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(responses: [tooLong, slice])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 150, seq: 5))
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 10

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    _ = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 10 && bucketState.date == 200
    }

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let callCount = await client.getCallCount()
    #expect(callCount == 2)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
  }

  @Test("cold start TOO_LONG fast-forwards without looping")
  func testTooLongFastForwardsWhenCold() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )

    let client = FakeProtocolClient(responses: [tooLong])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 10

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    _ = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 10 && bucketState.date == 200
    }

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let callCount = await client.getCallCount()
    #expect(callCount == 1)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
  }

  @Test("TOO_LONG (legacy) slices locally instead of fast-forwarding")
  func testTooLongLegacyServerSlicesLocally() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    // Simulate legacy server semantics where TOO_LONG.seq is the latest seq (far ahead),
    // not a slice boundary.
    let tooLongLatest = makeGetUpdatesResult(
      seq: 2005,
      date: 500,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    // First slice: currentSeq=5 -> boundary=1005
    let slice1005 = makeGetUpdatesResult(
      seq: 1005,
      date: 200,
      updates: [],
      final: true,
      resultType: .empty
    )
    // Second TOO_LONG still reports latest=2005.
    let tooLongLatestAgain = tooLongLatest
    // Final slice: boundary reaches latest=2005.
    let slice2005 = makeGetUpdatesResult(
      seq: 2005,
      date: 500,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(responses: [tooLongLatest, slice1005, tooLongLatestAgain, slice2005])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    await storage.setBucketState(for: .chat(peer: peer), state: BucketState(date: 150, seq: 5))
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    _ = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 2005
    }

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2005)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 2)

    let callCount = await client.getCallCount()
    #expect(callCount == 4)
  }

  @Test("getUpdatesState response advances lastSyncDate")
  func testGetUpdatesStateAdvancesLastSyncDate() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let now = Int64(Date().timeIntervalSince1970)
    let getUpdatesState = makeGetUpdatesStateResult(date: now)
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
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.connectionStateChanged(state: .connected)
    await Task.yield()
    _ = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == max(0, now - 15)
    }

    let state = await storage.getState()
    #expect(state.lastSyncDate == max(0, now - 15))
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
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer

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
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
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

  @Test("config updates propagate to existing buckets")
  func testConfigUpdatePropagates() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let empty = makeGetUpdatesResult(
      seq: 0,
      date: 0,
      updates: [],
      final: true,
      resultType: .empty
    )
    let messageUpdate = makeNewMessageUpdate(seq: 1, date: 100)
    let messageSlice = makeGetUpdatesResult(
      seq: 1,
      date: 100,
      updates: [messageUpdate],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [empty, messageSlice])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])

    await sync.updateConfig(SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15))

    await sync.process(updates: [update])
    _ = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
  }

  @Test("connected state triggers user bucket fetch and updates state call")
  func testConnectionTriggersUserFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.connectionStateChanged(state: .connected)
    await Task.yield()
    _ = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState) && methods.contains(.getUpdates)
    }

    let methods = await client.getCalledMethods()
    #expect(methods.contains(.getUpdatesState))
    #expect(methods.contains(.getUpdates))
  }

  @Test("user bucket catch-up applies updateReadMaxId")
  func testUserBucketAppliesUpdateReadMaxId() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let now = Int64(Date().timeIntervalSince1970)
    let getUpdatesState = makeGetUpdatesStateResult(date: now)
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
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.connectionStateChanged(state: .connected)
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

  @Test("buffers out-of-order realtime updates and repairs gap via fetch")
  func testRealtimeOutOfOrderIsBufferedUntilGapRepair() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let update1 = makeNewMessageUpdate(seq: 1, date: 80)
    let getUpdates = makeGetUpdatesResult(
      seq: 1,
      date: 80,
      updates: [update1],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [getUpdates])
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    // Receive seq=2 first (out-of-order). This should buffer and trigger a fetch for seq=1.
    let update2 = makeNewMessageUpdate(seq: 2, date: 90)
    await sync.process(updates: [update2])
    _ = await waitForCondition {
      await apply.appliedUpdates.count == 2
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    #expect(seqs == [1, 2])

    let peer = makeChatPeer(chatId: 1)
    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
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
      seq: 1,
      date: 80,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(
      responses: [firstSlice, finalSlice],
      gateCallNumbers: [2]
    )
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 2

    var signal = InlineProtocol.Update()
    signal.update = .chatHasNewUpdates(payload)

    Task { await sync.process(updates: [signal]) }
    await client.waitForCallStarted(2)

    let realtime1 = makeNewMessageUpdate(seq: 1, date: 80)
    let realtime2 = makeNewMessageUpdate(seq: 2, date: 90)
    await sync.process(updates: [realtime1, realtime2])

    await client.releaseCall(2)

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 2
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    #expect(seqs == [1, 2])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
  }

  @Test("realtime structural updates do not overtake pending catch-up batch when message sync is disabled")
  func testRealtimeDoesNotOvertakePendingCatchupBatchWhenMessageSyncDisabled() async throws {
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
      seq: 1,
      date: 80,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(
      responses: [firstSlice, finalSlice],
      gateCallNumbers: [2]
    )
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 2

    var signal = InlineProtocol.Update()
    signal.update = .chatHasNewUpdates(payload)

    Task { await sync.process(updates: [signal]) }
    await client.waitForCallStarted(2)

    let realtime2 = makeChatInfoUpdate(seq: 2, date: 90)
    await sync.process(updates: [realtime2])

    await client.releaseCall(2)

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 2
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    #expect(seqs == [1, 2])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
  }

  @Test("stale getUpdates seq behind local does not loop and realtime can continue")
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
    let client = FakeProtocolClient(responses: [stale])
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
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

    // Ensure stale server cursor does not trigger repeated fetch attempts.
    let looped = await waitForCondition(timeout: .milliseconds(200)) {
      await client.getCallCount() > 1
    }
    #expect(looped == false)

    let realtime6 = makeNewMessageUpdate(seq: 6, date: 130)
    await sync.process(updates: [realtime6])

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }
    let applied = await apply.appliedUpdates
    #expect(applied.map { Int($0.seq) } == [6])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 6)
  }

  @Test("non-progress getUpdates response does not spin fetch loop")
  func testNonProgressGetUpdatesDoesNotSpin() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let nonProgress = makeGetUpdatesResult(
      seq: 5,
      date: 120,
      updates: [],
      final: false,
      resultType: .empty
    )
    let client = FakeProtocolClient(responses: [nonProgress])
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
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

    let spun = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(spun == false)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
  }

  @Test("non-progress getUpdates with buffered realtime does not busy-loop")
  func testNonProgressWithBufferedRealtimeDoesNotBusyLoop() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let nonProgress = makeGetUpdatesResult(
      seq: 0,
      date: 120,
      updates: [],
      final: false,
      resultType: .empty
    )
    let client = FakeProtocolClient(responses: [nonProgress])
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let realtime2 = makeNewMessageUpdate(seq: 2, date: 130)
    await sync.process(updates: [realtime2])

    _ = await waitForCondition {
      await client.getCallCount() == 1
    }

    let spun = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(spun == false)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
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
      seq: 3,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(
      responses: [firstSlice, secondSlice],
      gateCallNumbers: [2]
    )
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 5

    var signal = InlineProtocol.Update()
    signal.update = .chatHasNewUpdates(payload)

    Task { await sync.process(updates: [signal]) }
    await client.waitForCallStarted(2)

    let realtime4 = makeNewMessageUpdate(seq: 4, date: 110)
    let realtime5 = makeNewMessageUpdate(seq: 5, date: 120)
    await sync.process(updates: [realtime4, realtime5])

    await client.releaseCall(2)

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 5
    }
    let applied = await apply.appliedUpdates
    #expect(applied.map { Int($0.seq) } == [1, 2, 3, 4, 5])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
  }

  @Test("catch-up skips seqs already applied by realtime")
  func testCatchupSkipsAlreadyAppliedRealtimeSeqs() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let catchup1 = makeNewMessageUpdate(seq: 1, date: 80)
    let catchup2 = makeNewMessageUpdate(seq: 2, date: 90)
    let catchup3 = makeNewMessageUpdate(seq: 3, date: 100)
    let catchup4 = makeNewMessageUpdate(seq: 4, date: 110)
    let catchup = makeGetUpdatesResult(
      seq: 4,
      date: 110,
      updates: [catchup1, catchup2, catchup3, catchup4],
      final: true,
      resultType: .slice
    )
    let client = FakeProtocolClient(responses: [catchup])
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
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
    #expect(stats.bucketUpdatesDuplicateSkipped == 2)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 4)
  }

  @Test("fetch does not regress bucket state behind newer realtime updates")
  func testFetchDoesNotRegressAfterRealtimeAdvance() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let getUpdates = makeGetUpdatesResult(
      seq: 0,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty
    )
    let client = FakeProtocolClient(responses: [getUpdates], gateFirstCall: true)
    let config = SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer
    payload.updateSeq = 1

    var signal = InlineProtocol.Update()
    signal.update = .chatHasNewUpdates(payload)

    Task { await sync.process(updates: [signal]) }
    await client.waitForFirstCallStarted()

    // While the fetch is in-flight (awaiting callRpc), a realtime update advances the bucket to seq=1.
    let realtimeUpdate = makeNewMessageUpdate(seq: 1, date: 90)
    await sync.process(updates: [realtimeUpdate])

    await client.releaseFirstCall()
    _ = await waitForCondition {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 1
    }

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 1)
  }

  @Test("global fetch limiter caps concurrent getUpdates RPCs across buckets")
  func testGlobalFetchLimiterCapsConcurrency() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let response = makeGetUpdatesResult(
      seq: 0,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty
    )

    let client = FakeProtocolClient(responses: [response, response], gateFirstCall: true)
    let config = SyncConfig(enableMessageUpdates: false, lastSyncSafetyGapSeconds: 15, maxConcurrentBucketFetches: 1)
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
  timeout: Duration = .seconds(1),
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
  nonisolated let events = AsyncChannel<ProtocolSessionEvent>()

  private var responses: [InlineProtocol.RpcResult.OneOf_Result?]
  private var methodResponses: [InlineProtocol.Method: [InlineProtocol.RpcResult.OneOf_Result?]]?
  private var callCount = 0
  private var methods: [InlineProtocol.Method] = []

  private let gatedCalls: Set<Int>
  private var startedCalls: Set<Int> = []
  private var callStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var callGates: [Int: CheckedContinuation<Void, Never>] = [:]

  init(
    responses: [InlineProtocol.RpcResult.OneOf_Result?],
    gateFirstCall: Bool = false,
    gateCallNumbers: Set<Int> = [],
    methodResponses: [InlineProtocol.Method: [InlineProtocol.RpcResult.OneOf_Result?]]? = nil
  ) {
    self.responses = responses
    var gates = gateCallNumbers
    if gateFirstCall {
      gates.insert(1)
    }
    gatedCalls = gates
    self.methodResponses = methodResponses
  }

  func startTransport() async {}

  func stopTransport() async {}

  func startHandshake() async {}

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
    signalCallStarted(callNumber)
    if gatedCalls.contains(callNumber) {
      await withCheckedContinuation { continuation in
        callGates[callNumber] = continuation
      }
    }

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

  func getCallCount() -> Int {
    callCount
  }

  func getCalledMethods() -> [InlineProtocol.Method] {
    methods
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

  func apply(updates: [InlineProtocol.Update], source: UpdateApplySource) async {
    appliedUpdates.append(contentsOf: updates)
  }
}

actor InMemorySyncStorage: SyncStorage {
  private var state = SyncState(lastSyncDate: 0)
  private var bucketStates: [BucketKey: BucketState] = [:]

  func getState() async -> SyncState {
    state
  }

  func setState(_ state: SyncState) async {
    self.state = state
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    bucketStates[key] ?? BucketState(date: 0, seq: 0)
  }

  func setBucketState(for key: BucketKey, state: BucketState) async {
    bucketStates[key] = state
  }

  func setBucketStates(states: [BucketKey: BucketState]) async {
    for (key, state) in states {
      bucketStates[key] = state
    }
  }

  func clearSyncState() async {
    state = SyncState(lastSyncDate: 0)
    bucketStates.removeAll()
  }
}

private func makeChatPeer(chatId: Int64) -> InlineProtocol.Peer {
  var peer = InlineProtocol.Peer()
  var chat = InlineProtocol.PeerChat()
  chat.chatID = chatId
  peer.chat = chat
  return peer
}

private func makeGetUpdatesResult(
  seq: Int64,
  date: Int64,
  updates: [InlineProtocol.Update],
  final: Bool,
  resultType: InlineProtocol.GetUpdatesResult.ResultType
) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetUpdatesResult()
  result.updates = updates
  result.seq = seq
  result.date = date
  result.final = final
  result.resultType = resultType
  return .getUpdates(result)
}

private func makeGetUpdatesStateResult(date: Int64) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetUpdatesStateResult()
  result.date = date
  return .getUpdatesState(result)
}

private func makeNewMessageUpdate(seq: Int64, date: Int64) -> InlineProtocol.Update {
  var message = InlineProtocol.Message()
  message.id = 1
  message.chatID = 1
  message.peerID = makeChatPeer(chatId: 1)

  var payload = InlineProtocol.UpdateNewMessage()
  payload.message = message

  var update = InlineProtocol.Update()
  update.seq = Int32(seq)
  update.date = date
  update.update = .newMessage(payload)
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
