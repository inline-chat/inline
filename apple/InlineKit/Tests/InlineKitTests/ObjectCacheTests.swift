import Combine
import Foundation
import GRDB
import Synchronization
import Testing

@testable import InlineKit

@Suite("Object cache")
@MainActor
struct ObjectCacheTests {
  private final class StatementLog: Sendable {
    private let selects = Mutex<[(sql: String, onMainThread: Bool)]>([])

    func record(_ sql: String) {
      guard sql.hasPrefix("SELECT") else { return }
      selects.withLock { $0.append((sql, Thread.isMainThread)) }
    }

    func reset() {
      selects.withLock { $0.removeAll() }
    }

    var count: Int {
      selects.withLock { $0.count }
    }

    var mainThreadCount: Int {
      selects.withLock { $0.count(where: \.onMainThread) }
    }
  }

  private struct Fixture {
    let cache: ObjectCache
    let queue: DatabaseQueue
    let log: StatementLog
  }

  private func makeFixture(users: Int = 4, trackedLimit: Int = 512, memoryLimit: Int = 4_096) async throws -> Fixture {
    let log = StatementLog()
    var configuration = AppDatabase.makeConfiguration(passphrase: "123")
    configuration.prepareDatabase { db in
      db.trace(options: .statement) { log.record($0.expandedDescription) }
    }
    let queue = try DatabaseQueue(configuration: configuration)
    let database = try AppDatabase(queue)
    try await queue.write { db in
      for id in 1 ... users {
        try User(id: Int64(id), email: nil, firstName: "User \(id)").insert(db)
      }
      try Space(id: 2, name: "Workspace", date: Date()).insert(db)
      try Chat(id: 3, date: Date(), type: .thread, title: "Thread", spaceId: 2).insert(db)
      try Message(
        messageId: 10, fromId: 1, date: Date(), text: "First", peerUserId: nil, peerThreadId: 3, chatId: 3
      ).insert(db)
    }
    let cache = ObjectCache(database: database, trackedLimit: { _ in trackedLimit }, memoryLimit: memoryLimit)
    log.reset()
    return Fixture(cache: cache, queue: queue, log: log)
  }

  private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 400 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  /// Loads `ids` and waits until the trackers are attached and every ID is fresh.
  private func loadAndSettle(_ fixture: Fixture, _ ids: [ObjectID]) async -> Bool {
    await fixture.cache.load(ids)
    await fixture.cache.trackerStart?.value
    return await eventually {
      let snapshot = fixture.cache.cached(ids)
      return ids.allSatisfy { [.fresh, .missing].contains(snapshot.state(of: $0)) }
    }
  }

  private func rename(_ fixture: Fixture, user id: Int64, to name: String) async throws {
    try await fixture.queue.write { db in
      try db.execute(sql: "UPDATE user SET firstName = ? WHERE id = ?", arguments: [name, id])
    }
  }

  @Test("cached never reads the database")
  func cachedNeverReads() async throws {
    let fixture = try await makeFixture()
    let snapshot = fixture.cache.cached([.user(1), .chat(3), .space(2)])
    #expect(snapshot.user(1) == nil)
    #expect(snapshot.state(of: .user(1)) == .unloaded)
    #expect(snapshot.state(of: .chat(3)) == .unloaded)
    #expect(fixture.log.count == 0)
  }

  @Test("get reads unloaded records once, in one batch per kind")
  func getReadsOnceInBatches() async throws {
    let fixture = try await makeFixture()
    let ids: [ObjectID] = [.user(1), .user(2), .user(99), .chat(3), .space(2)]
    let snapshot = fixture.cache.get(ids)
    #expect(snapshot.user(1)?.user.firstName == "User 1")
    #expect(snapshot.user(2)?.user.firstName == "User 2")
    #expect(snapshot.chat(3)?.title == "Thread")
    #expect(snapshot.space(2)?.name == "Workspace")
    #expect(snapshot.user(99) == nil)
    // Users and their photos, chats, spaces: independent of how many IDs were asked for.
    #expect(fixture.log.count == 4)

    fixture.log.reset()
    #expect(fixture.cache.get(ids).user(2)?.user.firstName == "User 2")
    #expect(fixture.cache.getUser(id: 1)?.user.firstName == "User 1")
    #expect(fixture.cache.getCachedChat(id: 3)?.title == "Thread")
    #expect(fixture.cache.get(.space(2)).space(2)?.name == "Workspace")
    #expect(fixture.cache.cached(.user(99)).state(of: .user(99)) == .missing)
    #expect(fixture.log.count == 0)
  }

