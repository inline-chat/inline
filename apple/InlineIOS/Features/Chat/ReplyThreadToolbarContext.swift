import Foundation
import GRDB
import InlineKit
import Logger

struct ReplyThreadToolbarContext: Equatable {
  let title: String
  let parentTitle: String?
  let parentPeer: Peer?
}

enum ReplyThreadToolbarContextLoader {
  private static let maxExcerptLength = 72
  private static let genericFallbackTitle = "Re: Message"
  private static let log = Log.scoped("ReplyThreadToolbarContext")

  static func load(for chat: Chat, db appDatabase: AppDatabase = .shared) async -> ReplyThreadToolbarContext? {
    guard chat.isReplyThread else { return nil }

    do {
      return try await appDatabase.reader.read { db in
        try context(for: chat, db: db)
      }
    } catch {
      log.error("Failed to load reply thread toolbar context", error: error)
      return ReplyThreadToolbarContext(
        title: title(for: chat, anchorText: nil),
        parentTitle: nil,
        parentPeer: nil
      )
    }
  }

  static func fallbackTitle(for chat: Chat?) -> String {
    guard let chat else { return genericFallbackTitle }
    return title(for: chat, anchorText: nil)
  }

  private static func context(for chat: Chat, db: Database) throws -> ReplyThreadToolbarContext {
    let anchorText = try anchorText(for: chat, db: db)
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

    let parentTitle = try parentChat.map { parentChat in
      try Self.parentTitle(for: parentChat, userInfo: parentUserInfo, db: db)
    }
    let parentPeer = parentChat.map { parentChat in
      Self.parentPeer(for: parentChat, parentPeerUserId: parentPeerUserId)
    }

    return ReplyThreadToolbarContext(
      title: title(for: chat, anchorText: anchorText),
      parentTitle: parentTitle,
      parentPeer: parentPeer
    )
  }

  private static func title(for chat: Chat, anchorText: String?) -> String {
    if let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines),
       title.isEmpty == false
    {
      return title
    }

    guard chat.isReplyThread else {
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

    return try title(for: chat, anchorText: anchorText(for: chat, db: db))
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
    guard chat.isReplyThread,
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

  private static func fallback(anchorText: String?) -> String {
    let excerpt = anchorText?
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let excerpt, !excerpt.isEmpty else {
      return genericFallbackTitle
    }

    return "Re: \(String(excerpt.prefix(maxExcerptLength)))"
  }
}
