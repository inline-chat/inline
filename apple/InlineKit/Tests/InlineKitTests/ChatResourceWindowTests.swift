import Dispatch
import Foundation
import GRDB
@testable import InlineKit
import RealtimeV2
import Testing

@Suite("Chat info resource windows")
@MainActor
struct ChatResourceWindowTests {
  @Test("construction never waits on a busy database or claims an empty cache")
  func initialObservationDoesNotBlockConstruction() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: [90])
    let gate = DispatchSemaphore(value: 0)
    await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
      queue.asyncWriteWithoutTransaction { _ in
        ready.resume()
        // Bound a regression so a synchronous observer fails without hanging.
        _ = gate.wait(timeout: .now() + 2)
      }
    }
    let clock = ContinuousClock()
    let started = clock.now
    let window = makeWindow(database: database) { _ in
      try await queue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db, chatId: 7, scope: .media,
          lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    #expect(clock.now - started < .seconds(1))
    #expect(window.rows.isEmpty)
    #expect(window.loadState == .idle)
    #expect(!window.isEmptyConfirmed)
    gate.signal()

    await window.loadInitial()
    #expect(window.rows == [90])
    #expect(window.loadState == .complete)
  }

  @Test("hidden pages retain demand and advance from raw hole boundaries")
  func hiddenPagesDoNotStall() async throws {
    let (database, queue) = try makeDatabase()
    let recorder = ResourceRequestRecorder()
    let window = makeWindow(database: database) { offset in
      await recorder.append(offset)
      try await queue.write { db in
        if offset == nil {
          // Fifty raw results had no renderable projection (for example,
          // reconciled membership). Their raw minimum is still the frontier.
          try MessageHistoryCoverageStore.subtract(
            db,
            chatId: 7,
            scope: .media,
            lowerId: 51,
            upperId: MessageHistoryHole.positiveMessageIDMax
          )
        } else {
          #expect(offset == 51)
          try MessageHistoryCoverageStore.subtract(db, chatId: 7, scope: .media, lowerId: 1, upperId: 50)
        }
      }
    }

    await window.loadInitial()
    #expect(await recorder.offsets == [nil, 51])
    #expect(window.rows.isEmpty)
    #expect(window.isEmptyConfirmed)
    #expect(window.loadState == .complete)
  }

  @Test("sparse cached rows cannot skip unknown intervals inside the window")
  func cachedRowsDoNotProveCoverage() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: Array(1 ... 100).map(Int64.init))
    let recorder = ResourceRequestRecorder()
    let window = makeWindow(database: database) { offset in
      await recorder.append(offset)
      try await queue.write { db in
        if offset == nil {
          try MessageHistoryCoverageStore.subtract(
            db,
            chatId: 7,
            scope: .media,
            lowerId: 81,
            upperId: MessageHistoryHole.positiveMessageIDMax
          )
        } else {
          #expect(offset == 81)
          try MessageHistoryCoverageStore.subtract(db, chatId: 7, scope: .media, lowerId: 1, upperId: 80)
        }
      }
    }

    await window.loadInitial()
    #expect(await recorder.offsets == [nil, 81])
    #expect(window.rows.count == 50)
    // Coverage is complete, but the bounded projection has older cached rows.
    #expect(window.hasMore)
    #expect(window.loadState == .idle)
    await window.loadMore()
    #expect(window.rows.count == 100)
    #expect(await recorder.offsets == [nil, 81])
    #expect(window.loadState == .complete)
  }

  @Test("errors retain cached occurrences and retry the uncertified page")
  func errorsRetainContent() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: [90, 89])
    let recorder = ResourceRequestRecorder()
    let window = makeWindow(database: database) { offset in
      let attempt = await recorder.append(offset)
      if attempt == 1 {
        throw ResourceTestError.offline
      }
      try await queue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db,
          chatId: 7,
          scope: .media,
          lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }

    await window.loadInitial()
    #expect(window.rows == [90, 89])
    #expect(window.loadState == .failed)
    #expect(!window.isEmptyConfirmed)
    await window.retry()
    #expect(await recorder.offsets == [nil, nil])
    #expect(window.rows == [90, 89])
    #expect(window.loadState == .complete)
  }

  @Test("Retry restores live resource updates after a terminal database observation failure")
  func retryRestartsFailedObservation() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: Array(1 ... 60).map(Int64.init))
    let reads = ResourceReadProbe()
    let requests = ResourceRequestRecorder()
    let window = makeWindow(database: database, reads: reads) { offset in
      await requests.append(offset)
      try await queue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db, chatId: 7, scope: .media, lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    await window.loadInitial()
    await window.loadMore()
    #expect(window.rows.count == 60)
    try await insertResource(61, into: queue)
    try #require(await eventually { window.rows.first == 61 })

    // Fail the actual GRDB observation on a tracked-table notification.
    reads.failNextRead()
    try await insertResource(62, into: queue)
    try #require(await eventually { window.loadState == .failed })
    #expect(window.rows.count == 61)
    #expect(window.rows.first == 61)

    await window.retry()
    #expect(window.rows.count == 62) // Earlier Load more demand survives Retry.
    #expect(window.rows.first == 62)
    #expect(window.loadState == .complete)
    #expect(await requests.offsets == [nil])

    try await insertResource(63, into: queue)
    #expect(await eventually { window.rows.first == 63 && window.rows.count == 63 })
    try await queue.write { db in
      try db.execute(sql: "DELETE FROM message WHERE chatId = 7 AND messageId IN (61, 62, 63)")
    }
    #expect(await eventually { window.rows.first == 60 && window.rows.count == 60 })
    #expect(await requests.offsets == [nil])
  }

  @Test("repeated Retry keeps exactly one live resource observation")
  func repeatedRetryDoesNotDuplicateObservation() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: [90])
    let reads = ResourceReadProbe()
    let window = makeWindow(database: database, reads: reads) { _ in
      try await queue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db, chatId: 7, scope: .media, lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    await window.loadInitial()
    try await insertResource(91, into: queue)
    try #require(await eventually { window.rows.first == 91 })
    reads.failNextRead()
    try await insertResource(92, into: queue)
    try #require(await eventually { window.loadState == .failed })
    await window.retry()
    await window.retry()
    await window.retry()
    _ = try await queue.read { _ in true }
    let before = reads.count

    try await insertResource(93, into: queue)
    try #require(await eventually { window.rows.first == 93 })
    _ = try await queue.read { _ in true }
    #expect(reads.count == before + 1)
  }

  @Test("recovered resource observations end when their account window is released")
  func recoveredObservationDoesNotOutliveWindow() async throws {
    let (oldDatabase, oldQueue) = try makeDatabase(cachedIDs: [90])
    let reads = ResourceReadProbe()
    var oldWindow: ChatResourceWindow<Int64>? = makeWindow(database: oldDatabase, reads: reads) { _ in
      try await oldQueue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db, chatId: 7, scope: .media, lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    await oldWindow?.loadInitial()
    try await insertResource(91, into: oldQueue)
    try #require(await eventually { oldWindow?.rows.first == 91 })
    reads.failNextRead()
    try await insertResource(92, into: oldQueue)
    try #require(await eventually { oldWindow?.loadState == .failed })
    await oldWindow?.retry()
    _ = try await oldQueue.read { _ in true }
    weak var releasedWindow = oldWindow
    oldWindow = nil
    try #require(await eventually { releasedWindow == nil })
    let before = reads.count

    // Account/view replacement owns a different database and observation.
    let (newDatabase, newQueue) = try makeDatabase(cachedIDs: [10])
    let newWindow = makeWindow(database: newDatabase) { _ in
      try await newQueue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db, chatId: 7, scope: .media, lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    await newWindow.loadInitial()
    try await insertResource(93, into: oldQueue)
    _ = try await oldQueue.read { _ in true }
    #expect(reads.count == before)
    #expect(newWindow.rows == [10])
    try await insertResource(11, into: newQueue)
    #expect(await eventually { newWindow.rows == [11, 10] })
  }

  @Test("normal admission races retry a fresh token at the same cursor")
  func staleAdmissionRetries() async throws {
    let (database, queue) = try makeDatabase()
    let recorder = ResourceRequestRecorder()
    let window = makeWindow(database: database) { offset in
      let attempt = await recorder.append(offset)
      if attempt == 1 {
        throw TransactionExecutionError.staleHistory
      }
      try await queue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db,
          chatId: 7,
          scope: .media,
          lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    await window.loadInitial()
    #expect(await recorder.offsets == [nil, nil])
    #expect(window.loadState == .complete)
    #expect(window.isEmptyConfirmed)
  }

  @Test("an unchanged older page fails without looping or losing demand, then retries its cursor")
  func unchangedPageRetainsDemand() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: [90, 89])
    let recorder = ResourceRequestRecorder()
    let window = makeWindow(database: database) { offset in
      let attempt = await recorder.append(offset)
      if attempt == 2 {
        return
      } // Duplicate response made no certified progress.
      try await queue.write { (db: Database) throws in
        try MessageHistoryCoverageStore.subtract(
          db, chatId: 7, scope: .media,
          lowerId: offset == nil ? 81 : 1,
          upperId: offset == nil ? MessageHistoryHole.positiveMessageIDMax : 80
        )
      }
    }
    await window.loadInitial()
    #expect(await recorder.offsets == [nil, 81])
    #expect(window.rows == [90, 89])
    #expect(window.loadState == .failed)
    #expect(!window.isEmptyConfirmed)
    await window.retry()
    #expect(await recorder.offsets == [nil, 81, 81])
    #expect(window.rows == [90, 89])
    #expect(window.loadState == .complete)
  }

  @Test("persistent admission races stop after bounded retries and remain unknown")
  func staleAdmissionRetryIsBounded() async throws {
    let (database, _) = try makeDatabase()
    let recorder = ResourceRequestRecorder()
    let window = makeWindow(database: database) { offset in
      await recorder.append(offset)
      throw TransactionExecutionError.staleHistory
    }
    await window.loadInitial()
    #expect(await recorder.offsets == [nil, nil, nil])
    #expect(window.loadState == .failed)
    #expect(!window.isEmptyConfirmed)
  }

  @Test("inactive panes neither observe changes nor start page requests")
  func inactivePaneIsDormant() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: [90])
    let reads = ResourceReadProbe()
    let requests = ResourceRequestRecorder()
    let window = makeWindow(database: database, reads: reads) { offset in
      await requests.append(offset)
      try await queue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db,
          chatId: 7,
          scope: .media,
          lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    try await insertResource(91, into: queue)
    _ = try await queue.read { _ in true }
    #expect(reads.count == 0)
    #expect(await requests.offsets.isEmpty)
    await window.loadInitial()
    #expect(window.rows == [91, 90])
    window.deactivate()
    try await insertResource(92, into: queue)
    _ = try await queue.read { _ in true }
    #expect(window.rows == [91, 90])
    await window.loadInitial()
    #expect(window.rows == [92, 91, 90])
    #expect(await requests.offsets == [nil, nil])
    window.deactivate()
  }

  @Test("reopening after a cancelled first load resumes demand with one request owner")
  func cancelledFirstLoadResumes() async throws {
    let (database, queue) = try makeDatabase(cachedIDs: [90])
    let gate = ResourcePageGate()
    let requests = ResourceRequestRecorder()
    let window = makeWindow(database: database) { offset in
      let attempt = await requests.append(offset)
      if attempt == 1 {
        await gate.wait()
      }
      try Task.checkCancellation()
      try await queue.write { db in
        try MessageHistoryCoverageStore.subtract(
          db,
          chatId: 7,
          scope: .media,
          lowerId: 1,
          upperId: MessageHistoryHole.positiveMessageIDMax
        )
      }
    }
    let first = Task { await window.loadInitial() }
    try #require(await eventually { window.rows == [90] && window.loadState == .loading })
    window.deactivate()
    let reopened = Task { await window.loadInitial() }
    try await insertResource(91, into: queue)
    await gate.release()
    await first.value
    await reopened.value
    #expect(await requests.offsets == [nil, nil])
    #expect(window.rows == [91, 90])
    #expect(window.loadState == .complete)
    window.deactivate()
  }

  private func makeWindow(
    database: AppDatabase,
    reads: ResourceReadProbe? = nil,
    fetch: @escaping @Sendable (Int64?) async throws -> Void
  ) -> ChatResourceWindow<Int64> {
    ChatResourceWindow(
      db: database, chatId: 7, peer: .thread(id: 7), scope: .media,
      fetchRows: { db, count in
        try reads?.read()
        return try Int64.fetchAll(
          db,
          sql: "SELECT messageId FROM message WHERE chatId = 7 ORDER BY messageId DESC LIMIT ?",
          arguments: [count]
        )
      },
      messageID: { $0 }, fetchPage: fetch
    )
  }

  private func insertResource(_ id: Int64, into queue: DatabaseQueue) async throws {
    try await queue.write { db in
      var message = Message(
        messageId: id, fromId: 1, date: Date(timeIntervalSince1970: Double(id)),
        text: "live", peerUserId: nil, peerThreadId: 7, chatId: 7
      )
      try message.saveMessage(db)
    }
  }

  private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  private func makeDatabase(cachedIDs: [Int64] = []) throws -> (AppDatabase, DatabaseQueue) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 1, email: "resources@example.com", firstName: "Resources").insert(db)
      try Chat(id: 7, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Resources", spaceId: nil).insert(db)
      for id in cachedIDs {
        var message = Message(
          messageId: id,
          fromId: 1,
          date: Date(timeIntervalSince1970: Double(id)),
          text: "cached",
          peerUserId: nil,
          peerThreadId: 7,
          chatId: 7
        )
        try message.saveMessage(db)
      }
    }
    return (database, queue)
  }
}

private actor ResourceRequestRecorder {
  private(set) var offsets: [Int64?] = []
  @discardableResult func append(_ offset: Int64?) -> Int {
    offsets.append(offset)
    return offsets.count
  }
}

private final class ResourceReadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var readCount = 0
  private var shouldFail = false

  var count: Int {
    lock.withLock { readCount }
  }

  func failNextRead() {
    lock.withLock { shouldFail = true }
  }

  func read() throws {
    try lock.withLock {
      readCount += 1
      if shouldFail {
        shouldFail = false
        throw ResourceTestError.observation
      }
    }
  }
}

private enum ResourceTestError: Error { case offline, observation }

private actor ResourcePageGate {
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async {
    if released {
      return
    }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
