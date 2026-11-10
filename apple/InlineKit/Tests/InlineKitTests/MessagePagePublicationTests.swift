import Foundation
import GRDB
import Synchronization
import Testing

@testable import InlineKit

@Suite("Message pages retain publications that cross their database snapshot")
struct MessagePagePublicationTests {
  @Test @MainActor
  func offWindowDeleteIsNotResurrectedByAnOlderPage() async throws {
    let fixture = try await PageFixture()
    defer { fixture.close() }
    let model = try await fixture.model()
    defer { model.dispose() }
    fixture.gate.arm()
    let page = Task { @MainActor in await model.loadBatchAsync(at: .older) }
    defer { fixture.gate.release() }
    try await fixture.gate.waitUntilSnapshotWasRead()

    try await fixture.database.dbWriter.write { db in
      try Message.filter(Message.Columns.chatId == 1 && Message.Columns.messageId == 230).deleteAll(db)
    }
    fixture.publisher.publisher.send(.delete(.init(messageIds: [230], peer: .thread(id: 1))))
    fixture.gate.release()

    #expect(await page.value)
    #expect(model.messages.contains { $0.message.messageId == 229 })
    #expect(!model.messages.contains { $0.message.messageId == 230 })
  }

  @Test @MainActor
  func offWindowEditWinsOverTheOlderPageSnapshot() async throws {
    let fixture = try await PageFixture()
    defer { fixture.close() }
    let model = try await fixture.model()
    defer { model.dispose() }
    fixture.gate.arm()
    let page = Task { @MainActor in await model.loadBatchAsync(at: .older) }
    defer { fixture.gate.release() }
    try await fixture.gate.waitUntilSnapshotWasRead()

    let edited = try await fixture.database.dbWriter.write { db in
      try db.execute(sql: "UPDATE message SET text = 'Edited while paging' WHERE chatId = 1 AND messageId = 230")
      return try #require(try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1 && Column("messageId") == 230).fetchOne(db))
    }
    fixture.publisher.publisher.send(.update(.init(message: edited, animated: false, peer: .thread(id: 1))))
    fixture.gate.release()

    #expect(await page.value)
    #expect(model.messages.first { $0.message.messageId == 230 }?.message.text == "Edited while paging")
    #expect(model.messagesByID[edited.id]?.message.text == "Edited while paging")
  }
}

private struct PageFixture {
  let directory: URL
  let database: AppDatabase
  let publisher: MessagesPublisher
  let gate: PageSnapshotGate

  @MainActor init() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("inline-page-publication-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    gate = PageSnapshotGate()
    var configuration = AppDatabase.makeConfiguration(passphrase: "123")
    configuration.prepareDatabase { [gate] db in
      db.trace(options: .profile) { event in
        guard case let .profile(statement, _) = event else { return }
        gate.afterStatement(statement.expandedSQL)
      }
    }
    let pool = try DatabasePool(path: directory.appendingPathComponent("db.sqlite").path, configuration: configuration)
    database = try AppDatabase(pool)
    publisher = MessagesPublisher(database: database)
    try await pool.write { db in
      try User(id: 1, email: nil, firstName: "Page fixture").insert(db)
      try User(id: 2, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 1, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Page", spaceId: nil, lastMsgId: 300)
        .insert(db)
      for id in Int64(1) ... 300 {
        var message = Message(
          messageId: id, fromId: 2, date: Date(timeIntervalSince1970: Double(id)), text: "Before",
          peerUserId: nil, peerThreadId: 1, chatId: 1
        )
        try message.saveMessage(db)
      }
      try MessageHistoryCoverageStore.subtract(db, chatId: 1, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax)
    }
  }

  @MainActor func model() async throws -> MessagesProgressiveViewModel {
    let state = try await database.reader.read { db in
      let rows = try FullMessage.queryRequest(currentUserId: 1)
        .filter(Column("chatId") == 1).order(Column("messageId").desc).limit(60).fetchAll(db).reversed()
      let messages = Array(rows)
      return MessagesProgressiveViewModel.InitialState(
        messages: messages,
        threadAnchor: .resolved(nil),
        loadedWindowMetadata: try MessagesProgressiveViewModel.loadedWindowMetadata(db, peer: .thread(id: 1), messages: messages)
      )
    }
    return MessagesProgressiveViewModel(
      peer: .thread(id: 1), initialState: state, database: database, publisher: publisher, currentUserId: 1
    )
  }

  func close() {
    gate.release()
    try? database.dbWriter.close()
    try? FileManager.default.removeItem(at: directory)
  }
}

private final class PageSnapshotGate: Sendable {
  private let armed = Mutex(false)
  private let semaphore = DispatchSemaphore(value: 0)
  private let entered = AsyncStream<Void>.makeStream()

  func arm() { armed.withLock { $0 = true } }

  func afterStatement(_ sql: String) {
    // The transcript SELECT has finished and holds its WAL snapshot. Other pool readers
    // and the writer remain free to publish a real delete/edit before the page resumes.
    guard sql.contains("messageId"), sql.contains("< 241"), sql.contains("LIMIT 100"),
          armed.withLock({ value in
            guard value else { return false }
            value = false
            return true
          })
    else { return }
    entered.continuation.yield(())
    _ = semaphore.wait(timeout: .now() + 10)
  }

  func waitUntilSnapshotWasRead() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        var iterator = self.entered.stream.makeAsyncIterator()
        _ = await iterator.next()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw SnapshotTimeout()
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  func release() { semaphore.signal() }
  private struct SnapshotTimeout: Error {}
}
