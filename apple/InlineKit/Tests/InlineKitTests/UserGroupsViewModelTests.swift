import Foundation
import GRDB
import Testing

@testable import InlineKit

@MainActor
@Suite("User Groups View Model")
struct UserGroupsViewModelTests {
  @Test("database observations update main-actor state")
  func databaseObservationsUpdateMainActorState() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let viewModel = UserGroupsViewModel(db: database, spaceId: 42)

    try await queue.write { db in
      try Space(
        id: 42,
        name: "Product",
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ).insert(db)
      try UserGroup(
        id: 7,
        spaceId: 42,
        name: "Design",
        description: nil,
        memberCount: 0,
        currentUserIsMember: false,
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ).insert(db)
    }

    for _ in 0 ..< 100 where viewModel.groups.map(\.id) != [7] {
      try await Task.sleep(for: .milliseconds(10))
    }

    MainActor.preconditionIsolated()
    #expect(viewModel.groups.map(\.id) == [7])
  }
}
