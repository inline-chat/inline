import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetSpaceMembersTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetSpaceMembers")

  // Properties
  public var method: InlineProtocol.Method = .getSpaceMembers
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    let spaceId: Int64
  }

  public init(spaceId: Int64) {
    context = Context(spaceId: spaceId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getSpaceMembers(.with { $0.spaceID = context.spaceId })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getSpaceMembers(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getSpaceMembers result: \(response)")

    do {
      let mutationToken = try Auth.shared.handle.beginAccountMutation()
      let importResult = try await AppDatabase.shared.dbWriter.write { db in
        try Auth.shared.handle.validateAccountMutation(mutationToken)
        return try Self.apply(response, spaceID: context.spaceId, in: db)
      }
      if let catchUpTarget = importResult.catchUpTarget {
        _ = try await Api.realtime.installSnapshotOutcome(
          seededStates: [:],
          catchUpTargets: [.space(id: context.spaceId): catchUpTarget],
          expectedAccount: mutationToken
        )
      }
      log.trace("getSpaceMembers saved")
    } catch {
      log.error("Failed to save space members data", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  struct SnapshotImport: Sendable, Equatable {
    var applied: Bool
    var catchUpTarget: Int64?
  }

  @discardableResult
  static func apply(
    _ response: InlineProtocol.GetSpaceMembersResult,
    spaceID: Int64,
    currentUserID: Int64? = Auth.shared.getCurrentUserId(),
    in db: Database
  ) throws -> SnapshotImport {
    guard response.members.allSatisfy({
      $0.id > 0 && $0.userID > 0 && $0.spaceID == spaceID
    }) else {
      throw TransactionExecutionError.invalid
    }

    let bucketKey = BucketKey.space(id: spaceID)
    let cursorSequence = try DbBucketState
      .filter(
        DbBucketState.Columns.bucketType == bucketKey.getBucket()
          && DbBucketState.Columns.entityId == bucketKey.getEntityId()
      )
      .fetchOne(db)?
      .seq ?? 0
    let existingRosterState = try SpaceMemberRosterState.fetchOne(db, key: spaceID)
    let previousCurrentMembership = try currentUserID.flatMap { userID in
      try Member
        .filter(Member.Columns.spaceId == spaceID && Member.Columns.userId == userID)
        .fetchOne(db)
    }
    let snapshotCurrentMembership = currentUserID.flatMap { userID in
      response.members.first(where: { $0.userID == userID }).map(Member.init(from:))
    }
    let snapshotRevokesPublicAccess = previousCurrentMembership?.canAccessPublicChats != false
      && snapshotCurrentMembership?.canAccessPublicChats == false

    if response.hasSeq {
      let snapshotSequence = Int64(response.seq)
      guard snapshotSequence >= 0 else { throw TransactionExecutionError.invalid }
      let knownSequence = max(cursorSequence, existingRosterState?.observedSeq ?? 0)
      guard snapshotSequence >= knownSequence else {
        return SnapshotImport(
          applied: false,
          catchUpTarget: knownSequence > cursorSequence ? knownSequence : nil
        )
      }

      try saveUsers(response.users, in: db)
      try Member
        .filter(Member.Columns.spaceId == spaceID)
        .deleteAll(db)
      try SpaceMemberEventState
        .filter(SpaceMemberEventState.Columns.spaceId == spaceID)
        .deleteAll(db)
      for member in response.members {
        try Member(from: member).insert(db)
      }
      if snapshotRevokesPublicAccess {
        try Member.removePublicThreadsForSpace(spaceID: spaceID, in: db)
      }
      try SpaceMemberRosterState.recordSnapshot(
        spaceID: spaceID,
        through: snapshotSequence,
        in: db
      )
      try Space
        .filter(Space.Columns.id == spaceID)
        .updateAll(db, [
          Space.Columns.memberRosterComplete.set(to: true),
        ])
      return SnapshotImport(
        applied: true,
        catchUpTarget: snapshotSequence > cursorSequence ? snapshotSequence : nil
      )
    }

    if let existingRosterState {
      return SnapshotImport(
        applied: false,
        catchUpTarget: existingRosterState.observedSeq > cursorSequence
          ? existingRosterState.observedSeq
          : nil
      )
    }

    // Compatibility with an older server: once durable replay exists, an
    // unsequenced response may only fill missing or newer generations. It
    // cannot authoritatively delete or overwrite the journal-owned roster.
    if cursorSequence > 0 {
      try saveUsers(response.users, in: db)
      for member in response.members {
        try Member(from: member).reconcileProjection(
          db,
          updateMatchingGeneration: false
        )
      }
      try Space
        .filter(Space.Columns.id == spaceID)
        .updateAll(db, [Space.Columns.memberRosterComplete.set(to: false)])
      return SnapshotImport(applied: true, catchUpTarget: nil)
    }

    try saveUsers(response.users, in: db)
    try Member
      .filter(Member.Columns.spaceId == spaceID)
      .deleteAll(db)
    for member in response.members {
      try Member(from: member).insert(db)
    }
    if snapshotRevokesPublicAccess {
      try Member.removePublicThreadsForSpace(spaceID: spaceID, in: db)
    }
    try Space
      .filter(Space.Columns.id == spaceID)
      .updateAll(db, [Space.Columns.memberRosterComplete.set(to: true)])
    return SnapshotImport(applied: true, catchUpTarget: nil)
  }

  private static func saveUsers(_ users: [InlineProtocol.User], in db: Database) throws {
    for user in users {
      _ = try User.save(db, user: user)
    }
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetSpaceMembersTransaction {
  static func getSpaceMembers(spaceId: Int64) -> GetSpaceMembersTransaction {
    GetSpaceMembersTransaction(spaceId: spaceId)
  }
}
