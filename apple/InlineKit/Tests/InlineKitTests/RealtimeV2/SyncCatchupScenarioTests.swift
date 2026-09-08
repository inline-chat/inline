import Auth
import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
@testable import RealtimeV2
import Testing

/// Repeatable incident-shaped exercise of the real Sync -> UpdatesEngine -> GRDB
/// path. The server and the former admission predicate are test-only controls.
@Suite("Catch-up debug scenario", .serialized)
struct SyncCatchupScenarioTests {
  enum Mode: String, CaseIterable {
    case legacyUserFence
    case fixed
  }

  @Test("missing roots under continuous unrelated User progress", arguments: Mode.allCases)
  func catchupUnderUserTraffic(mode: Mode) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let storage = GRDBSyncStorage(db: database)
    let now: Int64 = 1_800_000_000
    try await queue.write { db in
      try Space(id: 1, name: "Scenario", date: Date(timeIntervalSince1970: TimeInterval(now))).insert(db)
      try User(id: 42, email: nil, firstName: "Scenario").insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: .init(date: now - 604_800, seq: 10), in: db)
    }
    #expect(await storage.setState(.init(lastSyncDate: now - 604_800)))
    let driver = CatchupScenarioDriver(database: database, mode: mode, now: now)
    let client = FakeProtocolClient(responses: [], responseProvider: { method, input in
      try await driver.respond(method: method, input: input)
    })
    let sync = Sync(applyUpdates: driver, syncStorage: storage, client: client, config: .default)
    let count = 32
    let hints: [InlineProtocol.Update] = (1 ... count).map { id in
      .with {
        $0.update = .chatHasNewUpdates(.with {
          $0.peerID = .with { $0.chat.chatID = Int64(id) }
          $0.updateSeq = 1
        })
      }
    }
    let start = ContinuousClock.now
    await sync.process(updates: hints)
    let reached = await waitUntil {
      if mode == .fixed {
        let stats = await sync.getStats()
        return await driver.committed == count && stats.activeBucketFetches == 0
      }
      return await driver.rejected >= count * 2
    }
    #expect(reached)
    let stats = await sync.getStats()
    let requests = await driver.requests
    let committed = await driver.committed
    let rejected = await driver.rejected
    print(
      "SYNC_SCENARIO mode=\(mode.rawValue) roots=\(count) requests=\(requests) committed=\(committed) rejected=\(rejected) active=\(stats.activeBucketFetches) elapsed=\(start.duration(to: .now))"
    )
    await sync.prepareForTermination()

    if mode == .legacyUserFence {
      #expect(committed == 0)
      #expect(rejected >= count * 2)
      #expect(stats.activeBucketFetches == count)
      #expect(try await queue.read { try Chat.fetchCount($0) } == 0)
    } else {
      #expect(requests == count)
      #expect(rejected == 0)
      #expect(stats.bucketApplyFailures == 0)
      #expect(stats.bucketApplyConflicts == 0)
      #expect(stats.activeBucketFetches == 0)
      #expect(try await storage.getRemovalRevision() == 0)
      #expect(try await storage.getBucketState(for: .user).seq == 10 + Int64(count))
      let titles = try await queue.read { db in
        try Chat.fetchAll(db).map(\.title)
      }
      #expect(titles.count == count)
      #expect(titles.allSatisfy { $0 == "Caught up" })
      // Recreate the sync owner over the same durable database. Re-delivered
      // finite hints must not replay pages that survived termination.
      let resumed = Sync(applyUpdates: driver, syncStorage: storage, client: client, config: .default)
      await resumed.process(updates: hints)
      #expect(await driver.requests == requests)
      #expect(await resumed.getStats().activeBucketFetches == 0)
      await resumed.prepareForTermination()
      print("SYNC_SCENARIO restart=fixed additional_requests=0 durable_roots=\(titles.count)")
    }
  }

  private func waitUntil(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}

private actor CatchupScenarioDriver: ApplyUpdates {
  let database: AppDatabase
  let engine: UpdatesEngine
  let mode: SyncCatchupScenarioTests.Mode
  let now: Int64
  private(set) var requests = 0
  private(set) var committed = 0
  private(set) var rejected = 0
  private var userAtRequest: [BucketKey: BucketState] = [:]

  init(database: AppDatabase, mode: SyncCatchupScenarioTests.Mode, now: Int64) {
    self.database = database
    self.mode = mode
    self.now = now
    engine = UpdatesEngine(database: database)
  }

  func respond(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> InlineProtocol.RpcResult
    .OneOf_Result?
  {
    guard method == .getUpdates, case let .getUpdates(request)? = input,
          case let .chat(bucket)? = request.bucket.type,
          case let .chat(peer)? = bucket.peerID.type
    else {
      Issue.record("Unexpected scenario RPC: \(method)")
      return nil
    }
    requests += 1
    let id = peer.chatID
    let peerID = InlineProtocol.Peer.with { $0.chat.chatID = id }
    let key = BucketKey.chat(peer: peerID)
    // Every received child request overlaps one unrelated, atomic User write.
    // Even capturing the former User fence after queueing cannot make it pass.
    let prior = try await database.dbWriter.write { db in
      let row = try DbBucketState.filter(DbBucketState.Columns.bucketType == 2).fetchOne(db)
      let prior = BucketState(date: row?.date ?? 0, seq: row?.seq ?? 0)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: .init(date: self.now, seq: prior.seq + 1), in: db)
      return prior
    }
    userAtRequest[key] = prior
    return .getUpdates(.with {
      $0.seq = 1
      $0.date = now
      $0.final = true
      $0.resultType = .slice
      $0.updates = [.with {
        $0.seq = 1
        $0.date = now
        $0.update = .chatInfo(.with { $0.chatID = id
          $0.title = "Caught up"
        })
      }]
      $0.sidecars = .with {
        $0.chats = [.with { $0.id = id
          $0.peerID = peerID
          $0.spaceID = 1
          $0.seq = 1
          $0.date = now
          $0.title = "Before"
        }]
        $0.dialogs = [.with { $0.peer = peerID
          $0.chatID = id
          $0.spaceID = 1
        }]
      }
    })
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    await engine.applyBatch(updates: updates, source: source, sidecars: sidecars)
  }

  func apply(
    updates: [InlineProtocol.Update], source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?, bucketCommit: UpdateBucketCommit?,
    mutationToken: AuthAccountMutationToken?
  ) async -> UpdateApplyResult {
    if mode == .legacyUserFence, let commit = bucketCommit, let expected = userAtRequest[commit.key] {
      do {
        let actual = try await GRDBSyncStorage(db: database).getBucketState(for: .user)
        if expected.seq != actual.seq || expected.date != actual.date {
          rejected += 1
          return .init(
            appliedCount: 0,
            failedCount: max(1, updates.count),
            failure: .cursorChanged(bucket: .user, expected: expected, actual: actual)
          )
        }
      } catch {
        Issue.record("Scenario storage failed: \(error)")
        return .init(appliedCount: 0, failedCount: 1)
      }
    }
    let result = await engine.applyBatch(
      updates: updates,
      source: source,
      sidecars: sidecars,
      bucketCommit: bucketCommit,
      mutationToken: mutationToken
    )
    if result.succeeded { committed += 1 } else { rejected += 1 }
    return result
  }
}
