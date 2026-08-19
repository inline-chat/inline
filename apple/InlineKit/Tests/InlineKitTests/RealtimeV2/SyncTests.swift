import AsyncAlgorithms
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

@Suite("SyncTests", .serialized)
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
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 5, through: 10)
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
    await apply.setRepairStorage(storage)

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
        .getChatParticipants: [makeGetChatParticipantsResult()],
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
    #expect(callCount == 4)

    let methods = await client.getCalledMethods()
    #expect(methods == [.getUpdates, .getChat, .getChatParticipants, .getChatHistory])
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
      resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 9)
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
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 5, through: 1005)
    )
    // Second TOO_LONG still reports latest=2005.
    let tooLongLatestAgain = tooLongLatest
    // Final slice: boundary reaches latest=2005.
    let slice2005 = makeGetUpdatesResult(
      seq: 2005,
      date: 500,
      updates: [],
      final: true,
      resultType: .empty,
      skippedSequences: makeIrrelevantSkippedSequences(after: 1005, through: 2005)
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
            seq: 0,
            date: 10,
            updates: [],
            final: true,
            resultType: .empty
          ),
          makeGetUpdatesResult(
            seq: 1,
            date: 100,
            updates: [failedChatUpdate],
            final: true,
            resultType: .slice
          ),
          makeGetUpdatesResult(
            seq: 0,
            date: 120,
            updates: [],
            final: true,
            resultType: .empty
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

    await sync.connectionStateChanged(state: .connected)
    try #require(await waitForCondition {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState) && methods.contains(.getUpdates)
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

    await sync.connectionStateChanged(state: .connected)
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

  @Test("fresh connection installs the current checkpoint without catch-up")
  func testFreshConnectionInstallsCurrentCheckpoint() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let checkpoint = makeGetUpdatesStateResult(date: 100, seq: 42)
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [checkpoint],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.connectionStateChanged(state: .connected)
    await Task.yield()
    let didInstallCheckpoint = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 100
    }
    #expect(didInstallCheckpoint)

    let methods = await client.getCalledMethods()
    #expect(methods.contains(.getUpdatesState))
    #expect(methods.contains(.getUpdates) == false)
    #expect(await client.getUpdatesStateDates() == [nil])
    #expect(await client.getUpdatesStartSequences().isEmpty)
    #expect(await storage.getState().lastSyncDate == 100)
    #expect(await storage.getBucketState(for: .user).seq == 42)
  }

  @Test("fresh checkpoint does not regress a partially persisted user cursor")
  func testFreshCheckpointPreservesNewerUserCursor() async throws {
    let storage = InMemorySyncStorage()
    await storage.setBucketState(for: .user, state: BucketState(date: 110, seq: 50))
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 100, seq: 42)],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.connectionStateChanged(state: .connected)
    let didInstallCheckpoint = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 100
    }

    #expect(didInstallCheckpoint)
    let userState = await storage.getBucketState(for: .user)
    #expect(userState.seq == 50)
    #expect(userState.date == 110)
    #expect(await client.getCalledMethods().contains(.getUpdates) == false)
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
        ],
        .getUpdates: [makeGetUpdatesResult(
          seq: 42,
          date: 100,
          updates: [],
          final: true,
          resultType: .empty
        )],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    await sync.connectionStateChanged(state: .connected)
    await client.waitForFirstCallStarted()
    await sync.connectionStateChanged(state: .connected)
    await Task.yield()

    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 1)

    await client.releaseCall(1)
    let didRunFollowUp = await waitForCondition(timeout: .seconds(3)) {
      await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2
    }
    #expect(didRunFollowUp)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2)
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

    await sync.connectionStateChanged(state: .connected)
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
    await sync.connectionStateChanged(state: .connected)
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
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.connectionStateChanged(state: .connected)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 101
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2)
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
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.connectionStateChanged(state: .connected)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 102
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2)
    #expect(await storage.getBucketState(for: .user).seq == 56)
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
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.connectionStateChanged(state: .connected)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 101
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2)
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
        ],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

    await sync.connectionStateChanged(state: .connected)
    let recovered = await waitForCondition(timeout: .seconds(3)) {
      await storage.getState().lastSyncDate == 101
    }

    #expect(recovered)
    #expect(await client.getCalledMethods().filter { $0 == .getUpdatesState }.count == 2)
    #expect(await storage.getBucketState(for: .user).seq == 32)
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

    await sync.connectionStateChanged(state: .connected)
    let didCallState = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState)
    }
    #expect(didCallState)

    let state = await storage.getState()
    #expect(state.lastSyncDate == storedDate)
    #expect(await client.getUpdatesStateDates() == [storedDate])
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

    await sync.connectionStateChanged(state: .connected)
    let didCallState = await waitForCondition(timeout: .milliseconds(250)) {
      await client.getCalledMethods().contains(.getUpdatesState)
    }

    #expect(didCallState == false)
    #expect(await client.getCallCount() == 0)
  }

