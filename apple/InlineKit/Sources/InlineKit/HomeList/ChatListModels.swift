import Foundation

public enum ChatListSort: String, CaseIterable, Codable, Hashable, Sendable {
  case lastUpdated
  case recentlyOpened
}

public enum ChatListLayoutMode: String, CaseIterable, Codable, Hashable, Sendable {
  case compact
  case standard
  case large
}

public enum ChatListProminence: String, Codable, Hashable, Sendable {
  case standard
  case prominent
}

public struct ChatListUserAvatarDescriptor: Codable, Hashable, Sendable {
  public let userID: Int64
  public let firstName: String?
  public let lastName: String?
  public let email: String?
  public let username: String?
  public let stableAvatarIdentity: String?
  public let remoteURL: URL?
  public let localURL: URL?

  public init(
    userID: Int64,
    firstName: String? = nil,
    lastName: String? = nil,
    email: String? = nil,
    username: String? = nil,
    profileFileID: String? = nil,
    profileFileUniqueID: String? = nil,
    profileLocalPath: String? = nil,
    remoteURL: URL? = nil,
    localURL: URL? = nil
  ) {
    self.userID = userID
    self.firstName = firstName
    self.lastName = lastName
    self.email = email
    self.username = username
    if let profileFileUniqueID, profileFileUniqueID.isEmpty == false {
      stableAvatarIdentity = "unique:\(profileFileUniqueID)"
    } else if let profileFileID, profileFileID.isEmpty == false {
      stableAvatarIdentity = "id:\(profileFileID)"
    } else if let profileLocalPath, profileLocalPath.isEmpty == false {
      stableAvatarIdentity = "local:\(profileLocalPath)"
    } else {
      stableAvatarIdentity = nil
    }
    self.remoteURL = remoteURL
    self.localURL = localURL
  }
}

public struct ChatListThreadIconDescriptor: Codable, Hashable, Sendable {
  public let emoji: String?
  public let title: String
  public let isReplyThread: Bool

  public init(emoji: String?, title: String, isReplyThread: Bool) {
    self.emoji = emoji
    self.title = title
    self.isReplyThread = isReplyThread
  }
}

public enum ChatListIdentityDescriptor: Codable, Hashable, Sendable {
  case user(ChatListUserAvatarDescriptor)
  case thread(ChatListThreadIconDescriptor)
}

public struct ChatListContentSignature: Codable, Hashable, Sendable {
  public static let empty = Self()

  public let messageID: Int64?
  public let messageRevision: Int64?
  public let draftRevision: Int64?

  public init(
    messageID: Int64? = nil,
    messageRevision: Int64? = nil,
    draftRevision: Int64? = nil
  ) {
    self.messageID = messageID
    self.messageRevision = messageRevision
    self.draftRevision = draftRevision
  }
}

/// A narrow, immutable value consumed by chat-list projection, badges, and actions.
/// Rendering-only descriptors can be added without retaining the source database graph.
public struct ChatListItemSnapshot: Identifiable, Codable, Hashable, Sendable {
  public var id: Peer { peer }

  public let peer: Peer
  public let chatID: Int64
  public let spaceID: Int64?
  public let title: String
  public let previewSenderName: String?
  public let previewText: String?
  public let timestampText: String?
  public let identity: ChatListIdentityDescriptor?
  public let unreadCount: Int
  public let unreadMark: Bool
  public let prominence: ChatListProminence
  public let isOpen: Bool
  public let isPinned: Bool
  public let isFollowed: Bool
  public let isChatListHidden: Bool
  public let isArchived: Bool
  public let lastUpdatedAt: Date?
  public let openedDate: Date?
  public let order: String?
  public let pinnedOrder: String?
  public let contentSignature: ChatListContentSignature

  public init(
    peer: Peer,
    chatID: Int64,
    spaceID: Int64? = nil,
    title: String,
    previewSenderName: String? = nil,
    previewText: String? = nil,
    timestampText: String? = nil,
    identity: ChatListIdentityDescriptor? = nil,
    unreadCount: Int = 0,
    unreadMark: Bool = false,
    prominence: ChatListProminence = .standard,
    isOpen: Bool = false,
    isPinned: Bool = false,
    isFollowed: Bool = false,
    isChatListHidden: Bool = false,
    isArchived: Bool = false,
    lastUpdatedAt: Date? = nil,
    openedDate: Date? = nil,
    order: String? = nil,
    pinnedOrder: String? = nil,
    contentSignature: ChatListContentSignature = .empty
  ) {
    self.peer = peer
    self.chatID = chatID
    self.spaceID = spaceID
    self.title = title
    self.previewSenderName = previewSenderName
    self.previewText = previewText
    self.timestampText = timestampText
    self.identity = identity
    self.unreadCount = unreadCount
    self.unreadMark = unreadMark
    self.prominence = prominence
    self.isOpen = isOpen
    self.isPinned = isPinned
    self.isFollowed = isFollowed
    self.isChatListHidden = isChatListHidden
    self.isArchived = isArchived
    self.lastUpdatedAt = lastUpdatedAt
    self.openedDate = openedDate
    self.order = order
    self.pinnedOrder = pinnedOrder
    self.contentSignature = contentSignature
  }

  public var isUnread: Bool {
    unreadCount > 0 || unreadMark
  }

  public var isProminent: Bool {
    prominence == .prominent
  }

  public var isVisibleInHome: Bool {
    !isChatListHidden && !isArchived
  }

  /// Inbox membership intentionally ignores pin state. A closed pinned chat remains in All Chats.
  public var isInboxMember: Bool {
    isVisibleInHome && isOpen
  }
}
