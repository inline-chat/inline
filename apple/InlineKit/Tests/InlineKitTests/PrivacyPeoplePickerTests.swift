import Foundation
import GRDB
@testable import InlineKit
import Synchronization
import Testing

@Suite("Privacy exception people", .serialized)
@MainActor
struct PrivacyPeoplePickerTests {
  @Test("Done can preserve existing exceptions before names start loading")
  func keepsSelectionBeforeLoading() throws {
    let fixture = try PickerFixture()
    let model = PrivacyPeoplePickerModel(selectedIDs: [99, 2], database: fixture.database)

    #expect(model.selectedIDs == [99, 2])
    #expect(model.unresolvedIDs == [99, 2])
  }

  @Test("a failed people read preserves the list being saved")
  func failedReadPreservesSelection() async throws {
    let fixture = try PickerFixture()
    let model = PrivacyPeoplePickerModel(selectedIDs: [2, 99], database: fixture.database)
    // Keep GRDB's observed writer alive: closing it while its observation callbacks
    // are pending can crash instead of delivering a query error to the picker.
    try await fixture.queue.write { db in
      try db.execute(sql: "DROP TABLE \"user\"")
    }

    await model.load()

    #expect(model.selectedIDs == [2, 99])
    #expect(model.unresolvedIDs == [2, 99])
  }

  @Test("name hydration cannot undo removals or additions made while its read is pending")
  func hydrationPreservesEdits() async throws {
    let fixture = try PickerFixture()
    let model = PrivacyPeoplePickerModel(selectedIDs: [2, 99], database: fixture.database)
    fixture.gate.arm()
    let load = Task { await model.load() }
    defer { fixture.gate.release() }
    await fixture.gate.waitUntilReading()

    #expect(model.selectedIDs == [2, 99])
    model.remove(id: 2)
    model.remove(id: 99)
    model.add(UserInfo(user: User(id: 3, email: nil, firstName: "New person")))
    fixture.gate.release()
    await load.value

    #expect(model.selectedIDs == [3])
    #expect(model.selectedUsers.map(\.id) == [3])
    #expect(model.unresolvedIDs.isEmpty)
  }

  @Test("hydration retains unknown exceptions and the original selection order")
  func hydrationPreservesUnknownPeople() async throws {
    let fixture = try PickerFixture()
    let model = PrivacyPeoplePickerModel(selectedIDs: [99, 2], database: fixture.database)

    await model.load()

    #expect(model.selectedIDs == [99, 2])
    #expect(model.selectedUsers.map(\.id) == [2])
    #expect(model.unresolvedIDs == [99])
  }
}

private struct PickerFixture {
  let gate = PickerReadGate()
  let queue: DatabaseQueue
  let database: AppDatabase

  init() throws {
    var configuration = AppDatabase.makeConfiguration(passphrase: "123")
    configuration.prepareDatabase { [gate] db in
      db.trace(options: .statement) { gate.beforeStatement($0.expandedDescription) }
    }
    queue = try DatabaseQueue(configuration: configuration)
    database = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 2, email: nil, firstName: "Existing person").insert(db)
    }
  }
}

private final class PickerReadGate: Sendable {
  private let armed = Mutex(false)
  private let semaphore = DispatchSemaphore(value: 0)
  private let entered = AsyncStream<Void>.makeStream()

  func arm() {
    armed.withLock { $0 = true }
  }

  func beforeStatement(_ sql: String) {
    guard sql.hasPrefix("SELECT"), armed.withLock({ value in
      guard value else { return false }
      value = false
      return true
    }) else { return }
    entered.continuation.yield(())
    semaphore.wait()
  }

  func waitUntilReading() async {
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
  }

  func release() {
    semaphore.signal()
  }
}
