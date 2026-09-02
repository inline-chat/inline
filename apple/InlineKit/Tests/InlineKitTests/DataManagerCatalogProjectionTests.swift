import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("DataManager catalog projections")
@MainActor
struct DataManagerCatalogProjectionTests {
  @Test("catalog compatibility methods only read their local projections")
  func catalogMethodsReadLocalDatabase() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)

    try await queue.write { (db: Database) throws in
      try User(id: 200, email: nil, firstName: "Peer").save(db)
      try Space(id: 10, name: "One", date: Date(timeIntervalSince1970: 10)).save(db)
      try Space(id: 20, name: "Two", date: Date(timeIntervalSince1970: 20)).save(db)

      let privateChat = Chat(
        id: 100,
        date: Date(timeIntervalSince1970: 100),
        type: .privateChat,
        title: nil,
        spaceId: nil,
        peerUserId: 200
      )
      let firstThread = Chat(
        id: 110,
        date: Date(timeIntervalSince1970: 110),
        type: .thread,
        title: "First",
        spaceId: 10
      )
      let secondThread = Chat(
        id: 120,
        date: Date(timeIntervalSince1970: 120),
        type: .thread,
        title: "Second",
        spaceId: 20
      )
      try privateChat.save(db)
      try firstThread.save(db)
      try secondThread.save(db)
      try Dialog(optimisticForChat: firstThread).save(db)
      try Dialog(optimisticForChat: secondThread).save(db)
    }

    let data = DataManager(database: database, auth: Auth.mocked(authenticated: true).handle)
    let spaces = try await data.getSpaces()
    let privateChats = try await data.getPrivateChats()
    let dialogs = try await data.getDialogs(spaceId: 10)

    #expect(Set(spaces.map(\.id)) == [10, 20])
    #expect(privateChats.map(\.id) == [100])
    #expect(dialogs.compactMap(\.peerThreadId) == [110])
  }

  @Test("targeted space refresh cannot regress a newer bucket projection")
  func targetedSpaceRefreshRejectsStaleSnapshot() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 7, email: nil, firstName: "Me").save(db)
      try Space(
        id: 10,
        name: "Current",
        date: Date(timeIntervalSince1970: 10),
        seq: 12,
        memberRosterComplete: true
      ).save(db)
      try DbBucketState(
        bucketType: BucketKey.space(id: 10).getBucket(),
        entityId: BucketKey.space(id: 10).getEntityId(),
        date: 12,
        seq: 12
      ).save(db)

      let imported = try DataManager.applyTargetedSpaceSnapshot(
        makeSpaceResult(spaceID: 10, userID: 7, sequence: 11, name: "Stale"),
        expectedSpaceID: 10,
        authenticatedUserID: 7,
        in: db
      )

      #expect(imported.applied == false)
      #expect(imported.catchUpTarget == nil)
      #expect(try Space.fetchOne(db, key: 10)?.name == "Current")
      #expect(try Space.fetchOne(db, key: 10)?.memberRosterComplete == true)
      #expect(try Member.fetchCount(db) == 0)
    }
  }

  @Test("newer cached space sequence remains the exact demand when response is older")
  func targetedSpaceRefreshKeepsNewerKnownTarget() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 7, email: nil, firstName: "Me").save(db)
      try Space(
        id: 10,
        name: "Newer cached metadata",
        date: Date(timeIntervalSince1970: 20),
        seq: 20,
        memberRosterComplete: true
      ).save(db)
      try DbBucketState(
        bucketType: BucketKey.space(id: 10).getBucket(),
        entityId: BucketKey.space(id: 10).getEntityId(),
        date: 10,
        seq: 10
      ).save(db)

      let imported = try DataManager.applyTargetedSpaceSnapshot(
        makeSpaceResult(spaceID: 10, userID: 7, sequence: 15, name: "Older response"),
        expectedSpaceID: 10,
        authenticatedUserID: 7,
        in: db
      )

      #expect(imported.applied == false)
      #expect(imported.catchUpTarget == 20)
      #expect(try Space.fetchOne(db, key: 10)?.name == "Newer cached metadata")
      #expect(try Space.fetchOne(db, key: 10)?.memberRosterComplete == false)
      #expect(try Member.fetchCount(db) == 0)
    }
  }

  @Test("unsequenced snapshot cannot treat a persisted zero cursor as pristine")
  func targetedUnsequencedSpaceRefreshPreservesZeroCursor() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 7, email: nil, firstName: "Me").save(db)
      try DbBucketState(
        bucketType: BucketKey.space(id: 10).getBucket(),
        entityId: BucketKey.space(id: 10).getEntityId(),
        date: 0,
        seq: 0
      ).save(db)

      let imported = try DataManager.applyTargetedSpaceSnapshot(
        makeSpaceResult(spaceID: 10, userID: 7, sequence: nil, name: "Unsequenced"),
        expectedSpaceID: 10,
        authenticatedUserID: 7,
        in: db
      )

      #expect(imported.applied == false)
      #expect(imported.catchUpTarget == 0)
      #expect(try Space.fetchCount(db) == 0)
      #expect(try Member.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchOne(db)?.seq == 0)
    }
  }

  @Test("unsequenced response requests latest even when cached metadata has a newer sequence")
  func targetedUnsequencedSpaceRefreshDoesNotUseCachedSequenceAsCeiling() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 7, email: nil, firstName: "Me").save(db)
      try Space(
        id: 10,
        name: "Cached",
        date: Date(timeIntervalSince1970: 20),
        seq: 20,
        memberRosterComplete: true
      ).save(db)
      try DbBucketState(
        bucketType: BucketKey.space(id: 10).getBucket(),
        entityId: BucketKey.space(id: 10).getEntityId(),
        date: 10,
        seq: 10
      ).save(db)

      let imported = try DataManager.applyTargetedSpaceSnapshot(
        makeSpaceResult(spaceID: 10, userID: 7, sequence: nil, name: "Unknown frontier"),
        expectedSpaceID: 10,
        authenticatedUserID: 7,
        in: db
      )

      #expect(imported.applied == false)
      #expect(imported.catchUpTarget == 0)
      #expect(try Space.fetchOne(db, key: 10)?.name == "Cached")
      #expect(try Space.fetchOne(db, key: 10)?.memberRosterComplete == false)
      #expect(try Member.fetchCount(db) == 0)
    }
  }

  @Test("space snapshot ahead of cursor creates one exact demand and invalidates roster completeness")
  func targetedSpaceRefreshReturnsExactDemand() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 7, email: nil, firstName: "Me").save(db)
      try User(id: 8, email: nil, firstName: "Cached member").save(db)
      try Space(
        id: 10,
        name: "Cached",
        date: Date(timeIntervalSince1970: 10),
        seq: 10,
        memberRosterComplete: true
      ).save(db)
      try Member(
        id: 80,
        date: Date(timeIntervalSince1970: 1),
        userId: 8,
        spaceId: 10
      ).save(db)
      try DbBucketState(
        bucketType: BucketKey.space(id: 10).getBucket(),
        entityId: BucketKey.space(id: 10).getEntityId(),
        date: 10,
        seq: 10
      ).save(db)

      let imported = try DataManager.applyTargetedSpaceSnapshot(
        makeSpaceResult(spaceID: 10, userID: 7, sequence: 12, name: "Fresh metadata"),
        expectedSpaceID: 10,
        authenticatedUserID: 7,
        in: db
      )

      #expect(imported.applied)
      #expect(imported.catchUpTarget == 12)
      #expect(try Space.fetchOne(db, key: 10)?.name == "Fresh metadata")
      #expect(try Space.fetchOne(db, key: 10)?.memberRosterComplete == false)
      #expect(Set(try Member.fetchAll(db).map(\.userId)) == [7, 8])
      #expect(try DbBucketState.fetchOne(db)?.seq == 10)
    }
  }

  @Test("space snapshot at the cursor preserves certified roster completeness")
  func targetedSpaceRefreshAtCursorPreservesCompleteness() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 7, email: nil, firstName: "Me").save(db)
      try Space(
        id: 10,
        name: "Cached",
        date: Date(timeIntervalSince1970: 10),
        seq: 10,
        memberRosterComplete: true
      ).save(db)
      try DbBucketState(
        bucketType: BucketKey.space(id: 10).getBucket(),
        entityId: BucketKey.space(id: 10).getEntityId(),
        date: 10,
        seq: 10
      ).save(db)

      let imported = try DataManager.applyTargetedSpaceSnapshot(
        makeSpaceResult(spaceID: 10, userID: 7, sequence: 10, name: "Equal"),
        expectedSpaceID: 10,
        authenticatedUserID: 7,
        in: db
      )

      #expect(imported.applied)
      #expect(imported.catchUpTarget == nil)
      #expect(try Space.fetchOne(db, key: 10)?.name == "Equal")
      #expect(try Space.fetchOne(db, key: 10)?.memberRosterComplete == true)
    }
  }

  @Test("targeted space refresh imports only the authenticated membership")
  func targetedSpaceRefreshValidatesMembershipOwner() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { (db: Database) throws in
      try User(id: 7, email: nil, firstName: "Me").save(db)

      #expect(throws: InlineRPCClientError.self) {
        try DataManager.applyTargetedSpaceSnapshot(
          makeSpaceResult(spaceID: 10, userID: 8, sequence: 1, name: "Wrong account"),
          expectedSpaceID: 10,
          authenticatedUserID: 7,
          in: db
        )
      }
      #expect(try Space.fetchCount(db) == 0)
      #expect(try Member.fetchCount(db) == 0)

      let imported = try DataManager.applyTargetedSpaceSnapshot(
        makeSpaceResult(spaceID: 10, userID: 7, sequence: 1, name: "Current"),
        expectedSpaceID: 10,
        authenticatedUserID: 7,
        in: db
      )
      #expect(imported.applied)
      #expect(imported.catchUpTarget == 1)
      #expect(try Space.fetchOne(db, key: 10)?.name == "Current")
      #expect(try Member.fetchAll(db).map(\.userId) == [7])
      #expect(try DbBucketState.fetchCount(db) == 0)
    }
  }

  private func makeSpaceResult(
    spaceID: Int64,
    userID: Int64,
    sequence: Int32?,
    name: String
  ) -> InlineProtocol.GetSpaceResult {
    var result = InlineProtocol.GetSpaceResult()
    result.space = .with {
      $0.id = spaceID
      $0.name = name
      $0.date = 1
      if let sequence { $0.seq = sequence }
    }
    result.membership = .with {
      $0.id = 100
      $0.userID = userID
      $0.spaceID = spaceID
      $0.date = 1
      $0.role = .member
    }
    return result
  }
}
