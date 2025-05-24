import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger

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
  public var timeZone: String?
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
  public var timeZone: String?
  public var profileFileId: String?
  public var profileCdnUrl: String?
  public var profileLocalPath: String?

  public enum Columns {
    static let id = Column(CodingKeys.id)
    static let email = Column(CodingKeys.email)
    static let firstName = Column(CodingKeys.firstName)
    static let lastName = Column(CodingKeys.lastName)
    static let date = Column(CodingKeys.date)
    static let username = Column(CodingKeys.username)
    static let phoneNumber = Column(CodingKeys.phoneNumber)
    static let pendingSetup = Column(CodingKeys.pendingSetup)
    static let online = Column(CodingKeys.online)
    static let lastOnline = Column(CodingKeys.lastOnline)
    static let timeZone = Column(CodingKeys.timeZone)
    static let profileFileId = Column(CodingKeys.profileFileId)
    static let profileCdnUrl = Column(CodingKeys.profileCdnUrl)
    static let profileLocalPath = Column(CodingKeys.profileLocalPath)
  }

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
    timeZone = apiUser.timeZone ?? nil
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

    var profileCdnUrl: String? = nil
    var profileLocalPath: String? = nil

    // TODO: support clearing photo
    var file: File? = nil

    if let photo = photo?.first {
      profileCdnUrl = photo.temporaryUrl
      // save file
      file = try? File.save(db, apiPhoto: photo, forUserId: user.id)
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
      user.timeZone = user.timeZone ?? existing.timeZone
      user.profileCdnUrl = profileCdnUrl ?? existing.profileCdnUrl
      user.profileLocalPath = existing.profileLocalPath

      try user.save(db)
      // ... anything else?
    } else {
      // NEW USER
      // attach main photo
      user.profileFileId = file?.id
      user.profileCdnUrl = profileCdnUrl

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
    timeZone = user.hasTimeZone ? user.timeZone : nil
    date = Date() // unused field
    // don't preserve pendingSetup

    if !min {
      email = user.hasEmail ? user.email : nil
      phoneNumber = user.hasPhoneNumber ? user.phoneNumber : nil

      if user.hasStatus {
        online = user.status.online == .online
        lastOnline = user.status.hasLastOnline ? Date(
          timeIntervalSince1970: Double(user.status.lastOnline.date)
        )
          : nil
      }
    }

    if user.hasProfilePhoto {
      profileCdnUrl = user.profilePhoto.hasCdnURL ? user.profilePhoto.cdnURL : nil
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
      user.timeZone = user.timeZone ?? existing.timeZone
      user.profileCdnUrl = user.profileCdnUrl ?? existing.profileCdnUrl
      user.profileLocalPath = existing.profileLocalPath

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

// MARK: - Photo helpers

public extension User {
  private static func getProfileCacheDirectory() -> URL {
    FileHelpers.getLocalCacheDirectory(for: .photos)
  }

  func getLocalURL() -> URL? {
    guard let profileLocalPath else {
      return nil
    }
    return
      User.getProfileCacheDirectory()
        .appending(path: profileLocalPath)
  }

  func getRemoteURL() -> URL? {
    guard let profileCdnUrl else {
      return nil
    }
    return URL(string: profileCdnUrl)
  }

  static func cacheImage(userId: Int64, image: PlatformImage) async throws {
    Log.shared.debug("Trying to cache image")

    // Save image locally when loaded
    let directory = User.getProfileCacheDirectory()
    let fileName = "User\(UUID().uuidString).jpg"
    if let (localPath, _) = try? image.save(
      to: directory, withName: fileName, format: .jpeg
    ) {
      _ = try? await AppDatabase.shared.dbWriter.write { db in
        try User.filter(id: userId).updateAll(db, [
          Column("profileLocalPath").set(to: localPath),
        ])
      }
    }
  }
}
