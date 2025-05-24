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
}

public struct Member: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  @unchecked Sendable
{
  public var id: Int64
  public var date: Date
  public var userId: Int64
  public var spaceId: Int64
  public var role: MemberRole

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let date = Column(CodingKeys.date)
    static let userId = Column(CodingKeys.userId)
    static let spaceId = Column(CodingKeys.spaceId)
    static let role = Column(CodingKeys.role)
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
    role: MemberRole = .owner
  ) {
    self.id = id
    self.date = date
    self.userId = userId
    self.spaceId = spaceId
    self.role = role
  }
}

public extension Member {
  init(from: ApiMember) {
    id = from.id
    date = Self.fromTimestamp(from: from.date)
    userId = from.userId
    spaceId = from.spaceId
    role = MemberRole(rawValue: from.role) ?? .member
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
        ))
    )
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
