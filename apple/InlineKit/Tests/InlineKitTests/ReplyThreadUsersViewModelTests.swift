import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("ReplyThreadUsersViewModel")
struct ReplyThreadUsersViewModelTests {
  private struct TimeoutError: Error {}

  private func makeInMemoryDB() throws -> (DatabaseQueue, AppDatabase) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    let database = try AppDatabase(queue)
    return (queue, database)
  }

  private static func makeUser(id: Int64, name: String) -> User {
    User(
      id: id,
      email: nil,
      firstName: name,
      lastName: nil,
      username: nil
    )
  }

  @MainActor
  private func waitUntil(
    description: String,
    timeout: Duration = .seconds(1),
    condition: @MainActor @escaping () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout

    while clock.now < deadline {
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }

    Issue.record("Timed out waiting for \(description)")
    throw TimeoutError()
  }

  @Test("ReplyThreadUsersViewModel keeps newest-first user order and skips missing users")
  @MainActor
  func usersViewModelResolvesRecentRepliers() async throws {
    let (dbQueue, database) = try makeInMemoryDB()

    try await dbQueue.write { db in
      try Self.makeUser(id: 2, name: "Second").insert(db)
      try Self.makeUser(id: 1, name: "First").insert(db)
    }

    let viewModel = ReplyThreadUsersViewModel(userIds: [2, 1, 2, 3], db: database)

    try await waitUntil(description: "initial users") {
      viewModel.users.map(\.id) == [2, 1]
    }

    try await dbQueue.write { db in
      try Self.makeUser(id: 3, name: "Third").insert(db)
    }

    try await waitUntil(description: "late-arriving user") {
      viewModel.users.map(\.id) == [2, 1, 3]
    }

    #expect(viewModel.users.map(\.id) == [2, 1, 3])
    #expect(viewModel.users.map(\.user.firstName) == ["Second", "First", "Third"])
  }

  @Test("ReplyThreadUsersViewModel exposes already-cached users immediately")
  @MainActor
  func usersViewModelBootstrapsImmediately() async throws {
    let (dbQueue, database) = try makeInMemoryDB()

    try await dbQueue.write { db in
      try Self.makeUser(id: 2, name: "Second").insert(db)
      try Self.makeUser(id: 1, name: "First").insert(db)
    }

    let viewModel = ReplyThreadUsersViewModel(userIds: [2, 1], db: database)

    #expect(viewModel.users.map(\.id) == [2, 1])
    #expect(viewModel.users.map(\.user.firstName) == ["Second", "First"])
  }
}
