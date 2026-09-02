import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

/// A request-time User cursor is the authority for a join response's
/// membership projection. Child sequence alone cannot fence a later removal,
/// because removal is deliberately carried by the User bucket.
public struct SpaceJoinSnapshotAdmission: Sendable, Codable {
  let userID: Int64
  let userState: GetChatsTransaction.ExpectedUserBucketState
  var mutationToken: AuthAccountMutationToken? = nil

  enum CodingKeys: String, CodingKey {
    case userID, userState
  }

  static func capture() async throws -> SpaceJoinSnapshotAdmission {
    let token = try Auth.shared.handle.beginAccountMutation()
    return try await AppDatabase.shared.reader.read { db in
      try Auth.shared.handle.validateAccountMutation(token)
      return SpaceJoinSnapshotAdmission(
        userID: token.userID, userState: try currentUserState(db), mutationToken: token
      )
    }
  }

  private static func currentUserState(_ db: Database) throws -> GetChatsTransaction.ExpectedUserBucketState {
    let cursor = try DbBucketState
      .filter(DbBucketState.Columns.bucketType == BucketKey.user.getBucket())
      .filter(DbBucketState.Columns.entityId == BucketKey.user.getEntityId())
      .fetchOne(db)
    return GetChatsTransaction.ExpectedUserBucketState(BucketState(date: cursor?.date ?? 0, seq: cursor?.seq ?? 0))
  }

  @discardableResult
  static func apply(
    space: InlineProtocol.Space,
    member: InlineProtocol.Member,
    admission: SpaceJoinSnapshotAdmission?,
    currentUserID: Int64,
    in db: Database
  ) throws -> Bool {
    guard space.id > 0, member.spaceID == space.id, member.userID == currentUserID else {
      throw TransactionExecutionError.invalid
    }
    // Older persisted transactions have no preflight snapshot. They remain
    // decodable, but durable User replay owns their projection safely.
    guard let admission, admission.userID == currentUserID,
          admission.userState == (try currentUserState(db)) else { return false }
    let key = BucketKey.space(id: space.id)
    let cursor = try DbBucketState
      .filter(DbBucketState.Columns.bucketType == key.getBucket())
      .filter(DbBucketState.Columns.entityId == key.getEntityId())
      .fetchOne(db)
    let existingSpace = try Space.fetchOne(db, id: space.id)
    let mayReplaceSpace = cursor.map { space.hasSeq && Int64(space.seq) >= $0.seq } ?? true
    if mayReplaceSpace {
      var model = Space(from: space)
      model.memberRosterComplete = cursor.map { space.hasSeq && Int64(space.seq) == $0.seq } == true
        && existingSpace?.memberRosterComplete == true
      try model.save(db)
    } else {
      // Role changes belong to the Space bucket too. Keeping newer Space
      // metadata while replacing its Member would still regress that bucket.
      return false
    }
    try Member(from: member).save(db)
    return true
  }
}

public struct JoinSpaceByInviteTokenTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .joinSpaceByInviteToken
  public var context: Context
  // Invite tokens are bearer credentials. Keep retries in memory so the raw
  // token is never serialized into the durable transaction queue.
  public var type: TransactionKindType = .mutation(.init(transient: true))

  public struct Context: Sendable, Codable {
    public let token: String
    public let snapshotAdmission: SpaceJoinSnapshotAdmission?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/JoinSpaceByInviteToken")

  public init(token: String, snapshotAdmission: SpaceJoinSnapshotAdmission? = nil) {
    context = Context(token: token, snapshotAdmission: snapshotAdmission)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .joinSpaceByInviteToken(.with { $0.token = context.token })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .joinSpaceByInviteToken(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      let token = try context.snapshotAdmission?.mutationToken ?? Auth.shared.handle.beginAccountMutation()
      try await AppDatabase.shared.dbWriter.write { db in
        try Auth.shared.handle.validateAccountMutation(token)
        try SpaceJoinSnapshotAdmission.apply(
          space: response.space, member: response.member,
          admission: context.snapshotAdmission, currentUserID: token.userID, in: db
        )
      }
    } catch {
      log.error("Failed to save joined space", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public struct GetSpaceInviteLinkTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .getSpaceInviteLink
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public let spaceId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(spaceId: Int64) {
    context = Context(spaceId: spaceId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getSpaceInviteLink(.with { $0.spaceID = context.spaceId })
  }

  public func apply(_: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

public struct SetSpaceInviteLinkEnabledTransaction: Transaction2 {
  public var method: InlineProtocol.Method = .setSpaceInviteLinkEnabled
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public let spaceId: Int64
    public let enabled: Bool
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(spaceId: Int64, enabled: Bool) {
    context = Context(spaceId: spaceId, enabled: enabled)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .setSpaceInviteLinkEnabled(.with {
      $0.spaceID = context.spaceId
      $0.enabled = context.enabled
    })
  }

  public func apply(_: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

public extension Transaction2 where Self == JoinSpaceByInviteTokenTransaction {
  static func joinSpaceByInviteToken(token: String) async throws -> JoinSpaceByInviteTokenTransaction {
    JoinSpaceByInviteTokenTransaction(token: token, snapshotAdmission: try await .capture())
  }
}

public extension Transaction2 where Self == GetSpaceInviteLinkTransaction {
  static func getSpaceInviteLink(spaceId: Int64) -> GetSpaceInviteLinkTransaction {
    GetSpaceInviteLinkTransaction(spaceId: spaceId)
  }
}

public extension Transaction2 where Self == SetSpaceInviteLinkEnabledTransaction {
  static func setSpaceInviteLinkEnabled(spaceId: Int64, enabled: Bool) -> SetSpaceInviteLinkEnabledTransaction {
    SetSpaceInviteLinkEnabledTransaction(spaceId: spaceId, enabled: enabled)
  }
}
