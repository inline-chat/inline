import Foundation
import GRDB
import InlineProtocol
import Logger

public struct UserGroup: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
  public var id: Int64
  public var spaceId: Int64
  public var name: String
  public var description: String?
  public var memberCount: Int
  public var currentUserIsMember: Bool
  public var date: Date

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let spaceId = Column(CodingKeys.spaceId)
    public static let name = Column(CodingKeys.name)
    public static let description = Column(CodingKeys.description)
    public static let memberCount = Column(CodingKeys.memberCount)
    public static let currentUserIsMember = Column(CodingKeys.currentUserIsMember)
    public static let date = Column(CodingKeys.date)
  }

  public static let members = hasMany(UserGroupMember.self)
  public var members: QueryInterfaceRequest<UserGroupMember> {
    request(for: UserGroup.members)
  }

  public init(
    id: Int64,
    spaceId: Int64,
    name: String,
    description: String?,
    memberCount: Int,
    currentUserIsMember: Bool,
    date: Date
  ) {
    self.id = id
    self.spaceId = spaceId
    self.name = name
    self.description = description
    self.memberCount = memberCount
    self.currentUserIsMember = currentUserIsMember
    self.date = date
  }
}

public struct UserGroupMember: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
  public var groupId: Int64
  public var userId: Int64

  public enum Columns {
    public static let groupId = Column(CodingKeys.groupId)
    public static let userId = Column(CodingKeys.userId)
  }

  public static let group = belongsTo(UserGroup.self)
  public var group: QueryInterfaceRequest<UserGroup> {
    request(for: UserGroupMember.group)
  }

  public static let user = belongsTo(User.self)
  public var user: QueryInterfaceRequest<User> {
    request(for: UserGroupMember.user)
  }

  public init(groupId: Int64, userId: Int64) {
    self.groupId = groupId
    self.userId = userId
  }
}

public struct ChatParticipantGroup: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
  public var id: Int64?
  public var chatId: Int64
  public var groupId: Int64
  public var date: Date

  public enum Columns {
    public static let id = Column(CodingKeys.id)
    public static let chatId = Column(CodingKeys.chatId)
    public static let groupId = Column(CodingKeys.groupId)
    public static let date = Column(CodingKeys.date)
  }

  public static let group = belongsTo(UserGroup.self)
  public var group: QueryInterfaceRequest<UserGroup> {
    request(for: ChatParticipantGroup.group)
  }

  public init(id: Int64? = nil, chatId: Int64, groupId: Int64, date: Date) {
    self.id = id
    self.chatId = chatId
    self.groupId = groupId
    self.date = date
  }
}

public extension UserGroup {
  init(from group: InlineProtocol.UserGroup) {
    self.init(
      id: group.id,
      spaceId: group.spaceID,
      name: group.name,
      description: group.hasDescription_p ? group.description_p : nil,
      memberCount: Int(group.memberCount),
      currentUserIsMember: group.currentUserIsMember,
      date: Self.date(from: group.date)
    )
  }

  static func save(_ db: Database, from group: InlineProtocol.UserGroup) throws {
    var value = UserGroup(from: group)
    value.memberCount = group.userIds.isEmpty ? value.memberCount : group.userIds.count
    try value.save(db)

    try UserGroupMember
      .filter(UserGroupMember.Columns.groupId == group.id)
      .deleteAll(db)

    for userId in group.userIds {
      try UserGroupMember(groupId: group.id, userId: userId).insert(db)
    }
  }

  static func delete(_ db: Database, id: Int64) throws {
    try UserGroupMember
      .filter(UserGroupMember.Columns.groupId == id)
      .deleteAll(db)
    try ChatParticipantGroup
      .filter(ChatParticipantGroup.Columns.groupId == id)
      .deleteAll(db)
    try UserGroup
      .filter(UserGroup.Columns.id == id)
      .deleteAll(db)
  }

  static func date(from timestamp: Int64) -> Date {
    timestamp > 1_000_000_000_000
      ? Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
      : Date(timeIntervalSince1970: TimeInterval(timestamp))
  }
}

public extension ChatParticipantGroup {
  init(from group: InlineProtocol.ChatParticipantGroup, chatId: Int64) {
    self.init(
      chatId: chatId,
      groupId: group.groupID,
      date: UserGroup.date(from: group.date)
    )
  }

  static func save(_ db: Database, from group: InlineProtocol.ChatParticipantGroup, chatId: Int64) throws {
    let existing = try ChatParticipantGroup
      .filter(Columns.chatId == chatId)
      .filter(Columns.groupId == group.groupID)
      .fetchOne(db)

    var value = ChatParticipantGroup(from: group, chatId: chatId)
    value.id = existing?.id
    try value.save(db, onConflict: .replace)
  }
}
