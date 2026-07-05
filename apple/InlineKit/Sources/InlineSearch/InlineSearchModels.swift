import Foundation
import InlineKit

public struct InlineSearchScope: Sendable, Hashable {
  public var spaceId: Int64?
  public var includeArchived: Bool
  public var includeSpaceChatsInHome: Bool
  public var includeGlobalUsers: Bool
  public var messageSort: LocalMessageSearchSort

  public init(
    spaceId: Int64? = nil,
    includeArchived: Bool = false,
    includeSpaceChatsInHome: Bool = true,
    includeGlobalUsers: Bool = true,
    messageSort: LocalMessageSearchSort = .relevance
  ) {
    self.spaceId = spaceId
    self.includeArchived = includeArchived
    self.includeSpaceChatsInHome = includeSpaceChatsInHome
    self.includeGlobalUsers = includeGlobalUsers
    self.messageSort = messageSort
  }
}

public struct InlineSearchLimits: Sendable, Hashable {
  public var chatLimit: Int
  public var messageBatchSize: Int
  public var globalUserLimit: Int
  public var globalDebounceNanoseconds: UInt64

  public init(
    chatLimit: Int = 20,
    messageBatchSize: Int = 20,
    globalUserLimit: Int = 20,
    globalDebounceNanoseconds: UInt64 = 250_000_000
  ) {
    self.chatLimit = max(1, chatLimit)
    self.messageBatchSize = max(1, min(messageBatchSize, LocalMessageSearch.maxLimit - 1))
    self.globalUserLimit = max(1, globalUserLimit)
    self.globalDebounceNanoseconds = globalDebounceNanoseconds
  }
}

public struct InlineSearchChatResult: Identifiable, Sendable, Hashable {
  public let id: String
  public let snapshot: HomeChatListItemSnapshot
  public let peer: Peer
  public let chatId: Int64?
  public let spaceId: Int64?
  public let title: String
  public let subtitle: String?
  public let preview: String
  public let chat: Chat?
  public let userInfo: UserInfo?
  public let messageCount: Int
  public let lastDate: Date
  public let unread: Bool
  public let pinned: Bool
  public let archived: Bool
  public let score: Int

  init(snapshot: HomeChatListItemSnapshot, messageCount: Int, score: Int) {
    self.snapshot = snapshot
    peer = snapshot.peerId
    id = "chat-\(snapshot.peerId.toString())"
    chatId = snapshot.chatId
    spaceId = snapshot.item.dialog.spaceId ?? snapshot.item.chat?.spaceId ?? snapshot.item.space?.id
    title = snapshot.title
    subtitle = snapshot.parentTitle ?? snapshot.spaceTitle ?? userSubtitle(snapshot.item.displayUserInfo?.user)
    preview = snapshot.preview
    chat = snapshot.item.chat
    userInfo = snapshot.item.displayUserInfo
    self.messageCount = messageCount
    lastDate = snapshot.sortDate
    unread = snapshot.unread
    pinned = snapshot.pinned
    archived = snapshot.archived
    self.score = score
  }
}

public struct InlineSearchGlobalUserResult: Identifiable, Sendable, Hashable {
  public let id: Int64
  public let user: ApiUser
  public let title: String
  public let subtitle: String?
  public let score: Int

  init(user: ApiUser, score: Int) {
    id = user.id
    self.user = user
    title = apiUserTitle(user)
    subtitle = user.username.map { "@\($0)" } ?? user.email
    self.score = score
  }
}

public struct InlineSearchLocalPayload: Sendable, Equatable {
  public let chats: [InlineSearchChatResult]
  public let messages: [LocalMessageSearchResult]
  public let hasMoreMessages: Bool
  public let errorText: String?

  static func empty(errorText: String? = nil) -> Self {
    Self(chats: [], messages: [], hasMoreMessages: false, errorText: errorText)
  }
}

struct InlineSearchMessagePage: Sendable, Equatable {
  let results: [LocalMessageSearchResult]
  let hasMore: Bool
  let errorText: String?

  static let empty = Self(results: [], hasMore: false, errorText: nil)
}

func apiUserTitle(_ user: ApiUser) -> String {
  let name = [user.firstName, user.lastName]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: " ")

  if !name.isEmpty {
    return name
  }

  return user.anyName
}

private func userSubtitle(_ user: User?) -> String? {
  guard let user else { return nil }
  return user.username.map { "@\($0)" } ?? user.email
}
