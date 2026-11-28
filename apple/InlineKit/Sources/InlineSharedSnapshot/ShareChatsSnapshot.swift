import Foundation

/// Chats and users the share extension offers as destinations.
public struct ShareExtensionData: SharedSnapshotPayload, Equatable {
  public static let kind = "share-chats"
  public static let schemaVersion = 1

  public var chats: [SharedChat]
  public var users: [SharedUser]

  public init(chats: [SharedChat], users: [SharedUser]) {
    self.chats = chats
    self.users = users
  }
}

public struct SharedChat: Codable, Equatable, Sendable {
  public var id: Int64
  public var title: String
  public var peerUserId: Int64?
  public var peerThreadId: Int64?
  public var lastMessageDate: Date?
  public var pinned: Bool?
  public var spaceName: String?
  public var emoji: String?
  public var parentTitle: String?
  public var preview: String?
  public var searchText: String?
  public var unread: Bool?
  public var archived: Bool?
  public var isReplyThread: Bool?

  public init(
    id: Int64,
    title: String,
    peerUserId: Int64?,
    peerThreadId: Int64?,
    lastMessageDate: Date?,
    pinned: Bool?,
    spaceName: String?,
    emoji: String?,
    parentTitle: String? = nil,
    preview: String? = nil,
    searchText: String? = nil,
    unread: Bool? = nil,
    archived: Bool? = nil,
    isReplyThread: Bool? = nil
  ) {
    self.id = id
    self.title = title
    self.peerUserId = peerUserId
    self.peerThreadId = peerThreadId
    self.lastMessageDate = lastMessageDate
    self.pinned = pinned
    self.spaceName = spaceName
    self.emoji = emoji
    self.parentTitle = parentTitle
    self.preview = preview
    self.searchText = searchText
    self.unread = unread
    self.archived = archived
    self.isReplyThread = isReplyThread
  }
}

public struct SharedUser: Codable, Equatable, Sendable {
  public var id: Int64
  public var firstName: String
  public var lastName: String
  public var displayName: String?
  public var email: String?
  public var username: String?
  public var profileCdnUrl: String?
  public var profileFileId: String?
  public var profileLocalPath: String?
  public var profileFileUniqueId: String?
  /// Avatar exported by the app, relative to the app group container.
  public var profileSharedLocalPath: String?

  public init(
    id: Int64,
    firstName: String,
    lastName: String,
    displayName: String?,
    email: String? = nil,
    username: String? = nil,
    profileCdnUrl: String? = nil,
    profileFileId: String? = nil,
    profileLocalPath: String? = nil,
    profileFileUniqueId: String? = nil,
    profileSharedLocalPath: String? = nil
  ) {
    self.id = id
    self.firstName = firstName
    self.lastName = lastName
    self.displayName = displayName
    self.email = email
    self.username = username
    self.profileCdnUrl = profileCdnUrl
    self.profileFileId = profileFileId
    self.profileLocalPath = profileLocalPath
    self.profileFileUniqueId = profileFileUniqueId
    self.profileSharedLocalPath = profileSharedLocalPath
  }

  public var sharedAvatarURL: URL? {
    SharedSnapshotStore.appGroupFileURL(relativePath: profileSharedLocalPath)
  }
}
