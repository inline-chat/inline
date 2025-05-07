import Auth
import Foundation
import GRDB
import InlineProtocol

public struct ApiUser: Codable, Hashable, Sendable {
  public var id: Int64
  public var email: String?
  public var firstName: String?
  public var lastName: String?
  public var online: Bool?
  public var pendingSetup: Bool?
  public var phoneNumber: String?
  public var lastOnline: Int?
  public var date: Int
  public var username: String?
  public var photo: [ApiPhoto]?

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

public struct User: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord, Sendable,
  Equatable
{
  public var id: Int64
  public var email: String?
  public var firstName: String?
  public var lastName: String?
  public var date: Date?
  public var username: String?
  public var phoneNumber: String?
  public var pendingSetup: Bool?
  public var online: Bool?
  public var lastOnline: Date?

  public var profileFileId: String?

  // Add hasMany for all files (including historical profile photos)
  public static let photos = hasMany(
    File.self,
    using: ForeignKey(["profileForUserId"], to: ["id"])
  )
  public var photos: QueryInterfaceRequest<File> {
    request(for: User.photos)
  }

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

  public static let previewUserId: Int64 = 1
  public static let preview = Self(
    id: 1,
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

  public var displayName: String {
    firstName != nil ? fullName : (username ?? email ?? phoneNumber ?? "User")
  }
  
  public var shortDisplayName: String {
    firstName != nil ? firstName! : (username ?? email ?? phoneNumber ?? "User")
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
    pendingSetup = apiUser.pendingSetup ?? false
    phoneNumber = apiUser.phoneNumber ?? nil
  }

  static func fromTimestamp(from: Int) -> Date {
    Date(timeIntervalSince1970: Double(from))
  }

  @MainActor func isCurrentUser() -> Bool {
    id == Auth.shared.currentUserId
  }
}

// TODO: add a get color item for the user

public struct UserWithPhoto: Codable, Hashable {
  public var user: User
  public var photo: File?
}

public extension User {
  static func userInfoQuery() -> QueryInterfaceRequest<UserInfo> {
    User
      .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      .asRequest(of: UserInfo.self)
  }
}

public extension ApiUser {
  @discardableResult
  func saveFull(
    _ db: Database
  )
    throws -> User
  {
    let existing = try? User.fetchOne(db, id: id)
    var user = User(from: self)

    // TODO: support clearing photo
    let file: File? = if let photo = photo?.first {
      // save file
      try? File.save(db, apiPhoto: photo, forUserId: user.id)
    } else {
      nil
    }

    // remove old photos except new ones for existing users
    if let file,
       let existing,
       // main file changed
       existing.profileFileId != file.id
    {
      // clear all other files for this user
      try File
        .filter(Column("profileForUserId") == user.id)
        .filter(Column("id") != file.id)
        .deleteAll(db)
    }

    if let existing {
      // keep exitsing values
      user.profileFileId = file?.id ?? existing.profileFileId
      user.phoneNumber = user.phoneNumber ?? existing.phoneNumber
      user.email = user.email ?? existing.email
      user.pendingSetup = user.pendingSetup ?? existing.pendingSetup
      try user.save(db)
      // ... anything else?
    } else {
      // attach main photo
      user.profileFileId = file?.id
      // TODO: handle multiple files
      try user.save(db)
    }

    return user
  }
}

// Inline Protocol
public extension User {
  init(from user: InlineProtocol.User) {
    let min = user.hasMin && user.min == true

    id = user.id
    firstName = user.hasFirstName ? user.firstName : nil
    lastName = user.hasLastName ? user.lastName : nil
    username = user.hasUsername ? user.username : nil
    date = Date() // unused field
    // don't preserve pendingSetup

    if !min {
      email = user.hasEmail ? user.email : nil
      phoneNumber = user.hasPhoneNumber ? user.phoneNumber : nil

      if user.hasStatus {
        online = user.status.online == .online
        lastOnline = Date(timeIntervalSince1970: Double(user.status.lastOnline.date))
      }
    }
  }

  static func save(
    _ db: Database, user protocolUser: InlineProtocol.User
  )
    throws -> User
  {
    let existing = try? User.fetchOne(db, id: protocolUser.id)
    var user = User(from: protocolUser)

    if let existing {
      // keep existing values
      user.profileFileId = existing.profileFileId
      user.date = existing.date
      user.phoneNumber = user.phoneNumber ?? existing.phoneNumber
      user.email = user.email ?? existing.email
      // don't preserve pendingSetup
      try user.save(db)
    } else {
      // Backward compatible as the new API doesn't send date for users
      user.date = Date()
      try user.save(db)
    }

    return user
  }
}