  @Test("load reads off the main thread and reports what it found")
  func loadReadsOffMainThread() async throws {
    let fixture = try await makeFixture()
    let ids: [ObjectID] = [.user(1), .user(99), .chat(3)]
    let snapshot = await fixture.cache.load(ids)
    #expect(snapshot.user(1)?.user.firstName == "User 1")
    #expect(snapshot.chat(3)?.title == "Thread")
    #expect(snapshot.user(99) == nil)
    #expect(fixture.log.mainThreadCount == 0)

    #expect(await loadAndSettle(fixture, ids))
    let settled = fixture.cache.cached(ids)
    #expect(settled.state(of: .user(1)) == .fresh)
    #expect(settled.state(of: .user(99)) == .missing)
    #expect(fixture.log.mainThreadCount == 0)
  }

  @Test("warm fills the cache without blocking, so a later get hits memory")
  func warmThenGetHitsMemory() async throws {
    let fixture = try await makeFixture()
    fixture.cache.warm(.user(1))
    fixture.cache.warm([.user(1), .user(2)])
    #expect(fixture.cache.cached([.user(1)]).state(of: .user(1)) == .unloaded)
    #expect(await eventually { fixture.cache.cached([.user(2)]).user(2) != nil })

    #expect(fixture.cache.get([.user(1), .user(2)]).user(1)?.user.firstName == "User 1")
    #expect(fixture.log.mainThreadCount == 0)
  }

  @Test("tracked records follow database writes and announce the change")
  func trackedRecordsStayFresh() async throws {
    let fixture = try await makeFixture()
    #expect(await loadAndSettle(fixture, [.user(1), .user(2), .chat(3)]))
    var announced: Set<ObjectID> = []
    let subscription = fixture.cache.changes.sink { announced.formUnion($0) }
    defer { subscription.cancel() }

    try await rename(fixture, user: 1, to: "Renamed")
    #expect(await eventually { fixture.cache.cached([.user(1)]).user(1)?.user.firstName == "Renamed" })
    #expect(await eventually { fixture.cache.cached([.user(1)]).state(of: .user(1)) == .fresh })
    #expect(announced == [.user(1)])
    #expect(fixture.log.mainThreadCount == 0)
  }

  @Test("a row that appears or disappears later is picked up")
  func missingRowsAreTracked() async throws {
    let fixture = try await makeFixture()
    #expect(await loadAndSettle(fixture, [.user(50), .chat(3)]))
    #expect(fixture.cache.cached([.user(50)]).state(of: .user(50)) == .missing)

    try await fixture.queue.write { db in
      try User(id: 50, email: nil, firstName: "Late").insert(db)
      try db.execute(sql: "DELETE FROM chat WHERE id = 3")
    }
    #expect(await eventually { fixture.cache.cached([.user(50)]).user(50)?.user.firstName == "Late" })
    #expect(await eventually { fixture.cache.cached([.chat(3)]).state(of: .chat(3)) == .missing })
  }

  @Test("tracking cost does not grow with the number of cached records")
  func trackingIsBounded() async throws {
    let fixture = try await makeFixture(users: 60)
    let ids = (1 ... 60).map { ObjectID.user(Int64($0)) }
    #expect(await loadAndSettle(fixture, ids + [.chat(3), .space(2)]))
    #expect(fixture.cache.trackerCount == 4)

    fixture.log.reset()
    try await rename(fixture, user: 7, to: "Seven")
    #expect(await eventually { fixture.cache.cached([.user(7)]).user(7)?.user.firstName == "Seven" })
    #expect(await eventually { fixture.cache.cached(ids).state(of: .user(60)) == .fresh })
    // One write refreshes all 60 users with two statements: users, then their photos.
    #expect(fixture.log.count == 2)
    #expect(fixture.log.mainThreadCount == 0)
  }

  @Test("records beyond the tracked limit go stale and revalidate when next used")
  func untrackedRecordsRevalidateOnUse() async throws {
    let fixture = try await makeFixture(trackedLimit: 2)
    let ids: [ObjectID] = [.user(1), .user(2), .user(3), .user(4)]
    #expect(await loadAndSettle(fixture, ids))
    // Users 3 and 4 become the two most recently used, so they are the tracked ones.
    _ = fixture.cache.cached([.user(3), .user(4)])

    try await fixture.queue.write { db in
      try db.execute(sql: "UPDATE user SET firstName = 'New ' || id")
    }
    #expect(await eventually { fixture.cache.cached([.user(4)]).user(4)?.user.firstName == "New 4" })
    #expect(await eventually { fixture.cache.cached([.user(3)]).state(of: .user(3)) == .fresh })

    fixture.log.reset()
    let stale = fixture.cache.get([.user(1)])
    #expect(stale.state(of: .user(1)) == .stale)
    #expect(stale.user(1)?.user.firstName == "User 1")
    #expect(await eventually { fixture.cache.cached([.user(1)]).user(1)?.user.firstName == "New 1" })
    #expect(fixture.cache.cached([.user(1)]).state(of: .user(1)) == .fresh)
    #expect(fixture.log.mainThreadCount == 0)

    // Reading from memory alone also brings a stale record back up to date.
    #expect(fixture.cache.cached(.user(2)).user(2)?.user.firstName == "User 2")
    #expect(await eventually { fixture.cache.cached(.user(2)).user(2)?.user.firstName == "New 2" })
    #expect(fixture.log.mainThreadCount == 0)
  }

