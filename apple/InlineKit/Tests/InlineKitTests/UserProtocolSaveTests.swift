import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("User protocol save")
struct UserProtocolSaveTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("full protocol user clears omitted optional profile fields")
  func fullUserClearsOmittedProfileFields() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try User(
        id: 100,
        email: "old@example.com",
        firstName: "Old",
        lastName: "Name",
        username: "oldhandle",
        bio: "Old bio"
      )
      .insert(db)

      var protocolUser = InlineProtocol.User()
      protocolUser.id = 100
      protocolUser.firstName = "New"
      protocolUser.min = false

      _ = try User.save(db, user: protocolUser)

      let saved = try #require(try User.fetchOne(db, id: 100))
      #expect(saved.firstName == "New")
      #expect(saved.lastName == nil)
      #expect(saved.bio == nil)
      #expect(saved.username == nil)
    }
  }

  @Test("min protocol user preserves omitted profile fields")
  func minUserPreservesOmittedProfileFields() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      try User(
        id: 101,
        email: "old@example.com",
        firstName: "Old",
        lastName: "Name",
        username: "oldhandle",
        bio: "Old bio"
      )
      .insert(db)

      var protocolUser = InlineProtocol.User()
      protocolUser.id = 101
      protocolUser.firstName = "Mini"
      protocolUser.min = true

      _ = try User.save(db, user: protocolUser)

      let saved = try #require(try User.fetchOne(db, id: 101))
      #expect(saved.firstName == "Mini")
      #expect(saved.lastName == "Name")
      #expect(saved.bio == "Old bio")
      #expect(saved.username == "oldhandle")
    }
  }
}
