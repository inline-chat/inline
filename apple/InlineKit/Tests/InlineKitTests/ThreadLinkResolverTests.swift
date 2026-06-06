import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Thread Link Resolver")
struct ThreadLinkResolverTests {
  @Test("resolves title in space case insensitively")
  func resolvesTitleInSpaceCaseInsensitively() throws {
    let queue = try makeInMemoryDB()

    try queue.write { db in
      try seedSpace(db, id: 7)
      try seedThread(db, id: 1, spaceId: 7, title: "Planning", date: 1)

      let peer = try ThreadLinkResolver.resolve(.title(spaceId: 7, title: "planning"), db: db)

      #expect(peer == .thread(id: 1))
    }
  }

  @Test("resolves newest duplicate title in space")
  func resolvesNewestDuplicateTitleInSpace() throws {
    let queue = try makeInMemoryDB()

    try queue.write { db in
      try seedSpace(db, id: 7)
      try seedThread(db, id: 1, spaceId: 7, title: "Planning", date: 1)
      try seedThread(db, id: 2, spaceId: 7, title: "planning", date: 2)

      let peer = try ThreadLinkResolver.resolve(.title(spaceId: 7, title: "Planning"), db: db)

      #expect(peer == .thread(id: 2))
    }
  }

  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  private func seedSpace(_ db: Database, id: Int64) throws {
    try Space(id: id, name: "Space \(id)", date: Date(timeIntervalSince1970: 1)).insert(db)
  }

  private func seedThread(
    _ db: Database,
    id: Int64,
    spaceId: Int64,
    title: String,
    date: TimeInterval
  ) throws {
    try Chat(
      id: id,
      date: Date(timeIntervalSince1970: date),
      type: .thread,
      title: title,
      spaceId: spaceId
    ).insert(db)
  }
}
