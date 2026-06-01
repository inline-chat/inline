import Foundation
import GRDB
import InlineKit

enum ReplyThreadTitleFallback {
  private static let maxExcerptLength = 72
  static let genericFallbackTitle = "Re: Message"

  static func title(for chat: Chat, db: Database) throws -> String {
    try title(for: chat, anchorText: anchorText(for: chat, db: db))
  }

  static func title(for chat: Chat, anchorText: String?) -> String {
    if let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty == false {
      return title
    }

    guard chat.isReplyThread else {
      return chat.humanReadableTitle ?? "Chat"
    }

    return fallback(anchorText: anchorText)
  }

  static func explicitTitle(chatId: Int64, db: Database) throws -> String? {
    guard let chat = try Chat.fetchOne(db, id: chatId),
          let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines),
          title.isEmpty == false
    else {
      return nil
    }

    return title
  }

  static func titlesByChatId(for items: [HomeChatItem], db: Database) throws -> [Int64: String] {
    try titlesByChatId(for: items.compactMap(\.chat), db: db)
  }

  static func titlesByChatId(for chats: [Chat], db: Database) throws -> [Int64: String] {
    var titles: [Int64: String] = [:]

    for chat in chats where needsFallback(chat) {
      titles[chat.id] = try title(for: chat, db: db)
    }

    return titles
  }

  static func anchorText(for chat: Chat, db: Database) throws -> String? {
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

  static func isGenericFallback(_ title: String) -> Bool {
    title == genericFallbackTitle
  }

  static func isReplyFallback(_ title: String) -> Bool {
    title == genericFallbackTitle || title.hasPrefix("Re: ")
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
