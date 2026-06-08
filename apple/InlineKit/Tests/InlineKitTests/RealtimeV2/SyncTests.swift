import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("SyncTests")
final class SyncTests {
  @Test("sync config defaults")
  func testSyncConfigDefaults() {
    #expect(SyncConfig.default.lastSyncSafetyGapSeconds == 15)
    #expect(SyncConfig.default.maxConcurrentBucketFetches == 4)
  }

  @Test("realtime config store returns sync defaults")
  func testRealtimeConfigStoreInitialConfig() {
    let config = RealtimeConfigStore.initialSyncConfig()
    #expect(config.lastSyncSafetyGapSeconds == SyncConfig.default.lastSyncSafetyGapSeconds)
    #expect(config.maxConcurrentBucketFetches == SyncConfig.default.maxConcurrentBucketFetches)
  }

  @Test("updates lastSyncDate with safety gap")
  func testLastSyncDateSafetyGap() async throws {
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
    #expect(state.lastSyncDate == 85)
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
      resultType: .empty
    )
    let secondResponse = makeGetUpdatesResult(
      seq: 2,
      date: 101,
      updates: [],
      final: true,
      resultType: .empty
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
      resultType: .empty
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
      resultType: .empty
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
      resultType: .empty
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
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
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

  @Test("cold chat TOO_LONG repairs chat snapshot and advances")
  func testColdChatTooLongRepairsAndAdvances() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )

    let historyMessage = makeProtocolMessage(id: 10, chatId: 1)
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [tooLong],
        .getChat: [makeGetChatResult(chatId: 1)],
        .getChatHistory: [makeGetChatHistoryResult(messages: [historyMessage])],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 10)
    await sync.process(updates: [signal])
    _ = await waitForCondition {
      await apply.repairedChats.count == 1
    }

    let repaired = await apply.repairedChats
    #expect(repaired.count == 1)
    let snapshot = try #require(repaired.first)
    #expect(snapshot.reason == "cold_too_long")
    #expect(snapshot.history.messages.map(\.id) == [10])

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let callCount = await client.getCallCount()
    #expect(callCount == 3)

    let methods = await client.getCalledMethods()
    #expect(methods == [.getUpdates, .getChat, .getChatHistory])
  }

  @Test("cold chat TOO_LONG falls back to slicing when repair fails")
  func testColdChatTooLongFallsBackToSlicingWhenRepairFails() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let tooLong = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [],
      final: false,
      resultType: .tooLong
    )
    let message = makeNewMessageUpdate(seq: 10, date: 200)
    let slice = makeGetUpdatesResult(
      seq: 10,
      date: 200,
      updates: [message],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [tooLong, slice],
        .getChat: [nil],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 10)
    await sync.process(updates: [signal])

    _ = await waitForCondition {
      await apply.appliedUpdates.count == 1
    }

    let applied = await apply.appliedUpdates
    #expect(applied.map { Int($0.seq) } == [10])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let callCount = await client.getCallCount()
    #expect(callCount == 3)
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
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
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

  @Test("getUpdatesState response with updates does not advance lastSyncDate")
  func testGetUpdatesStateWithUpdatesDoesNotAdvanceLastSyncDate() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let now = Int64(Date().timeIntervalSince1970)
    let initialDate = now - 60
    await storage.setState(SyncState(lastSyncDate: initialDate))

    let getUpdatesState = makeGetUpdatesStateResult(date: now, updatesFound: true)
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

    await sync.connectionStateChanged(state: .connected)
    let didCallState = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState)
    }
    #expect(didCallState)

    let state = await storage.getState()
    #expect(state.lastSyncDate == initialDate)
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

    await sync.connectionStateChanged(state: .connected)
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

  @Test("connected state triggers user bucket fetch and updates state call")
  func testConnectionTriggersUserFetch() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
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

  @Test("too old sync state uses bounded lookback")
  func testTooOldSyncStateUsesBoundedLookback() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let day: Int64 = 24 * 60 * 60
    let before = Int64(Date().timeIntervalSince1970)
    await storage.setState(SyncState(lastSyncDate: before - 15 * day))

    await sync.connectionStateChanged(state: .connected)
    let didCallState = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState)
    }
    #expect(didCallState)

    let after = Int64(Date().timeIntervalSince1970)
    let state = await storage.getState()
    #expect(state.lastSyncDate >= before - 5 * day - 2)
    #expect(state.lastSyncDate <= after - 5 * day + 2)
  }

