import Foundation
import GRDB
import Testing

@testable import InlineKit

@MainActor
@Suite("Space Full Members View Model")
struct SpaceFullMembersViewModelTests {
  @Test("database observations update main-actor state")
  func databaseObservationsUpdateMainActorState() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let viewModel = SpaceFullMembersViewModel(db: database, spaceId: 42)

    try await queue.write { db in
      try Space(
        id: 42,
        name: "Product",
        date: Date(timeIntervalSince1970: 1_700_000_000)
      ).insert(db)
      try User(id: 7, email: nil, firstName: "Visible").insert(db)
      try Member(
        id: 8,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        userId: 7,
        spaceId: 42
      ).insert(db)
    }

    for _ in 0 ..< 100 where viewModel.members.map(\.userInfo.user.id) != [7] {
      try await Task.sleep(for: .milliseconds(10))
    }

    MainActor.preconditionIsolated()
    #expect(viewModel.space?.id == 42)
    #expect(viewModel.members.map(\.userInfo.user.id) == [7])
  }
}
