import Foundation
import GRDB

public struct ApiUser: Codable, Hashable, Sendable {
  public var id: Int64
  public var email: String?
  public var firstName: String?
  public var lastName: String?
  public var online: Bool?
  public var lastOnline: Int?
  public var date: Int
  public var username: String?

  public static let preview = Self(
    id: 1,
    email: "mo@inline.chat",
    firstName: "Mo",
    lastName: nil,
    date: 162_579_240,
    username: "mo"
  )

  public var anyName: String {
    firstName ?? username ?? email?.components(separatedBy: "@").first ?? "User \(id)"
  }
}

public struct User: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable, Equatable {
  public var id: Int64
  public var email: String?
  public var firstName: String?
  public var lastName: String?
  public var date: Date?
  public var username: String?
  public var online: Bool?
  public var lastOnline: Date?

  public static let members = hasMany(Member.self)
  public static let dialog = hasOne(Dialog.self)
  public static let spaces = hasMany(Space.self, through: members, using: Member.space)

  public var members: QueryInterfaceRequest<Member> {
    request(for: User.members)
  }

  public var spaces: QueryInterfaceRequest<Space> {
    request(for: User.spaces)
  }

  public var dialog: QueryInterfaceRequest<Dialog> {
    request(for: User.dialog)
  }

  public static let chat = hasOne(Chat.self)
  public var chat: QueryInterfaceRequest<Chat> {
    request(for: User.chat)
  }

  public static let messages = hasMany(Message.self)
  public var messages: QueryInterfaceRequest<Message> {
    request(for: User.messages)
  }

  public static let deletedInstance = Self(
    id: -1,
    email: nil,
    firstName: "Deleted",
    lastName: nil,
    username: nil
  )

  public static let preview = Self(
    id: -1,
    email: "john@acme.com",
    firstName: "John",
    lastName: "Doe",
    username: "jdoe"
  )

  public init(
    id: Int64 = Int64.random(in: 1 ... 5_000), email: String?, firstName: String?,
    lastName: String? = nil, username: String? = nil
  ) {
    self.id = id
    self.email = email
    self.firstName = firstName
    self.lastName = lastName
    date = Date.now
    self.username = username
  }

  // MARK: - Computed

  private static let nameFormatter = PersonNameComponentsFormatter()
  public var fullName: String {
    let nameComponents = PersonNameComponents(
      givenName: firstName,
      familyName: lastName
    )

    return Self.nameFormatter.string(from: nameComponents)
  }
}

public extension User {
  init(from apiUser: ApiUser) {
    id = apiUser.id
    email = apiUser.email
    firstName = apiUser.firstName
    lastName = apiUser.lastName
    username = apiUser.username
    date = Self.fromTimestamp(from: apiUser.date)
    online = apiUser.online
    lastOnline = apiUser.lastOnline.map(Self.fromTimestamp(from:))
  }

  static func fromTimestamp(from: Int) -> Date {
    Date(timeIntervalSince1970: Double(from))
  }

  func isCurrentUser() -> Bool {
    id == Auth.shared.getCurrentUserId()
  }
}
