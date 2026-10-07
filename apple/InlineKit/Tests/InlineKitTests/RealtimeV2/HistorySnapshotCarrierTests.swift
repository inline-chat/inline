import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Testing

@Suite("RealtimeV2.HistorySnapshotCarrier", .serialized)
struct HistorySnapshotCarrierTests {
  @Test("a history witness drains catch-up replies on its own protocol carrier", .timeLimit(.minutes(1)))
  func historyWitnessDoesNotBlockCarrier() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = HistoryCarrierTransport()
    let storage = HistoryCarrierStorage()
    let realtime = RealtimeV2(
      transport: transport, auth: auth.handle,
      applyUpdates: HistoryCarrierApplyUpdates(), syncStorage: storage
    )
    let id = UUID()
    let clock = ContinuousClock()
    let started = clock.now
    let query = historyQuery(realtime, id: id)

    let finished = await historyCarrierWait(timeout: .seconds(2)) {
      await HistoryCarrierProbe.shared.finished(id)
    }
    #expect(finished)
    #expect(clock.now - started < .seconds(2))
    #expect(await transport.chatUpdateRequests == [5])
    #expect(await storage.getBucketState(for: historyCarrierBucket).seq == 6)
    #expect(await HistoryCarrierProbe.shared.applied(id))
    #expect(await HistoryCarrierProbe.shared.succeeded(id))

    query.cancel()
    await realtime.loggedOut()
    await query.value
  }

  @Test("cancelling a history caller never applies its page after catch-up arrives", .timeLimit(.minutes(1)))
  func cancellationRejectsLatePage() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = HistoryCarrierTransport(withholdChatCatchup: true)
    let storage = HistoryCarrierStorage()
    let realtime = RealtimeV2(
      transport: transport, auth: auth.handle,
      applyUpdates: HistoryCarrierApplyUpdates(), syncStorage: storage
    )
    let id = UUID()
    let query = historyQuery(realtime, id: id)
    let waiting = await historyCarrierWait(timeout: .seconds(2)) {
      await transport.chatUpdateRequests == [5]
    }
    #expect(waiting)
    #expect(await HistoryCarrierProbe.shared.applied(id) == false)

    query.cancel()
    #expect(await historyCarrierWait(timeout: .seconds(2)) {
      await HistoryCarrierProbe.shared.finished(id)
    })
    await transport.releaseChatCatchup()
    #expect(await historyCarrierWait(timeout: .seconds(2)) {
      await storage.getBucketState(for: historyCarrierBucket).seq == 6
    })
    #expect(await HistoryCarrierProbe.shared.applied(id) == false)
    #expect(await HistoryCarrierProbe.shared.succeeded(id) == false)
    await realtime.loggedOut()
    await query.value
  }

  @Test("logout drains a withheld history witness and rejects a late old-owner page", .timeLimit(.minutes(1)))
  func logoutRejectsLatePage() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = HistoryCarrierTransport(withholdChatCatchup: true)
    let storage = HistoryCarrierStorage()
    let realtime = RealtimeV2(
      transport: transport, auth: auth.handle,
      applyUpdates: HistoryCarrierApplyUpdates(), syncStorage: storage
    )
    let id = UUID()
    let query = historyQuery(realtime, id: id)
    #expect(await historyCarrierWait(timeout: .seconds(2)) {
      await transport.chatUpdateRequests == [5]
    })

    let clock = ContinuousClock()
    let started = clock.now
    await realtime.loggedOut()
    #expect(clock.now - started < .seconds(2))
    #expect(await historyCarrierWait(timeout: .seconds(2)) {
      await HistoryCarrierProbe.shared.finished(id)
    })
    await transport.releaseChatCatchup()
    #expect(await HistoryCarrierProbe.shared.applied(id) == false)
    #expect(await HistoryCarrierProbe.shared.succeeded(id) == false)
    #expect(await storage.chatCommits.contains(6) == false)
    #expect(await storage.getBucketState(for: historyCarrierBucket).seq == 0)
    await query.value
  }
}

private let historyCarrierBucket = BucketKey.chat(peer: .with { $0.chat = .with { $0.chatID = 77 } })

private func historyQuery(_ realtime: RealtimeV2, id: UUID) -> Task<Void, Never> {
  Task {
    do {
      _ = try await realtime.send(HistoryCarrierTransaction(id: id))
      await HistoryCarrierProbe.shared.finish(id, succeeded: true)
    } catch {
      await HistoryCarrierProbe.shared.finish(id, succeeded: false)
    }
  }
}

private struct HistoryCarrierTransaction: Transaction, Codable {
  struct Context: Sendable, Codable { let id: UUID }
  enum CodingKeys: String, CodingKey { case context }

  var method: InlineProtocol.Method = .getChatHistory
  var type: TransactionKindType = .query()
  var context: Context

  init(id: UUID) {
    context = Context(id: id)
  }

  var historyReadChatID: Int64? {
    77
  }

  var historyReadBucket: BucketKey? {
    historyCarrierBucket
  }

  func input(from context: Context) -> RpcCall.OneOf_Input? {
    .getChatHistory(.with { $0.peerID = .with { $0.chat = .with { $0.chatID = 77 } } })
  }

  func apply(_ rpcResult: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChatHistory(result) = rpcResult, result.hasSeq, result.seq == 6 else {
      throw .invalid
    }
    await HistoryCarrierProbe.shared.markApplied(context.id)
  }
}

