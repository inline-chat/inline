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

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    Task { await sync.process(updates: [update]) }
    await client.waitForFirstCallStarted()

    await sync.process(updates: [update])

    await client.releaseFirstCall()
    try await Task.sleep(for: .milliseconds(50))

    let callCount = await client.getCallCount()
    #expect(callCount == 2)
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

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    try await Task.sleep(for: .milliseconds(50))

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

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    try await Task.sleep(for: .milliseconds(50))

    let applied = await apply.appliedUpdates
    #expect(applied.count == 1)
  }

  @Test("TOO_LONG slices within max total and updates bucket state")
  func testTooLongFastForward() async throws {
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
    var payload = InlineProtocol.UpdateChatHasNewUpdates()
    payload.peerID = peer

    var update = InlineProtocol.Update()
    update.update = .chatHasNewUpdates(payload)

    await sync.process(updates: [update])
    try await Task.sleep(for: .milliseconds(50))

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 10)
    #expect(bucketState.date == 200)

    let stats = await sync.getStats()
    #expect(stats.bucketFetchTooLong == 1)

    let applied = await apply.appliedUpdates
    #expect(applied.isEmpty)
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
    try await Task.sleep(for: .milliseconds(50))

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
    update.seq = 5
    update.date = 100
    update.update = .deleteMessages(payload)

    await sync.process(updates: [update])

    let bucketState = await storage.getBucketState(for: .chat(peer: peer))
    #expect(bucketState.seq == 5)
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
    try await Task.sleep(for: .milliseconds(50))

    await sync.updateConfig(SyncConfig(enableMessageUpdates: true, lastSyncSafetyGapSeconds: 15))

    await sync.process(updates: [update])
    try await Task.sleep(for: .milliseconds(50))

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
    try await Task.sleep(for: .milliseconds(50))

    let methods = await client.getCalledMethods()
    #expect(methods.contains(.getUpdatesState))
    #expect(methods.contains(.getUpdates))
  }
}

// MARK: - Test Helpers

final actor FakeProtocolClient: ProtocolClientType {
  private var responses: [InlineProtocol.RpcResult.OneOf_Result?]
  private var callCount = 0
  private var methods: [InlineProtocol.Method] = []

  private var firstCallStarted = false
  private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstCallGate: CheckedContinuation<Void, Never>?
  private let gateFirstCall: Bool

  init(responses: [InlineProtocol.RpcResult.OneOf_Result?], gateFirstCall: Bool = false) {
    self.responses = responses
    self.gateFirstCall = gateFirstCall
  }

  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    callCount += 1
    methods.append(method)
    if callCount == 1, gateFirstCall {
      signalFirstCallStarted()
      await withCheckedContinuation { continuation in
        firstCallGate = continuation
      }
    }

    if responses.isEmpty {
      return nil
    }
    return responses.removeFirst() ?? nil
  }

  func waitForFirstCallStarted() async {
    if firstCallStarted {
      return
    }
    await withCheckedContinuation { continuation in
      firstCallWaiters.append(continuation)
    }
  }

  func releaseFirstCall() {
    firstCallGate?.resume()
    firstCallGate = nil
  }

  func getCallCount() -> Int {
    callCount
  }

  func getCalledMethods() -> [InlineProtocol.Method] {
    methods
  }

  private func signalFirstCallStarted() {
    guard !firstCallStarted else { return }
    firstCallStarted = true
    for continuation in firstCallWaiters {
      continuation.resume()
    }
    firstCallWaiters.removeAll()
  }
}

actor RecordingApplyUpdates: ApplyUpdates {
  private(set) var appliedUpdates: [InlineProtocol.Update] = []

  func apply(updates: [InlineProtocol.Update]) async {
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
