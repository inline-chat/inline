import Foundation
import GRDB
import InlineProtocol

public enum MemberRole: String, Codable, Hashable, Sendable {
  case owner, admin, member
}

public struct ApiMember: Codable, Hashable, Sendable {
  public var id: Int64
  public var date: Int
  public var userId: Int64
  public var spaceId: Int64
  public var role: String
  public var canAccessPublicChats: Bool?
}

public struct Member: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  @unchecked Sendable
{
  public var id: Int64
  public var date: Date
  public var userId: Int64
  public var spaceId: Int64
  public var role: MemberRole
  public var canAccessPublicChats: Bool

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let date = Column(CodingKeys.date)
    public static let userId = Column(CodingKeys.userId)
    public static let spaceId = Column(CodingKeys.spaceId)
    public static let role = Column(CodingKeys.role)
    public static let canAccessPublicChats = Column(CodingKeys.canAccessPublicChats)
  }

  // Member -> Space
  public static let space = belongsTo(Space.self)
  public var space: QueryInterfaceRequest<Space> {
    request(for: Member.space)
  }

  // Member -> User
  public static let user = belongsTo(User.self)
  public var user: QueryInterfaceRequest<User> {
    request(for: Member.user)
  }

  public static let chat = hasOne(
    Chat.self,
    through: Self.user,
    using: User.chat
  )

  public static let dialog = hasOne(
    Dialog.self,
    through: Self.user,
    using: User.dialog
  )

  public init(
    id: Int64 = Int64.random(in: 1 ... 5_000), date: Date, userId: Int64, spaceId: Int64,
    role: MemberRole = .owner, canAccessPublicChats: Bool = true
  ) {
    self.id = id
    self.date = date
    self.userId = userId
    self.spaceId = spaceId
    self.role = role
    self.canAccessPublicChats = canAccessPublicChats
  }
}

public extension Member {
  init(from: ApiMember) {
    id = from.id
    date = Self.fromTimestamp(from: from.date)
    userId = from.userId
    spaceId = from.spaceId
    role = MemberRole(rawValue: from.role) ?? .member
    canAccessPublicChats = from.canAccessPublicChats ?? true
  }

  static func fromTimestamp(from: Int) -> Date {
    Date(timeIntervalSince1970: Double(from) / 1_000)
  }
}

public extension Member {
  init(from: InlineProtocol.Member) {
    id = from.id
    date = Date(timeIntervalSince1970: Double(from.date))
    userId = from.userID
    spaceId = from.spaceID
    role = switch from.role {
      case .owner:
        .owner
      case .admin:
        .admin
      case .member:
        .member
      case .UNRECOGNIZED:
        .member
    }
    canAccessPublicChats = from.canAccessPublicChats
  }
}

struct MemberProjectionWrite {
  let previous: Member?
  let applied: Bool
}

struct SpaceMemberRosterState: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "space_member_roster_state"

  var spaceId: Int64
  /// Highest Space sequence represented by any membership reducer or roster
  /// snapshot. This rejects an older full snapshot without claiming that every
  /// earlier membership event has already been projected.
  var observedSeq: Int64
  /// Highest Space sequence covered by a complete roster snapshot. Only this
  /// watermark may suppress replay for other members in the same space.
  var snapshotSeq: Int64?

  enum Columns {
    static let spaceId = Column(CodingKeys.spaceId)
    static let observedSeq = Column(CodingKeys.observedSeq)
    static let snapshotSeq = Column(CodingKeys.snapshotSeq)
  }

  static func observe(spaceID: Int64, sequence: Int64?, in db: Database) throws {
    guard let sequence else { return }
    let existing = try fetchOne(db, key: spaceID)
    guard sequence > (existing?.observedSeq ?? -1) else { return }
    try SpaceMemberRosterState(
      spaceId: spaceID,
      observedSeq: sequence,
      snapshotSeq: existing?.snapshotSeq
    ).save(db)
  }

  static func recordSnapshot(spaceID: Int64, through sequence: Int64, in db: Database) throws {
    let existing = try fetchOne(db, key: spaceID)
    try SpaceMemberRosterState(
      spaceId: spaceID,
      observedSeq: max(existing?.observedSeq ?? sequence, sequence),
      snapshotSeq: max(existing?.snapshotSeq ?? sequence, sequence)
    ).save(db)
  }
}

