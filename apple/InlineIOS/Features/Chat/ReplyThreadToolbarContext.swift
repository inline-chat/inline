import Foundation
import GRDB
import InlineKit
import Logger

struct ReplyThreadToolbarContext: Equatable {
  struct SpaceLink: Equatable {
    let id: Int64
    let title: String
  }

  struct ParentLink: Equatable {
    let peer: Peer
    let title: String
  }

  let title: String
  let space: SpaceLink?
  let parent: ParentLink?

  var hasBreadcrumb: Bool {
    space != nil || parent != nil
  }
}

enum ReplyThreadToolbarContextLoader {
  private static let maxExcerptLength = 72
  private static let genericFallbackTitle = "Re: Message"
  private static let log = Log.scoped("ReplyThreadToolbarContext")

  static func load(
    for chat: Chat,
    contextSpaceId: Int64?,
    db appDatabase: AppDatabase = .shared
  ) async -> ReplyThreadToolbarContext? {
    do {
      return try await appDatabase.reader.read { db in
        try context(for: chat, contextSpaceId: contextSpaceId, db: db)
      }
    } catch {
      log.error("Failed to load reply thread toolbar context", error: error)
      return ReplyThreadToolbarContext(
        title: fallbackTitle(for: chat),
        space: nil,
        parent: nil
      )
    }
  }

  static func fallbackTitle(for chat: Chat?) -> String {
    guard let chat else { return genericFallbackTitle }
    return title(for: chat, anchorText: nil)
  }

  private static func context(
    for chat: Chat,
    contextSpaceId: Int64?,
    db: Database
  ) throws -> ReplyThreadToolbarContext {
    let space = try spaceLink(for: chat, contextSpaceId: contextSpaceId, db: db)
    let parentChat = try chat.parentChatId.flatMap { try Chat.fetchOne(db, id: $0) }
    let parentDialog = try parentChat.flatMap { parentChat in
      try Dialog
        .filter(Column("chatId") == parentChat.id)
        .fetchOne(db)
    }
    let parentPeerUserId = parentDialog?.peerUserId ?? parentChat?.peerUserId
    let parentUserInfo = try parentPeerUserId.flatMap { userId in
      try User
        .userInfoQuery()
        .filter(Column("id") == userId)
        .fetchOne(db)
    }

    let parent = try parentLink(
      for: chat,
      parentChat: parentChat,
      parentUserInfo: parentUserInfo,
      parentPeerUserId: parentPeerUserId,
      db: db
    )

    return ReplyThreadToolbarContext(
      title: try title(for: chat, db: db),
      space: space,
      parent: parent
    )
  }

  private static func spaceLink(
    for chat: Chat,
    contextSpaceId: Int64?,
    db: Database
  ) throws -> ReplyThreadToolbarContext.SpaceLink? {
    guard let spaceId = chat.spaceId, spaceId != contextSpaceId else { return nil }
    guard let space = try Space.fetchOne(db, id: spaceId) else { return nil }
    return ReplyThreadToolbarContext.SpaceLink(id: spaceId, title: space.displayName)
  }

  private static func parentLink(
    for chat: Chat,
    parentChat: Chat?,
    parentUserInfo: UserInfo?,
    parentPeerUserId: Int64?,
    db: Database
  ) throws -> ReplyThreadToolbarContext.ParentLink? {
    guard chat.isReplyThread, let parentChatId = chat.parentChatId else { return nil }

    if let parentChat {
      return ReplyThreadToolbarContext.ParentLink(
        peer: parentPeer(for: parentChat, parentPeerUserId: parentPeerUserId),
        title: try parentTitle(for: parentChat, userInfo: parentUserInfo, db: db)
      )
    }

    return ReplyThreadToolbarContext.ParentLink(
      peer: .thread(id: parentChatId),
      title: "Thread"
    )
  }

  private static func title(for chat: Chat, db: Database) throws -> String {
    try title(for: chat, anchorText: anchorText(for: chat, db: db))
  }

  private static func title(for chat: Chat, anchorText: String?) -> String {
    if let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       title.isEmpty == false
    {
      return title
    }

    guard needsFallback(chat) else {
      return chat.humanReadableTitle ?? "Chat"
    }

    return fallback(anchorText: anchorText)
  }

  private static func parentTitle(for chat: Chat, userInfo: UserInfo?, db: Database) throws -> String {
    if chat.type == .privateChat {
      if let userInfo {
        return userInfo.user.isCurrentUser() ? "Saved Messages" : userInfo.user.displayName
      }
      return "Direct Message"
    }

    return try title(for: chat, db: db)
  }

  private static func parentPeer(for chat: Chat, parentPeerUserId: Int64?) -> Peer {
    guard chat.type == .privateChat else {
      return .thread(id: chat.id)
    }

    if let parentPeerUserId {
      return .user(id: parentPeerUserId)
    }

    return .thread(id: chat.id)
  }

  private static func anchorText(for chat: Chat, db: Database) throws -> String? {
    guard needsFallback(chat),
          let parentChatId = chat.parentChatId,
          let parentMessageId = chat.parentMessageId
    else {
      return nil
    }

    let message = try Message
      .filter(Column("chatId") == parentChatId)
      .filter(Column("messageId") == parentMessageId)
      .fetchOne(db)

    return message?.stringRepresentationPlain
  }

  private static func needsFallback(_ chat: Chat) -> Bool {
    guard chat.isReplyThread else { return false }
    let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return title == nil || title?.isEmpty == true
  }

  private static func fallback(anchorText: String?) -> String {
    let excerpt = anchorText?
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { $0.isEmpty == false }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let excerpt, excerpt.isEmpty == false else {
      return genericFallbackTitle
    }

    return "Re: \(String(excerpt.prefix(maxExcerptLength)))"
  }
}