private actor HistoryCarrierProbe {
  static let shared = HistoryCarrierProbe()
  private var appliedIDs: Set<UUID> = []
  private var outcomes: [UUID: Bool] = [:]

  func markApplied(_ id: UUID) {
    appliedIDs.insert(id)
  }

  func finish(_ id: UUID, succeeded: Bool) {
    outcomes[id] = succeeded
  }

  func applied(_ id: UUID) -> Bool {
    appliedIDs.contains(id)
  }

  func finished(_ id: UUID) -> Bool {
    outcomes[id] != nil
  }

  func succeeded(_ id: UUID) -> Bool {
    outcomes[id] == true
  }
}

/// Only the remote endpoint is scripted. RealtimeV2, ProtocolSession and Sync are real.
private actor HistoryCarrierTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private let withholdChatCatchup: Bool
  private var started = false
  private var withheld: [UInt64] = []
  private(set) var chatUpdateRequests: [Int64] = []

  init(withholdChatCatchup: Bool = false) {
    self.withholdChatCatchup = withholdChatCatchup
  }

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    await events.send(.connected)
  }

  func stop() async {
    started = false
    events.finish()
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
      case .connectionInit:
        await events.send(.message(.with {
          $0.id = message.id
          $0.body = .connectionOpen(.init())
        }))
      case let .rpcCall(call):
        switch call.input {
          case .getChatHistory:
            await reply(message.id, result: .getChatHistory(.with { $0.seq = 6 }))
          case .getUpdatesState:
            await reply(message.id, result: .getUpdatesState(.with {
              $0.date = 1
              $0.seq = 0
              $0.updatesFound = false
            }))
          case let .getUpdates(input):
            if case let .chat(bucket) = input.bucket.type,
               case let .chat(peer) = bucket.peerID.type, peer.chatID == 77
            {
              chatUpdateRequests.append(input.startSeq)
              if withholdChatCatchup {
                withheld.append(message.id)
              } else {
                await replyChatCatchup(message.id)
              }
            } else {
              await reply(message.id, result: .getUpdates(.with {
                $0.seq = input.startSeq
                $0.date = 1
                $0.final = true
                $0.resultType = .empty
              }))
            }
          default:
            Issue.record("Unexpected RPC on history test carrier: \(call.method)")
        }
      default:
        break
    }
  }

  func releaseChatCatchup() async {
    let pending = withheld
    withheld = []
    for id in pending {
      await replyChatCatchup(id)
    }
  }

  private func replyChatCatchup(_ id: UInt64) async {
    await reply(id, result: .getUpdates(.with {
      $0.seq = 6
      $0.date = 2
      $0.final = true
      $0.resultType = .slice
      $0.skippedSequences = [.with { $0.seq = 6
        $0.reason = .irrelevantToBucket
      }]
    }))
  }

  private func reply(_ id: UInt64, result: RpcResult.OneOf_Result) async {
    await events.send(.message(.with {
      $0.id = id
      $0.body = .rpcResult(.with { $0.reqMsgID = id
        $0.result = result
      })
    }))
  }
}

private actor HistoryCarrierApplyUpdates: ApplyUpdates {
  func apply(
    updates: [InlineProtocol.Update], source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    .success(count: updates.count)
  }
}

private actor HistoryCarrierStorage: SyncStorage {
  private var state = SyncState(lastSyncDate: 1)
  private var buckets = [historyCarrierBucket: BucketState(date: 1, seq: 5)]
  private(set) var chatCommits: [Int64] = []

  func canonicalPeer(forChatID chatID: Int64) async -> InlineProtocol.Peer? {
    guard case let .chat(peer) = historyCarrierBucket,
          case let .chat(chat) = peer.type,
          chat.chatID == chatID,
          buckets[historyCarrierBucket] != nil
    else { return nil }
    return peer
  }

  func getState() async -> SyncState {
    state
  }

  func setState(_ state: SyncState) async -> Bool {
    self.state = state
    return true
  }

  func getBucketState(for key: BucketKey) async -> BucketState {
    buckets[key] ?? BucketState(date: 0, seq: 0)
  }

  func setBucketState(for key: BucketKey, state: BucketState) async -> Bool {
    buckets[key] = state
    return true
  }

  func advanceBucketState(for key: BucketKey, state: BucketState) async -> BucketState? {
    let current = buckets[key] ?? BucketState(date: 1, seq: 0)
    let committed = BucketState(date: max(current.date, state.date), seq: max(current.seq, state.seq))
    buckets[key] = committed
    if key == historyCarrierBucket {
      chatCommits.append(committed.seq)
    }
    return committed
  }

  func removeBucketState(for key: BucketKey) async -> Bool {
    buckets.removeValue(forKey: key)
    return true
  }

  func setBucketStates(states: [BucketKey: BucketState]) async -> Bool {
    for (key, state) in states {
      _ = await advanceBucketState(for: key, state: state)
    }
    return true
  }

  func clearSyncState() async -> Bool {
    state = SyncState(lastSyncDate: 0)
    buckets = [:]
    return true
  }
}

private func historyCarrierWait(
  timeout: Duration, _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while await !condition() {
    if clock.now >= deadline {
      return false
    }
    try? await clock.sleep(for: .milliseconds(10))
  }
  return true
}
