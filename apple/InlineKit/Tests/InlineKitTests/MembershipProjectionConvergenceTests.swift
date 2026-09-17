import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Membership projection convergence")
struct MembershipProjectionConvergenceTests {
  private let spaceID: Int64 = 70
  private let userID: Int64 = 42

  @Test("a re-add generation replaces the old natural-key row and commits its page")
  func readdConvergesAndAdvancesCursor() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(id: 100, role: .member).save(db)
    }

    let result = await engine.applyBatch(
      updates: [makeAddUpdate(sequence: 1, memberID: 200, role: .admin)],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .space(id: spaceID),
        state: .init(date: 1, seq: 1),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { db in
      let members = try InlineKit.Member
        .filter(InlineKit.Member.Columns.spaceId == spaceID)
        .filter(InlineKit.Member.Columns.userId == userID)
        .fetchAll(db)
      #expect(members.count == 1)
      #expect(members.first?.id == 200)
      #expect(members.first?.role == .admin)
      #expect(try bucketCursor(db)?.seq == 1)
      let rosterState = try SpaceMemberRosterState.fetchOne(db, key: spaceID)
      #expect(rosterState?.observedSeq == 1)
      #expect(rosterState?.snapshotSeq == nil)
    }
  }

  @Test("sequenced live membership writes advance the roster frontier before cursor catch-up")
  func liveWriteAdvancesRosterFrontier() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(id: 100, role: .member).save(db)
    }

    let result = await engine.applyBatch(
      updates: [makeAddUpdate(sequence: 6, memberID: 200, role: .admin)],
      source: .realtime
    )
    #expect(result.succeeded)

    try await queue.write { db in
      #expect(try bucketCursor(db) == nil)
      let rosterState = try SpaceMemberRosterState.fetchOne(db, key: spaceID)
      #expect(rosterState?.observedSeq == 6)
      #expect(rosterState?.snapshotSeq == nil)
      let delayed = try GetSpaceMembersTransaction.apply(
        makeRoster(sequence: 5, memberID: 100, role: .member),
        spaceID: spaceID,
        in: db
      )
      #expect(delayed == .init(applied: false, catchUpTarget: 6))
      #expect(try InlineKit.Member.fetchOne(db, id: 200)?.role == .admin)
    }
  }

  @Test("a live update for one member does not suppress earlier replay for another")
  func observedSequenceDoesNotClaimCompleteCoverage() async throws {
    let otherUserID: Int64 = 43
    let (queue, engine) = try makeEngine()
    try await queue.write { db in
      try seedSpaceAndUser(db)
      try InlineKit.User(id: otherUserID, email: nil, firstName: "Other").save(db)
      try makeMember(id: 100, role: .member).save(db)
    }

    let liveResult = await engine.applyBatch(
      updates: [makeAddUpdate(sequence: 6, memberID: 200, role: .admin)],
      source: .realtime
    )
    #expect(liveResult.succeeded)

    var earlierOtherMember = InlineProtocol.UpdateSpaceMemberAdd()
    earlierOtherMember.user = makeProtocolUser(id: otherUserID)
    earlierOtherMember.member = makeProtocolMember(
      id: 300,
      userID: otherUserID,
      role: .member
    )
    let replayResult = await engine.applyBatch(
      updates: [makeUpdate(sequence: 5, payload: .spaceMemberAdd(earlierOtherMember))],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .space(id: spaceID),
        state: .init(date: 5, seq: 5),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )
    #expect(replayResult.succeeded)

    try await queue.read { db in
      #expect(try InlineKit.Member.fetchOne(db, id: 200)?.role == .admin)
      #expect(try InlineKit.Member.fetchOne(db, id: 300)?.userId == otherUserID)
      let rosterState = try SpaceMemberRosterState.fetchOne(db, key: spaceID)
      #expect(rosterState?.observedSeq == 6)
      #expect(rosterState?.snapshotSeq == nil)
      #expect(try memberEventSequence(db, userID: userID) == 6)
      #expect(try memberEventSequence(db, userID: otherUserID) == 5)
      #expect(try bucketCursor(db)?.seq == 5)
    }
  }

  @Test("an earlier event cannot regress the same membership after a live update")
  func memberSequenceFenceRejectsEarlierReplay() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(id: 100, role: .member).save(db)
    }

    var livePayload = InlineProtocol.UpdateSpaceMemberUpdate()
    livePayload.member = makeProtocolMember(id: 100, role: .admin)
    let liveResult = await engine.applyBatch(
      updates: [makeUpdate(sequence: 6, payload: .spaceMemberUpdate(livePayload))],
      source: .realtime
    )
    #expect(liveResult.succeeded)

    var earlierPayload = livePayload
    earlierPayload.member = makeProtocolMember(id: 100, role: .member)
    let replayResult = await engine.applyBatch(
      updates: [makeUpdate(sequence: 5, payload: .spaceMemberUpdate(earlierPayload))],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .space(id: spaceID),
        state: .init(date: 5, seq: 5),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )
    #expect(replayResult.succeeded)

    try await queue.read { db in
      let stored = try InlineKit.Member.fetchOne(db, id: 100)
      let memberSequence = try memberEventSequence(db, userID: userID)
      let cursor = try bucketCursor(db)
      #expect(stored?.role == .admin)
      #expect(memberSequence == 6)
      #expect(cursor?.seq == 5)
    }
  }

  @Test("delayed add and update payloads cannot regress a newer generation")
  func delayedWritesPreserveNewerGeneration() throws {
    let (queue, _) = try makeEngine()
    try queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(
        id: 200,
        role: .admin,
        canAccessPublicChats: false
      ).save(db)

      var staleAdd = InlineProtocol.UpdateSpaceMemberAdd()
      staleAdd.user = makeProtocolUser()
      staleAdd.member = makeProtocolMember(id: 100, role: .member)
      try staleAdd.apply(db)

      var staleUpdate = InlineProtocol.UpdateSpaceMemberUpdate()
      staleUpdate.member = makeProtocolMember(
        id: 100,
        role: .member,
        canAccessPublicChats: true
      )
      try staleUpdate.apply(db)

      let stored = try #require(try InlineKit.Member.fetchOne(db, id: 200))
      #expect(stored.role == .admin)
      #expect(stored.canAccessPublicChats == false)
      #expect(try InlineKit.Member.fetchOne(db, id: 100) == nil)
    }
  }

  @Test("a delayed removal only deletes its own membership generation")
  func deleteIsGenerationAware() throws {
    let (queue, _) = try makeEngine()
    try queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(id: 200, role: .member).save(db)

      var legacyStaleDelete = InlineProtocol.UpdateSpaceMemberDelete()
      legacyStaleDelete.spaceID = spaceID
      legacyStaleDelete.userID = userID
      try legacyStaleDelete.apply(
        db,
        updateDate: .init(timeIntervalSince1970: 150),
        currentUserID: userID
      )
      #expect(try InlineKit.Member.fetchOne(db, id: 200) != nil)
      #expect(try InlineKit.Space.fetchOne(db, id: spaceID) != nil)

      var staleDelete = InlineProtocol.UpdateSpaceMemberDelete()
      staleDelete.spaceID = spaceID
      staleDelete.userID = userID
      staleDelete.memberID = 100
      try staleDelete.apply(db, currentUserID: userID)
      #expect(try InlineKit.Member.fetchOne(db, id: 200) != nil)
      #expect(try InlineKit.Space.fetchOne(db, id: spaceID) != nil)

      var currentDelete = staleDelete
      currentDelete.memberID = 200
      try currentDelete.apply(db, currentUserID: nil)
      #expect(try InlineKit.Member.fetchOne(db, id: 200) == nil)
    }
  }

  @Test("a sequenced roster snapshot owns covered membership updates")
  func snapshotWatermarkPreventsReplayRegression() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(id: 100, role: .member).save(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .space(id: spaceID),
        state: .init(date: 5, seq: 5),
        in: db
      )

      var roster = makeRoster(sequence: 10, memberID: 200, role: .admin)
      roster.users[0].firstName = "Current"
      let imported = try GetSpaceMembersTransaction.apply(
        roster,
        spaceID: spaceID,
        in: db
      )
      #expect(imported == .init(applied: true, catchUpTarget: 10))
    }

    var coveredDelete = InlineProtocol.UpdateSpaceMemberDelete()
    coveredDelete.spaceID = spaceID
    coveredDelete.userID = userID
    coveredDelete.memberID = 200
    let result = await engine.applyBatch(
      updates: [
        makeAddUpdate(sequence: 6, memberID: 150, role: .member),
        makeUpdate(sequence: 7, payload: .spaceMemberDelete(coveredDelete)),
      ],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .space(id: spaceID),
        state: .init(date: 10, seq: 10),
        expectedStartState: .init(date: 5, seq: 5)
      )
    )

    #expect(result.succeeded)
    try await queue.read { db in
      let stored = try #require(try InlineKit.Member.fetchOne(db, id: 200))
      #expect(stored.role == .admin)
      #expect(try InlineKit.User.fetchOne(db, id: userID)?.firstName == "Current")
      #expect(try InlineKit.Member.fetchOne(db, id: 150) == nil)
      let space = try #require(try InlineKit.Space.fetchOne(db, id: spaceID))
      #expect(space.memberRosterComplete)
      let rosterState = try SpaceMemberRosterState.fetchOne(db, key: spaceID)
      #expect(rosterState?.observedSeq == 10)
      #expect(rosterState?.snapshotSeq == 10)
      #expect(try bucketCursor(db)?.seq == 10)
    }
  }

  @Test("an authoritative roster applies current-user access revocation side effects")
  func snapshotRevocationRemovesPublicThreads() throws {
    let (queue, _) = try makeEngine()
    try queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(id: 100, role: .member).save(db)
      try Chat(
        id: 900,
        date: .init(timeIntervalSince1970: 1),
        type: .thread,
        title: "Public",
        spaceId: spaceID,
        isPublic: true
      ).save(db)

      var roster = makeRoster(sequence: 10, memberID: 100, role: .member)
      roster.members[0].canAccessPublicChats = false
      let imported = try GetSpaceMembersTransaction.apply(
        roster,
        spaceID: spaceID,
        currentUserID: userID,
        in: db
      )

      #expect(imported == .init(applied: true, catchUpTarget: 10))
      #expect(try InlineKit.Member.fetchOne(db, id: 100)?.canAccessPublicChats == false)
      #expect(try Chat.fetchOne(db, id: 900) == nil)
    }
  }

  @Test("stale and unsequenced snapshots cannot overwrite journal-owned membership")
  func staleSnapshotsAreNonDestructive() throws {
    let (queue, _) = try makeEngine()
    try queue.write { db in
      try seedSpaceAndUser(db)
      try makeMember(
        id: 200,
        role: .admin,
        canAccessPublicChats: false
      ).save(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .space(id: spaceID),
        state: .init(date: 10, seq: 10),
        in: db
      )

      var staleRoster = makeRoster(sequence: 8, memberID: 100, role: .member)
      staleRoster.users[0].firstName = "Stale"
      let stale = try GetSpaceMembersTransaction.apply(
        staleRoster,
        spaceID: spaceID,
        in: db
      )
      #expect(stale == .init(applied: false, catchUpTarget: nil))
      #expect(try InlineKit.User.fetchOne(db, id: userID)?.firstName == "Member")

      var unsequenced = makeRoster(sequence: nil, memberID: 200, role: .member)
      unsequenced.members[0].canAccessPublicChats = true
      let compatibility = try GetSpaceMembersTransaction.apply(
        unsequenced,
        spaceID: spaceID,
        in: db
      )
      #expect(compatibility == .init(applied: true, catchUpTarget: nil))

      let stored = try #require(try InlineKit.Member.fetchOne(db, id: 200))
      #expect(stored.role == .admin)
      #expect(stored.canAccessPublicChats == false)
      #expect(try InlineKit.User.fetchOne(db, id: userID)?.firstName == "Member")
      #expect(try InlineKit.Space.fetchOne(db, id: spaceID)?.memberRosterComplete == false)
    }
  }

  @Test("the roster frontier rejects out-of-order snapshots while replay is still behind")
  func rosterFrontierIsMonotonicAheadOfCursor() throws {
    let (queue, _) = try makeEngine()
    try queue.write { db in
      try seedSpaceAndUser(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .space(id: spaceID),
        state: .init(date: 5, seq: 5),
        in: db
      )

      let newest = try GetSpaceMembersTransaction.apply(
        makeRoster(sequence: 10, memberID: 200, role: .admin),
        spaceID: spaceID,
        in: db
      )
      #expect(newest == .init(applied: true, catchUpTarget: 10))

      let delayed = try GetSpaceMembersTransaction.apply(
        makeRoster(sequence: 8, memberID: 200, role: .member),
        spaceID: spaceID,
        in: db
      )
      #expect(delayed == .init(applied: false, catchUpTarget: 10))

      let stored = try #require(try InlineKit.Member.fetchOne(db, id: 200))
      #expect(stored.role == .admin)
      let space = try #require(try InlineKit.Space.fetchOne(db, id: spaceID))
      let rosterState = try SpaceMemberRosterState.fetchOne(db, key: spaceID)
      #expect(rosterState?.observedSeq == 10)
      #expect(rosterState?.snapshotSeq == 10)
      #expect(space.memberRosterComplete)
    }
  }

  @Test("an unsequenced compatibility response cannot replace a sequenced roster at cursor zero")
  func unsequencedSnapshotPreservesKnownRosterFrontier() throws {
    let (queue, _) = try makeEngine()
    try queue.write { db in
      try seedSpaceAndUser(db)

      let newest = try GetSpaceMembersTransaction.apply(
        makeRoster(sequence: 10, memberID: 200, role: .admin),
        spaceID: spaceID,
        in: db
      )
      #expect(newest == .init(applied: true, catchUpTarget: 10))

      let delayed = try GetSpaceMembersTransaction.apply(
        makeRoster(sequence: nil, memberID: 200, role: .member),
        spaceID: spaceID,
        in: db
      )
      #expect(delayed == .init(applied: false, catchUpTarget: 10))

      let stored = try #require(try InlineKit.Member.fetchOne(db, id: 200))
      #expect(stored.role == .admin)
      let space = try #require(try InlineKit.Space.fetchOne(db, id: spaceID))
      let rosterState = try SpaceMemberRosterState.fetchOne(db, key: spaceID)
      #expect(rosterState?.observedSeq == 10)
      #expect(rosterState?.snapshotSeq == 10)
      #expect(space.memberRosterComplete)
    }
  }

  private func makeEngine() throws -> (DatabaseQueue, UpdatesEngine) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    return try (queue, UpdatesEngine(database: AppDatabase(queue)))
  }

  private func seedSpaceAndUser(_ db: Database) throws {
    try InlineKit.Space(id: spaceID, name: "Space", date: .init(timeIntervalSince1970: 1)).save(db)
    try InlineKit.User(id: userID, email: nil, firstName: "Member").save(db)
  }

  private func makeMember(
    id: Int64,
    role: MemberRole,
    canAccessPublicChats: Bool = true
  ) -> InlineKit.Member {
    InlineKit.Member(
      id: id,
      date: .init(timeIntervalSince1970: Double(id)),
      userId: userID,
      spaceId: spaceID,
      role: role,
      canAccessPublicChats: canAccessPublicChats
    )
  }

  private func makeProtocolUser(id: Int64? = nil) -> InlineProtocol.User {
    .with {
      $0.id = id ?? userID
      $0.firstName = "Member"
    }
  }

  private func makeProtocolMember(
    id: Int64,
    userID: Int64? = nil,
    role: InlineProtocol.Member.Role,
    canAccessPublicChats: Bool = true
  ) -> InlineProtocol.Member {
    .with {
      $0.id = id
      $0.date = id
      $0.userID = userID ?? self.userID
      $0.spaceID = spaceID
      $0.role = role
      $0.canAccessPublicChats = canAccessPublicChats
    }
  }

  private func makeRoster(
    sequence: Int32?,
    memberID: Int64,
    role: InlineProtocol.Member.Role
  ) -> InlineProtocol.GetSpaceMembersResult {
    .with {
      $0.users = [makeProtocolUser()]
      $0.members = [makeProtocolMember(id: memberID, role: role)]
      if let sequence {
        $0.seq = sequence
      }
    }
  }

  private func makeAddUpdate(
    sequence: Int32,
    memberID: Int64,
    role: InlineProtocol.Member.Role
  ) -> InlineProtocol.Update {
    var payload = InlineProtocol.UpdateSpaceMemberAdd()
    payload.user = makeProtocolUser()
    payload.member = makeProtocolMember(id: memberID, role: role)
    return makeUpdate(sequence: sequence, payload: .spaceMemberAdd(payload))
  }

  private func makeUpdate(
    sequence: Int32,
    payload: InlineProtocol.Update.OneOf_Update
  ) -> InlineProtocol.Update {
    .with {
      $0.seq = sequence
      $0.date = Int64(sequence)
      $0.update = payload
    }
  }

  private func bucketCursor(_ db: Database) throws -> DbBucketState? {
    try DbBucketState
      .filter(DbBucketState.Columns.bucketType == BucketKey.space(id: spaceID).getBucket())
      .filter(DbBucketState.Columns.entityId == spaceID)
      .fetchOne(db)
  }

  private func memberEventSequence(_ db: Database, userID: Int64) throws -> Int64? {
    try SpaceMemberEventState
      .filter(
        SpaceMemberEventState.Columns.spaceId == spaceID
          && SpaceMemberEventState.Columns.userId == userID
      )
      .fetchOne(db)?
      .seq
  }
}