  @Test("messages are cached by chat and message id and follow edits")
  func messagesAreCached() async throws {
    let fixture = try await makeFixture()
    let id = ObjectID.message(chatId: 3, messageId: 10)
    let absent = ObjectID.message(chatId: 3, messageId: 11)
    #expect(await loadAndSettle(fixture, [id, absent]))
    let snapshot = fixture.cache.cached([id, absent])
    #expect(snapshot.message(chatId: 3, messageId: 10)?.text == "First")
    #expect(snapshot.state(of: absent) == .missing)

    try await fixture.queue.write { db in
      try db.execute(sql: "UPDATE message SET text = 'Edited' WHERE chatId = 3 AND messageId = 10")
    }
    #expect(await eventually {
      fixture.cache.cached(id).message(chatId: 3, messageId: 10)?.text == "Edited"
    })
    #expect(fixture.log.mainThreadCount == 0)
  }

  @Test("ensure asks the remote loader only for missing rows and placeholder users")
  func ensureUsesRemoteLoader() async throws {
    let fixture = try await makeFixture()
    try await fixture.queue.write { db in
      try User(id: 70, email: nil, firstName: nil).insert(db)
    }
    let asked = Mutex<[ObjectID]>([])
    let queue = fixture.queue
    fixture.cache.remoteLoader = ObjectRemoteLoader(policy: .init(coalesceWindow: .zero)) { ids in
      asked.withLock { $0.append(contentsOf: ids) }
      // Stands in for an RPC whose result is saved to the database.
      try await queue.write { db in
        try db.execute(sql: "UPDATE user SET firstName = 'Repaired' WHERE id = 70")
        try User(id: 71, email: nil, firstName: "Fetched").insert(db)
      }
      return ObjectFetchOutcome(resolved: [.user(70), .user(71)])
    }

    let snapshot = await fixture.cache.ensure([.user(1), .user(70), .user(71), .chat(3)])
    #expect(Set(asked.withLock { $0 }) == [.user(70), .user(71)])
    #expect(snapshot.user(1)?.user.firstName == "User 1")
    #expect(snapshot.user(70)?.user.firstName == "Repaired")
    #expect(snapshot.user(71)?.user.firstName == "Fetched")

    // Complete records are never sent to the remote.
    await fixture.cache.ensure([.user(70), .user(71)])
    #expect(asked.withLock { $0.count } == 2)
  }

  @Test("memory is bounded by evicting the least recently used records")
  func memoryIsBounded() async throws {
    let fixture = try await makeFixture(users: 12, trackedLimit: 2, memoryLimit: 4)
    for id in 1 ... 12 {
      await fixture.cache.load([.user(Int64(id))])
    }
    let snapshot = fixture.cache.cached((1 ... 12).map { .user(Int64($0)) })
    let loaded = (1 ... 12).filter { snapshot.state(of: .user(Int64($0))) != .unloaded }
    #expect(loaded.count <= 4)
    #expect(loaded.contains(12))
    #expect(!loaded.contains(1))
  }

  @Test("per-record publishers emit updates and clear resets everything")
  func publishersAndClear() async throws {
    let fixture = try await makeFixture()
    var names: [String?] = []
    let subscription = fixture.cache.getUserPublisher(id: 1).sink { names.append($0?.user.firstName) }
    defer { subscription.cancel() }
    // Subscribing loads in the background and delivers the first value itself.
    #expect(fixture.log.mainThreadCount == 0)
    #expect(await eventually { names.last == "User 1" })
    #expect(await loadAndSettle(fixture, [.user(1), .chat(3)]))

    try await rename(fixture, user: 1, to: "Renamed")
    #expect(await eventually { names.last == "Renamed" })

    fixture.cache.clear()
    #expect(names.last == .some(nil))
    #expect(fixture.cache.trackerCount == 0)
    #expect(fixture.cache.cached([.user(1), .chat(3)]).state(of: .chat(3)) == .unloaded)

    // The cache works again after a clear, with trackers re-attached.
    #expect(await loadAndSettle(fixture, [.user(1)]))
    #expect(fixture.cache.trackerCount == 4)
    #expect(fixture.cache.getUser(id: 1)?.user.firstName == "Renamed")
  }
}
