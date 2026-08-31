import Combine
import Dispatch
import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Participant search lifetime")
@MainActor
struct ParticipantSearchViewModelTests {
  @Test("clearing the query cancels a queued search without repopulating results")
  func clearingQueryDiscardsQueuedResults() async throws {
    let database = try makeDatabase()
    let model = ParticipantSearchViewModel(db: database, spaceId: 77)

    model.search(query: "Alice")
    let pendingSearch = try #require(model.searchTask)
    model.search(query: "")

    #expect(model.results.isEmpty)
    await pendingSearch.value
    #expect(model.results.isEmpty)
  }

  @Test("only the newest queued query publishes participants")
  func newestQueryWins() async throws {
    let database = try makeDatabase()
    let model = ParticipantSearchViewModel(db: database, spaceId: 77)

    model.search(query: "Alice")
    let firstSearch = try #require(model.searchTask)
    model.search(query: "Bob")
    let secondSearch = try #require(model.searchTask)

    await secondSearch.value
    await firstSearch.value
    #expect(model.results.map(\.user.id) == [2])
  }

  @Test("a queued search does not retain a dismissed participant picker")
  func queuedSearchReleasesModel() async throws {
    let database = try makeDatabase()
    var model: ParticipantSearchViewModel? = ParticipantSearchViewModel(db: database, spaceId: 77)
    weak var weakModel = model

    model?.search(query: "Alice")
    let pendingSearch = try #require(model?.searchTask)
    model = nil

    #expect(weakModel == nil)
    await pendingSearch.value
    #expect(weakModel == nil)
  }

  @Test("an in-flight obsolete query cannot clear or replace the current results")
  func inFlightSearchCannotPublishAfterReplacement() async throws {
    let database = try makeDatabase()
    let model = ParticipantSearchViewModel(db: database, spaceId: 77)
    model.search(query: "Bob")
    await model.searchTask?.value
    try #require(model.results.map(\.user.id) == [2])

    let releaseQuery = DispatchSemaphore(value: 0)
    let (queryStarted, signalQueryStarted) = AsyncStream<Void>.makeStream()
    try await database.dbWriter.write { db in
      var didBlock = false
      db.trace { event in
        guard !didBlock, case let .statement(statement) = event,
              statement.sql.contains("user.firstName LIKE")
        else { return }
        didBlock = true
        signalQueryStarted.yield(())
        signalQueryStarted.finish()
        _ = releaseQuery.wait(timeout: .now() + 5)
      }
    }
    defer {
      releaseQuery.signal()
      signalQueryStarted.finish()
    }

    var publishedIDs: [[Int64]] = []
    let observation = model.$results.sink { publishedIDs.append($0.map(\.user.id)) }
    defer { observation.cancel() }
    model.search(query: "Alice")
    let firstSearch = try #require(model.searchTask)
    let finishSignal = Task {
      await firstSearch.value
      signalQueryStarted.finish()
    }
    var started = queryStarted.makeAsyncIterator()
    try #require(await started.next() != nil)

    model.search(query: "Bob")
    let secondSearch = try #require(model.searchTask)
    releaseQuery.signal()
    await firstSearch.value
    await secondSearch.value
    await finishSignal.value

    #expect(model.results.map(\.user.id) == [2])
    #expect(publishedIDs.allSatisfy { $0 == [2] })
  }

  private func makeDatabase() throws -> AppDatabase {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    try queue.write { db in
      try Space(id: 77, name: "People", date: Date(timeIntervalSince1970: 1)).insert(db)
      for (id, name) in [(Int64(1), "Alice"), (Int64(2), "Bob")] {
        try User(id: id, email: nil, firstName: name).insert(db)
        try Member(id: id, date: Date(timeIntervalSince1970: 1), userId: id, spaceId: 77).insert(db)
      }
    }
    return database
  }
}
