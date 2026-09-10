import AsyncAlgorithms
@testable import Auth
import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import Logger
@testable import RealtimeV2
import Testing

@Suite("Sync release flow regressions", .serialized)
struct SyncReleaseRegressionTests {
  @Test("overflow recovery does not hold the receive receipt needed by its own RPC")
  func overflowReleasesReceiveLoop() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let storage = GRDBSyncStorage(db: database)
    let peer = InlineProtocol.Peer.with { $0.chat.chatID = 7 }
    let key = BucketKey.chat(peer: peer)
    _ = await storage.setBucketState(for: key, state: .init(date: 100, seq: 1))
    let transport = SyncScriptedTransport()
    let session = ProtocolSession(transport: transport, auth: Auth.mocked(authenticated: true).handle)
    let sync = Sync(
      applyUpdates: InlineApplyUpdates(engine: UpdatesEngine(database: database)),
      syncStorage: storage,
      client: session,
      config: .default
    )
    // The real session waits for this receipt before reading its next transport
    // message, exactly as the account event consumer does in production.
    let consumer = Task {
      for await envelope in session.events {
        if case let .updates(payload) = envelope.event { await sync.process(updates: payload.updates) }
        await envelope.markProcessed()
      }
    }
    await session.start()
    let updates: [InlineProtocol.Update] = (3 ... 4_099).map { sequence in
      .with {
        $0.seq = Int32(sequence)
        $0.date = 101
        $0.update = .chatInfo(.with { $0.chatID = 7
          $0.title = "buffered"
        })
      }
    }
    let delivery = Task { await transport.push(updates) }
    let completed = await releaseEventually {
      let state = try? await storage.getBucketState(for: key)
      let stats = await sync.getStats()
      return state?.seq == 4_099 && stats.activeBucketFetches == 0
    }
    // Cleanup before assertions also releases the deliberately wedged old path.
    await session.reset()
    await sync.prepareForTermination()
    await transport.finish()
    consumer.cancel()
    await delivery.value
    #expect(completed, "A delivered reply must progress before the production 30-second RPC timeout")
    #expect(await transport.requests == [(Int64(1), Int64(4_099))].map { SyncScriptedTransport.Request(
      from: $0.0,
      through: $0.1
    ) })
    #expect(try await storage.getBucketState(for: key).seq == 4_099)
  }

  @Test("a real foreign-key failure isolates its bucket and recovers without losing the update")
  func foreignKeyFailureDoesNotBlockHealthyChat() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let storage = GRDBSyncStorage(db: database)
    let failedPeer = InlineProtocol.Peer.with { $0.chat.chatID = 7 }
    let healthyPeer = InlineProtocol.Peer.with { $0.chat.chatID = 8 }
    let failedKey = BucketKey.chat(peer: failedPeer)
    let healthyKey = BucketKey.chat(peer: healthyPeer)
    try await queue.write { db in
      for peer in [failedPeer, healthyPeer] {
        let chat = Chat(from: .with { $0.id = peer.chat.chatID
          $0.peerID = peer
          $0.title = "Before"
        })
        try chat.save(db)
      }
    }
    for key in [failedKey, healthyKey] {
      _ = await storage.setBucketState(for: key, state: .init(date: 100, seq: 1))
    }
    let moved = InlineProtocol.Update.with {
      $0.seq = 2
      $0.date = 101
      $0.update = .chatMoved(.with {
        $0.chat = .with { $0.id = 7
          $0.peerID = failedPeer
          $0.spaceID = 99
          $0.title = "Moved"
        }
      })
    }
    let client = FakeProtocolClient(responses: [], responseProvider: { method, input in
      guard method == .getUpdates, case let .getUpdates(request)? = input else {
        Issue.record("Unexpected recovery operation")
        return nil
      }
      #expect(request.startSeq == 1)
      return .getUpdates(.with {
        $0.seq = 2
        $0.date = 101
        $0.final = true
        $0.resultType = .slice
        $0.updates = [moved]
      })
    })
    let sync = Sync(
      applyUpdates: InlineApplyUpdates(engine: UpdatesEngine(database: database)),
      syncStorage: storage,
      client: client,
      config: .default
    )
    let failures = SyncFailureLogSink()
    let sinkID = UUID().uuidString
    Log.addSink(failures, id: sinkID)
    defer { Log.removeSink(id: sinkID) }
    await sync.process(updates: [moved])
    let rejected = await releaseEventually {
      let stats = await sync.getStats()
      return stats.bucketApplyFailures > 0 && failures.hasRecoveryFailure
    }
    #expect(rejected)
    #expect(failures.hasForeignKeyFailure)
    #expect(try await storage.getBucketState(for: failedKey).seq == 1)
    #expect(try await queue.read { try Chat.fetchOne($0, id: 7)?.title } == "Before")
    await sync.process(updates: [.with {
      $0.seq = 2
      $0.date = 101
      $0.update = .chatInfo(.with { $0.chatID = 8
        $0.title = "Healthy progress"
      })
    }])
    #expect(try await storage.getBucketState(for: healthyKey).seq == 2)
    #expect(try await queue.read { try Chat.fetchOne($0, id: 8)?.title } == "Healthy progress")
    // Model the missing dependency arriving through an independent authoritative
    // write. The existing recovery owner must replay the failed update itself.
    try await queue.write { db in
      try Space(id: 99, name: "Recovered dependency", date: Date()).insert(db)
    }
    let recovered = await releaseEventually {
      let state = try? await storage.getBucketState(for: failedKey)
      let stats = await sync.getStats()
      return state?.seq == 2 && stats.activeBucketFetches == 0
    }
    await sync.prepareForTermination()
    #expect(recovered)
    #expect(try await queue.read { try Chat.fetchOne($0, id: 7)?.title } == "Moved")
    #expect(try await queue.read { try Chat.fetchOne($0, id: 7)?.spaceId } == 99)
  }

  @Test("a snapshot installed during limiter wait prevents an obsolete RPC")
  func queuedSnapshotAvoidsRPC() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let storage = GRDBSyncStorage(db: database)
    let peer = InlineProtocol.Peer.with { $0.chat.chatID = 7 }
    let key = BucketKey.chat(peer: peer)
    _ = await storage.setBucketState(for: key, state: .init(date: 100, seq: 1))
    let limiter = FetchLimiter(limit: 1)
    #expect(await limiter.acquire())
    let client = FakeProtocolClient(responses: [])
    let sync = Sync(
      applyUpdates: InlineApplyUpdates(engine: UpdatesEngine(database: database)),
      syncStorage: storage,
      client: client,
      config: .default
    )
    let bucket = BucketActor(
      key: key,
      seq: 1,
      date: 100,
      client: client,
      sync: sync,
      fetchLimiter: limiter,
      accountMutationToken: nil
    )
    await bucket.setFetchTarget(upToSeq: 2)
    let fetch = Task { await bucket.fetchNewUpdates() }
    let queued = await releaseEventually { await limiter.waitingCount == 1 }
    _ = await storage.setBucketState(for: key, state: .init(date: 102, seq: 3))
    await bucket.installSnapshotState(.init(date: 102, seq: 3))
    await limiter.release()
    await fetch.value
    await bucket.invalidate()
    await sync.prepareForTermination()
    #expect(queued)
    #expect(await client.getCallCount() == 0)
    #expect(await bucket.snapshot().seq == 3)
  }
}

private func releaseEventually(_ predicate: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    if await predicate() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return false
}

private final class SyncFailureLogSink: LogSink, @unchecked Sendable {
  private let lock = NSLock()
  private var recoveryFailure = false
  private var foreignKeyFailure = false

  var hasRecoveryFailure: Bool {
    lock.lock()
    defer { lock.unlock() }
    return recoveryFailure
  }

  var hasForeignKeyFailure: Bool {
    lock.lock()
    defer { lock.unlock() }
    return foreignKeyFailure
  }

  func write(_ event: LogEvent) {
    lock.lock()
    defer { lock.unlock() }
    if event.error is SyncRecoveryFailure { recoveryFailure = true }
    if let failure = event.error as? DurableUpdateFailure, failure.cause == .foreignKey {
      foreignKeyFailure = true
    }
  }
}