struct SpaceMemberEventState: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "space_member_event_state"

  var spaceId: Int64
  var userId: Int64
  var seq: Int64

  enum Columns {
    static let spaceId = Column(CodingKeys.spaceId)
    static let userId = Column(CodingKeys.userId)
    static let seq = Column(CodingKeys.seq)
  }

  static func covers(
    spaceID: Int64,
    userID: Int64,
    sequence: Int64?,
    in db: Database
  ) throws -> Bool {
    guard let sequence else { return false }
    let existing = try filter(Columns.spaceId == spaceID && Columns.userId == userID)
      .fetchOne(db)
    return sequence <= (existing?.seq ?? -1)
  }

  static func observe(
    spaceID: Int64,
    userID: Int64,
    sequence: Int64?,
    in db: Database
  ) throws {
    guard let sequence else { return }
    let existing = try filter(Columns.spaceId == spaceID && Columns.userId == userID)
      .fetchOne(db)
    guard sequence > (existing?.seq ?? -1) else { return }
    try SpaceMemberEventState(spaceId: spaceID, userId: userID, seq: sequence).save(db)
  }
}

extension Member {
  /// Reconciles the server's immutable membership-generation ID with the
  /// natural local identity of one membership. A remove/re-add creates a new
  /// server row for the same `(spaceId, userId)`, so primary-key `save` alone
  /// can violate the natural-key constraint or let delayed work regress the
  /// current generation.
  @discardableResult
  func reconcileProjection(
    _ db: Database,
    updateMatchingGeneration: Bool = true
  ) throws -> MemberProjectionWrite {
    let existing = try Member
      .filter(Member.Columns.userId == userId)
      .filter(Member.Columns.spaceId == spaceId)
      .fetchOne(db)

    guard let existing else {
      try insert(db)
      return MemberProjectionWrite(previous: nil, applied: true)
    }

    // Member IDs are immutable PostgreSQL serial IDs. A larger ID for the
    // same natural identity is therefore a later membership generation.
    guard id >= existing.id else {
      return MemberProjectionWrite(previous: existing, applied: false)
    }

    if id == existing.id {
      guard updateMatchingGeneration else {
        return MemberProjectionWrite(previous: existing, applied: false)
      }
      try update(db)
      return MemberProjectionWrite(previous: existing, applied: true)
    }

    // Delete the superseded natural-key owner before inserting the new
    // generation. Callers run this inside their enclosing database
    // transaction, so an unexpected ID collision rolls the whole write back.
    try existing.delete(db)
    try insert(db)
    return MemberProjectionWrite(previous: existing, applied: true)
  }

  static func projectionCovers(
    spaceID: Int64,
    userID: Int64,
    updateSequence: Int64?,
    in db: Database
  ) throws -> Bool {
    guard let updateSequence else { return false }
    if let snapshotSequence = try SpaceMemberRosterState.fetchOne(db, key: spaceID)?.snapshotSeq,
       updateSequence <= snapshotSequence {
      return true
    }
    return try SpaceMemberEventState.covers(
      spaceID: spaceID,
      userID: userID,
      sequence: updateSequence,
      in: db
    )
  }

  static func removePublicThreadsForSpace(spaceID: Int64, in db: Database) throws {
    try SyncRemovalRevision.advance(db)
    let publicThreads = try Chat
      .filter(Chat.Columns.spaceId == spaceID)
      .filter(Chat.Columns.type == ChatType.thread.rawValue)
      .filter(Chat.Columns.isPublic == true)
      .fetchAll(db)

    let chatIDs = publicThreads.map(\.id)
    guard !chatIDs.isEmpty else { return }

    try Message.filter(chatIDs.contains(Column("chatId"))).deleteAll(db)
    try Dialog.filter(chatIDs.contains(Column("chatId"))).deleteAll(db)
    try Dialog.filter(chatIDs.contains(Column("peerThreadId"))).deleteAll(db)
    let chatBucketIDs = chatIDs.map { -$0 }
    try DbBucketState
      .filter(DbBucketState.Columns.bucketType == 1 && chatBucketIDs.contains(DbBucketState.Columns.entityId))
      .deleteAll(db)
    try Chat.filter(chatIDs.contains(Column("id"))).deleteAll(db)
  }
}

public extension Member {
  static func spaceChatItemRequest() -> QueryInterfaceRequest<SpaceChatItem> {
    including(
      optional:
      // user info
      Member.user
        .forKey("userInfo")
        .including(
          all: User.photos
            .forKey("profilePhoto")
        )
    )
    .including(
      optional: Member.chat
        .including(optional: Chat.lastMessage.including(
          optional: Message.from.forKey("from")
            .including(
              all: User.photos
                .forKey("profilePhoto")
            )
        )
          .including(all: Message.translations.forKey("translations"))
          .including(
            optional: Message.photo
              .forKey("photoInfo")
              .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
          )
          .including(optional: Message.document.forKey("document"))
      ))
    
    .including(optional: Member.dialog)
    .asRequest(of: SpaceChatItem.self)
  }

  // use for array fetches
  static func fullMemberQuery() -> QueryInterfaceRequest<FullMemberItem> {
    // user info
    including(
      optional: Member.user.forKey("userInfo")
        .including(
          all: User.photos
            .forKey("profilePhoto")
        )
    )
    .asRequest(of: FullMemberItem.self)
  }
}
