import Foundation
import GRDB
import Testing

@testable import InlineKit
@testable import InlineProtocol
import RealtimeV2

@Suite("Space Join Transactions")
struct SpaceJoinTransactionsTests {
  @Test("a delayed join response cannot recreate membership after a newer user update")
  func delayedJoinResponseLosesAdmission() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    let expected = SpaceJoinSnapshotAdmission(
      userID: 42,
      userState: .init(BucketState(date: 100, seq: 10))
    )
    let space = InlineProtocol.Space.with { $0.id = 7; $0.name = "Joined"; $0.seq = 5 }
    let member = InlineProtocol.Member.with { $0.spaceID = 7; $0.userID = 42 }
    try queue.write { (db: Database) throws in
      try User(id: 42, email: "join@example.com", firstName: "Join").insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: BucketState(date: 101, seq: 11), in: db)
      #expect(try !SpaceJoinSnapshotAdmission.apply(
        space: space, member: member, admission: expected, currentUserID: 42, in: db
      ))
      #expect(try Space.fetchOne(db, id: 7) == nil)
      #expect(try Member.fetchCount(db) == 0)
    }
  }

  @Test("matching request-time user state admits join without advancing a child cursor")
  func matchingJoinResponseAdmitsProjection() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    let expected = SpaceJoinSnapshotAdmission(
      userID: 42, userState: .init(BucketState(date: 100, seq: 10))
    )
    let space = InlineProtocol.Space.with { $0.id = 7; $0.name = "Joined"; $0.seq = 5 }
    let member = InlineProtocol.Member.with { $0.spaceID = 7; $0.userID = 42 }
    try queue.write { (db: Database) throws in
      try User(id: 42, email: "join@example.com", firstName: "Join").insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: BucketState(date: 100, seq: 10), in: db)
      #expect(try SpaceJoinSnapshotAdmission.apply(
        space: space, member: member, admission: expected, currentUserID: 42, in: db
      ))
      #expect(try Space.fetchOne(db, id: 7)?.name == "Joined")
      #expect(try Member.fetchCount(db) == 1)
      #expect(try DbBucketState.filter(DbBucketState.Columns.bucketType == BucketKey.space(id: 7).getBucket())
        .fetchCount(db) == 0)
    }
  }

  @Test("a delayed join cannot regress a newer Space-bucket member role")
  func delayedJoinPreservesNewerSpaceMember() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    let expected = SpaceJoinSnapshotAdmission(
      userID: 42, userState: .init(BucketState(date: 100, seq: 10))
    )
    let oldSpace = InlineProtocol.Space.with { $0.id = 7; $0.name = "Old"; $0.seq = 5 }
    let oldMember = InlineProtocol.Member.with { $0.id = 8; $0.spaceID = 7; $0.userID = 42; $0.role = .member }
    try queue.write { (db: Database) throws in
      try User(id: 42, email: "join@example.com", firstName: "Join").insert(db)
      try Space(from: oldSpace).save(db)
      try Member(id: 8, date: .init(timeIntervalSince1970: 100), userId: 42, spaceId: 7, role: .admin).save(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: BucketState(date: 100, seq: 10), in: db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: 7), state: BucketState(date: 101, seq: 6), in: db)
      #expect(try !SpaceJoinSnapshotAdmission.apply(
        space: oldSpace, member: oldMember, admission: expected, currentUserID: 42, in: db
      ))
      #expect(try Member.fetchOne(db, id: 8)?.role == .admin)
    }
  }

  @Test("encodes private join without opting into durable credential storage")
  func privateJoinInput() {
    let token = "iv1_\(String(repeating: "a", count: 43))"
    let transaction = JoinSpaceByInviteTokenTransaction(token: token)

    guard case let .joinSpaceByInviteToken(input) = transaction.input(from: transaction.context) else {
      Issue.record("Expected private join input")
      return
    }
    #expect(input.token == token)
    guard case let .mutation(config) = transaction.type else {
      Issue.record("Expected a mutation")
      return
    }
    #expect(config.transient)
  }

  @Test("encodes invite-link administration")
  func inviteLinkInputs() {
    let get = GetSpaceInviteLinkTransaction(spaceId: 42)
    guard case let .getSpaceInviteLink(getInput) = get.input(from: get.context) else {
      Issue.record("Expected get invite link input")
      return
    }
    #expect(getInput.spaceID == 42)

    let set = SetSpaceInviteLinkEnabledTransaction(spaceId: 42, enabled: true)
    guard case let .setSpaceInviteLinkEnabled(setInput) = set.input(from: set.context) else {
      Issue.record("Expected set invite link input")
      return
    }
    #expect(setInput.spaceID == 42)
    #expect(setInput.enabled)
  }

  @Test("registers invite-link administration transactions")
  func inviteLinkTransactionRegistry() throws {
    let get = GetSpaceInviteLinkTransaction(spaceId: 42)
    #expect(TransactionTypeRegistry.typeString(for: get) == "get_space_invite_link")
    let getData = try JSONEncoder().encode(get)
    #expect(
      TransactionTypeRegistry.typeString(
        for: try TransactionTypeRegistry.decodeTransaction(
          type: "get_space_invite_link",
          data: getData
        )
      ) == "get_space_invite_link"
    )

    let set = SetSpaceInviteLinkEnabledTransaction(spaceId: 42, enabled: true)
    #expect(TransactionTypeRegistry.typeString(for: set) == "set_space_invite_link_enabled")
  }

  @Test("encodes block and remove and keeps older queued removals compatible")
  func deleteMemberBlockJoinCompatibility() throws {
    let blocked = DeleteMemberTransaction(spaceId: 7, userId: 9, blockJoin: true)
    guard case let .deleteMember(blockedInput) = blocked.input(from: blocked.context) else {
      Issue.record("Expected delete member input")
      return
    }
    #expect(blockedInput.blockJoin)

    let olderJSON = Data(#"{"context":{"spaceId":7,"userId":9}}"#.utf8)
    let older = try JSONDecoder().decode(DeleteMemberTransaction.self, from: olderJSON)
    guard case let .deleteMember(olderInput) = older.input(from: older.context) else {
      Issue.record("Expected decoded delete member input")
      return
    }
    #expect(!olderInput.blockJoin)
  }
}