#if DEBUG || DEBUG_BUILD
  @Test("debug zero-date scenario requests a fresh current checkpoint")
  func testDebugZeroDateScenarioRequestsFreshCheckpoint() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 777, seq: 12)],
        .getUpdates: [makeGetUpdatesResult(
          seq: 12,
          date: 777,
          updates: [],
          final: true,
          resultType: .empty
        )],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let result = await sync.runDebugScenario(.seedZeroDateAndFetch)
    #expect(result.succeeded)

    let didCallState = await waitForCondition(timeout: .seconds(3)) {
      let methods = await client.getCalledMethods()
      return methods.contains(.getUpdatesState)
    }
    #expect(didCallState)

    #expect(await client.getUpdatesStateDates() == [nil])
    #expect(await storage.getState().lastSyncDate == 777)
    #expect(await storage.getBucketState(for: .user).seq == 12)
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

  @Test("debug user rewind does not sweep chat buckets")
  func testDebugUserRewindDoesNotSweepChatBuckets() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let userDate: Int64 = 500
    let chatDate: Int64 = 600
    let chatKey = BucketKey.chat(peer: makeChatPeer(chatId: 7))
    await storage.setBucketState(for: .user, state: BucketState(date: userDate, seq: 50))
    await storage.setBucketState(for: chatKey, state: BucketState(date: chatDate, seq: 100))
    let client = FakeProtocolClient(responses: [makeGetUpdatesResult(
      seq: 25,
      date: userDate - 60 * 60,
      updates: [],
      final: true,
      resultType: .empty
    )])
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let result = await sync.runDebugScenario(.rewindUserBucketAndFetch)

    #expect(result.succeeded)
    #expect(await storage.getBucketState(for: .user).seq == 25)
    #expect(await storage.getBucketState(for: chatKey).seq == 100)
    #expect(await client.getUpdatesStartSequences() == [25])
  }

  @Test("debug buffer overflow uses the normal bounded recovery path")
  func testDebugBufferOverflowUsesBoundedRecovery() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let empty = makeGetUpdatesResult(
      seq: 0,
      date: 100,
      updates: [],
      final: true,
      resultType: .empty
    )
    let client = FakeProtocolClient(responses: [empty, empty])
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
    #expect(await client.getCallCount() == 2)
  }