#if DEBUG || DEBUG_BUILD
  @Test("debug zero-date scenario queues bounded discovery")
  func testDebugZeroDateScenarioQueuesBoundedDiscovery() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let before = Int64(Date().timeIntervalSince1970)
    let result = await sync.runDebugScenario(.seedZeroDateAndFetch)
    #expect(result.succeeded)

    let didCallState = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState)
    }
    #expect(didCallState)

    let after = Int64(Date().timeIntervalSince1970)
    let day: Int64 = 24 * 60 * 60
    let state = await storage.getState()
    #expect(state.lastSyncDate >= before - 5 * day - 2)
    #expect(state.lastSyncDate <= after - 5 * day + 2)
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
  }

  @Test("debug bucket rewind reports no tracked buckets")
  func testDebugBucketRewindReportsNoTrackedBuckets() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(responses: [])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let result = await sync.runDebugScenario(.rewindTrackedBucketsAndFetch)
    #expect(!result.succeeded)
  }
#endif

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
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
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
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100)],
        .getUpdates: [response],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.connectionStateChanged(state: .connected)
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

  @Test("catch-up apply failure does not advance bucket state")
  func testCatchUpApplyFailureDoesNotAdvanceBucketState() async throws {
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

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
    #expect(bucketState.date == 100)
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
  }

  @Test("non-retryable bucket error clears bucket state")
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
            errorCode: "PEER_ID_INVALID",
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

    let didFetch = await waitForCondition(timeout: .milliseconds(500)) {
      await client.getCallCount() == 1
    }
    #expect(didFetch)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 0)
    #expect(bucketState.date == 0)
  }

  @Test("realtime apply failure does not advance bucket state")
  func testRealtimeApplyFailureDoesNotAdvanceBucketState() async throws {
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
  }

  @Test("non-retryable fetch clears buffered realtime failure")
  func testNonRetryableFetchClearsBufferedRealtimeFailure() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResult(UpdateApplyResult(appliedCount: 0, failedCount: 1))

    let peer = makeChatPeer(chatId: 1)
    let invalidPeer = ProtocolSessionError.rpcError(
      errorCode: "peerIDInvalid",
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

    let update = makeNewMessageUpdate(seq: 1, date: 100)
    await sync.process(updates: [update])

    _ = await waitForCondition {
      await client.getCallCount() == 1
    }

    let refetched = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 1
    }
    #expect(refetched == false)

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 0)
    #expect(bucketState.date == 0)
  }

  @Test("non-retryable fetch invalidates queued bucket actor work")
  func testNonRetryableFetchInvalidatesQueuedBucketActorWork() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setResult(UpdateApplyResult(appliedCount: 0, failedCount: 1))

    let invalidPeer = ProtocolSessionError.rpcError(
      errorCode: "peerIDInvalid",
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

    let first = makeNewMessageUpdate(seq: 1, date: 100)
    await sync.process(updates: [first])
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
    let getUpdates = makeGetUpdatesResult(
      seq: 1,
      date: 80,
      updates: [update1],
      final: true,
      resultType: .slice
    )

    let client = FakeProtocolClient(responses: [getUpdates])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
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
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [nonProgress],
        .getChat: [makeGetChatResult(chatId: 1)],
        .getChatHistory: [makeGetChatHistoryResult()],
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
    _ = await waitForCondition {
      await client.getCallCount() == 3
    }

    let spun = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 3
    }
    #expect(spun == false)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
    let repaired = await apply.repairedChats
    #expect(repaired.count == 1)
    let snapshot = try #require(repaired.first)
    #expect(snapshot.reason == "non_progress")

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
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdates: [nonProgress],
        .getChat: [makeGetChatResult(chatId: 1)],
        .getChatHistory: [makeGetChatHistoryResult()],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let realtime2 = makeNewMessageUpdate(seq: 2, date: 130)
    await sync.process(updates: [realtime2])

    _ = await waitForCondition {
      await client.getCallCount() == 3
    }

    let spun = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCallCount() > 3
    }
    #expect(spun == false)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
    let repaired = await apply.repairedChats
    #expect(repaired.count == 1)
    let snapshot = try #require(repaired.first)
    #expect(snapshot.reason == "non_progress")
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
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let firstSignal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 1)
    async let firstProcess: Void = sync.process(updates: [firstSignal])
    await client.waitForFirstCallStarted()

    // While the fetch is in-flight (awaiting callRpc), a realtime update advances the bucket to seq=1.
    let realtimeUpdate = makeNewMessageUpdate(seq: 1, date: 90)
    await sync.process(updates: [realtimeUpdate])

    await client.releaseFirstCall()
    await firstProcess
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
  private var methodErrors: [InlineProtocol.Method: [Error]]
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
    methodResponses: [InlineProtocol.Method: [InlineProtocol.RpcResult.OneOf_Result?]]? = nil,
    methodErrors: [InlineProtocol.Method: [Error]] = [:]
  ) {
    self.responses = responses
    var gates = gateCallNumbers
    if gateFirstCall {
      gates.insert(1)
    }
    gatedCalls = gates
    self.methodResponses = methodResponses
    self.methodErrors = methodErrors
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

    if let errorsForMethod = methodErrors[method], !errorsForMethod.isEmpty {
      var updated = errorsForMethod
      let error = updated.removeFirst()
      methodErrors[method] = updated
      throw error
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
  private(set) var appliedSidecars: [InlineProtocol.UpdateSidecars] = []
  private(set) var repairedChats: [ChatRepairSnapshot] = []
  var result = UpdateApplyResult.success(count: 0)
  var repairResult = true

  func setResult(_ result: UpdateApplyResult) {
    self.result = result
  }

  func setRepairResult(_ result: Bool) {
    repairResult = result
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    appliedUpdates.append(contentsOf: updates)
    if let sidecars {
      appliedSidecars.append(sidecars)
    }
    guard result.failedCount > 0 else {
      return .success(count: updates.count)
    }
    return result
  }

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> Bool {
    repairedChats.append(snapshot)
    return repairResult
  }
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
  private var state = SyncState(lastSyncDate: 0)
  private var bucketStates: [BucketKey: BucketState] = [:]
  private var failBucketStateWrites = false
  private var clearCount = 0

  func setFailBucketStateWrites(_ value: Bool) {
    failBucketStateWrites = value
  }

  func getClearCount() -> Int {
    clearCount
  }

  func getState() async -> SyncState {
    state
  }

  @discardableResult
  func setState(_ state: SyncState) async -> Bool {
    self.state = state
    return true
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    bucketStates[key] ?? BucketState(date: 0, seq: 0)
  }

  @discardableResult
  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    guard !failBucketStateWrites else { return false }
    bucketStates[key] = state
    return true
  }

  @discardableResult
  func removeBucketState(for key: BucketKey) async -> Bool {
    bucketStates.removeValue(forKey: key)
    return true
  }

  @discardableResult
  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool {
    guard !failBucketStateWrites else { return false }
    for (key, state) in states {
      bucketStates[key] = state
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

private func makeGetChatResult(chatId: Int64 = 1) -> InlineProtocol.RpcResult.OneOf_Result {
  let peer = makeChatPeer(chatId: chatId)

  var chat = InlineProtocol.Chat()
  chat.id = chatId
  chat.title = "Chat \(chatId)"
  chat.peerID = peer

  var dialog = InlineProtocol.Dialog()
  dialog.peer = peer
  dialog.chatID = chatId

  var result = InlineProtocol.GetChatResult()
  result.chat = chat
  result.dialog = dialog
  return .getChat(result)
}

private func makeGetChatHistoryResult(
  messages: [InlineProtocol.Message] = []
) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetChatHistoryResult()
  result.messages = messages
  return .getChatHistory(result)
}

private func makeGetUpdatesResult(
  seq: Int64,
  date: Int64,
  updates: [InlineProtocol.Update],
  final: Bool,
  resultType: InlineProtocol.GetUpdatesResult.ResultType,
  sidecars: InlineProtocol.UpdateSidecars? = nil
) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetUpdatesResult()
  result.updates = updates
  result.seq = seq
  result.date = date
  result.final = final
  result.resultType = resultType
  if let sidecars {
    result.sidecars = sidecars
  }
  return .getUpdates(result)
}

private func makeGetUpdatesStateResult(
  date: Int64,
  updatesFound: Bool? = nil
) -> InlineProtocol.RpcResult.OneOf_Result {
  var result = InlineProtocol.GetUpdatesStateResult()
  result.date = date
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

private func makeProtocolMessage(id: Int64, chatId: Int64) -> InlineProtocol.Message {
  var message = InlineProtocol.Message()
  message.id = id
  message.chatID = chatId
  message.peerID = makeChatPeer(chatId: chatId)
  return message
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