#endif

  @Test("user bucket catch-up applies updateReadMaxId")
  func testUserBucketAppliesUpdateReadMaxId() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let now = Int64(Date().timeIntervalSince1970)
    await storage.setState(SyncState(lastSyncDate: now - 60))
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
    ]
    let client = FakeProtocolClient(
      responses: [],
      methodResponses: [
        .getUpdatesState: [makeGetUpdatesStateResult(date: 106, seq: 7)],
        .getUpdates: [makeGetUpdatesResult(
          seq: 7,
          date: 106,
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

    await sync.connectionStateChanged(state: .connected)
    let didApply = await waitForCondition {
      await apply.appliedUpdates.count == updates.count
    }

    #expect(didApply)
    #expect(await apply.appliedUpdates.map(\.seq) == [1, 2, 3, 4, 5, 6, 7])
    let bucketState = await storage.getBucketState(for: .user)
    #expect(bucketState.seq == 7)
    #expect(bucketState.date == 106)
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

  @Test("large catch-up continues without holding global Updating")
  func testLargeCatchUpContinuesWithoutHoldingSyncActivity() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    let client = FakeProtocolClient(
      responses: [],
      gateCallNumbers: [4],
      methodResponses: [
        .getUpdates: [
          makeGetUpdatesResult(
            seq: 2_000,
            date: 200,
            updates: [],
            final: false,
            resultType: .tooLong
          ),
          makeGetUpdatesResult(
            seq: 1_000,
            date: 150,
            updates: [],
            final: true,
            resultType: .empty,
            skippedSequences: makeIrrelevantSkippedSequences(after: 0, through: 1_000)
          ),
          makeGetUpdatesResult(
            seq: 2_000,
            date: 200,
            updates: [],
            final: true,
            resultType: .empty,
            skippedSequences: makeIrrelevantSkippedSequences(after: 1_000, through: 2_000)
          ),
        ],
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
    await client.waitForCallStarted(4)

    let activityWhileBackgroundFetchIsBlocked = await activity.sequence
    let stateWhileBackgroundFetchIsBlocked = await storage.getBucketState(
      for: .chat(peer: makeChatPeer(chatId: 1))
    )
    #expect(activityWhileBackgroundFetchIsBlocked == [true, false])
    #expect(stateWhileBackgroundFetchIsBlocked.seq == 1_000)

    await client.releaseCall(4)
    let completed = await waitForCondition {
      await storage.getBucketState(for: .chat(peer: makeChatPeer(chatId: 1))).seq == 2_000
    }
    #expect(completed)
    let finalActivity = await activity.sequence
    #expect(finalActivity == [true, false])
  }

  @Test("chat catch-up applies durable reaction updates")
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

  @Test("chat catch-up apply failure repairs and advances bucket state")
  func testChatCatchUpApplyFailureRepairsAndAdvancesBucketState() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()
    await apply.setRepairStorage(storage)
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

    let client = FakeProtocolClient(
      responses: [response],
      methodResponses: [
        .getChat: [makeGetChatResult(chatId: 1)],
        .getChatParticipants: [makeGetChatParticipantsResult()],
        .getChatHistory: [makeGetChatHistoryResult()],
      ]
    )
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 6)
    await sync.process(updates: [signal])

    let didRepair = await waitForCondition(timeout: .milliseconds(500)) {
      let repaired = await apply.repairedChats
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return repaired.count == 1 && bucketState.seq == 6
    }
    #expect(didRepair)

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
    let repaired = await apply.repairedChats
    #expect(repaired.count == 1)
    let snapshot = try #require(repaired.first)
    #expect(snapshot.reason == "apply_failed")

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 6)
    #expect(bucketState.date == 120)
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

    let didClear = await waitForCondition(timeout: .milliseconds(500)) {
      let bucketState = await storage.getBucketState(for: .chat(peer: peer))
      return bucketState.seq == 0 && bucketState.date == 0
    }
    #expect(didClear)

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 0)
    #expect(bucketState.date == 0)
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

    // Receive seq=2 first (out-of-order). It should buffer until catch-up fills seq=1.
    let update2 = makeNewMessageUpdate(seq: 2, date: 90)
    await sync.process(updates: [update2])
    _ = await waitForCondition {
      await apply.appliedUpdates.count == 2
    }

    let applied = await apply.appliedUpdates
    let seqs = applied.map { Int($0.seq) }
    let sources = await apply.appliedSources
    #expect(seqs == [1, 2])
    #expect(sources == [.syncCatchup, .realtime])

    let peer = makeChatPeer(chatId: 1)
    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 2)
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
        .getChat: [makeGetChatResult(chatId: 1)],
        .getChatParticipants: [makeGetChatParticipantsResult()],
        .getChatHistory: [makeGetChatHistoryResult(messages: [])],
      ]
    )
    let sync = Sync(
      applyUpdates: apply,
      syncStorage: storage,
      client: client,
      config: SyncConfig(lastSyncSafetyGapSeconds: 15)
    )

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

  @Test("future realtime messages wait for catch-up pointer")
  func testFutureRealtimeMessagesWaitForCatchupPointer() async throws {
    let storage = InMemorySyncStorage()
    let apply = RecordingApplyUpdates()

    let catchup1 = makeNewMessageUpdate(seq: 1, date: 80)
    let catchup2 = makeNewMessageUpdate(seq: 2, date: 90)
    let catchup3 = makeNewMessageUpdate(seq: 3, date: 100)
    let catchup = makeGetUpdatesResult(
      seq: 5,
      date: 120,
      updates: [catchup1, catchup2, catchup3],
      final: true,
      resultType: .slice,
      skippedSequences: makeIrrelevantSkippedSequences(after: 3, through: 5)
    )
    let client = FakeProtocolClient(responses: [catchup], gateFirstCall: true)
    let config = SyncConfig(lastSyncSafetyGapSeconds: 15)
    let sync = Sync(applyUpdates: apply, syncStorage: storage, client: client, config: config)

    let peer = makeChatPeer(chatId: 1)
    let signal = makeChatHasNewUpdatesSignal(chatId: 1, updateSeq: 5)
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

  private var responses: [InlineProtocol.RpcResult.OneOf_Result?]
  private var methodResponses: [InlineProtocol.Method: [InlineProtocol.RpcResult.OneOf_Result?]]?
  private var methodErrors: [InlineProtocol.Method: [Error]]
  private var callCount = 0
  private var methods: [InlineProtocol.Method] = []
  private var updatesStateDates: [Int64?] = []
  private var updatesStartSequences: [Int64] = []

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
    methodErrors: [InlineProtocol.Method: [Error]] = [:]
  ) {
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
  var result = UpdateApplyResult.success(count: 0)
  var repairResult = true
  var repairStorage: InMemorySyncStorage?

  func setResult(_ result: UpdateApplyResult) {
    self.result = result
  }

  func setRepairResult(_ result: Bool) {
    repairResult = result
  }

  func setRepairStorage(_ storage: InMemorySyncStorage) {
    repairStorage = storage
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    appliedUpdates.append(contentsOf: updates)
    appliedSources.append(contentsOf: Array(repeating: source, count: updates.count))
    if let sidecars {
      appliedSidecars.append(sidecars)
    }
    guard result.failedCount > 0 else {
      return .success(count: updates.count)
    }
    return result
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
  private var stateWriteFailuresRemaining = 0
  private var failBucketStateWrites = false
  private var bucketStateWriteFailuresRemaining = 0
  private var clearCount = 0

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
    bucketStates[key] ?? BucketState(date: 0, seq: 0)
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
