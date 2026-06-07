import Foundation
import GRDB

public enum ReplyThreadTitleFallback {
  private static let maxExcerptLength = 72
  public static let genericFallbackTitle = "Re: Message"

  public static func title(for chat: Chat, db: Database) throws -> String {
    try title(for: chat, anchorText: anchorText(for: chat, db: db))
  }

  public static func title(for chat: Chat, anchorText: String?) -> String {
    if let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty == false {
      return title
    }

    guard needsFallback(chat) else {
      return chat.humanReadableTitle ?? "Chat"
    }

    return fallback(anchorText: anchorText)
  }

  public static func customTitle(chatId: Int64, db: Database) throws -> String? {
    guard let chat = try Chat.fetchOne(db, id: chatId) else { return nil }
    return customTitle(for: chat)
  }

  public static func customTitle(for chat: Chat) -> String? {
    guard chat.isUntitled != true,
          let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines),
          title.isEmpty == false
    else {
      return nil
    }

    return title
  }

  public static func titlesByChatId(for items: [HomeChatItem], db: Database) throws -> [Int64: String] {
    try titlesByChatId(for: items.compactMap(\.chat), db: db)
  }

  public static func titlesByChatId(for chats: [Chat], db: Database) throws -> [Int64: String] {
    var titles: [Int64: String] = [:]

    for chat in chats where needsFallback(chat) {
      titles[chat.id] = try title(for: chat, db: db)
    }

    return titles
  }

  public static func parentTitlesByChatId(for items: [HomeChatItem], db: Database) throws -> [Int64: String] {
    try parentTitlesByChatId(for: items.compactMap(\.chat), db: db)
  }

  public static func parentTitlesByChatId(for chats: [Chat], db: Database) throws -> [Int64: String] {
    let replyChats = chats.filter { $0.isReplyThread && $0.parentChatId != nil }
    let parentIds = Set(replyChats.compactMap(\.parentChatId))
    guard parentIds.isEmpty == false else { return [:] }

    let parents = try Chat
      .filter(parentIds.contains(Column("id")))
      .fetchAll(db)
    let parentsById = Dictionary(uniqueKeysWithValues: parents.map { ($0.id, $0) })
    let parentDialogsByChatId = try parentDialogsByChatId(parentIds: parentIds, db: db)
    let parentUsersById = try parentUsersById(parents: parents, dialogsByChatId: parentDialogsByChatId, db: db)

    var titles: [Int64: String] = [:]
    for chat in replyChats {
      guard let parentChatId = chat.parentChatId, let parent = parentsById[parentChatId] else { continue }
      let userId = parentUserId(for: parent, dialogsByChatId: parentDialogsByChatId)
      titles[chat.id] = parentTitle(for: parent, userInfo: userId.flatMap { parentUsersById[$0] })
    }

    return titles
  }

  public static func anchorText(for chat: Chat, db: Database) throws -> String? {
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

  public static func isGenericFallback(_ title: String) -> Bool {
    title == genericFallbackTitle
  }

  public static func isReplyFallback(_ title: String) -> Bool {
    title == genericFallbackTitle || title.hasPrefix("Re: ")
  }

  private static func needsFallback(_ chat: Chat) -> Bool {
    guard chat.isReplyThread else { return false }
    let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return title == nil || title?.isEmpty == true
  }

  private static func parentTitle(for chat: Chat, userInfo: UserInfo?) -> String {
    if chat.type == .privateChat {
      if let userInfo {
        return userInfo.user.isCurrentUser() ? "Saved Messages" : userInfo.user.displayName
      }
      return "Direct Message"
    }

    return title(for: chat, anchorText: nil)
  }

  private static func parentDialogsByChatId(parentIds: Set<Int64>, db: Database) throws -> [Int64: Dialog] {
    let dialogs = try Dialog
      .filter(parentIds.contains(Column("chatId")))
      .fetchAll(db)

    var dialogsByChatId: [Int64: Dialog] = [:]
    for dialog in dialogs {
      guard let chatId = dialog.chatId else { continue }
      dialogsByChatId[chatId] = dialog
    }
    return dialogsByChatId
  }

  private static func parentUsersById(
    parents: [Chat],
    dialogsByChatId: [Int64: Dialog],
    db: Database
  ) throws -> [Int64: UserInfo] {
    let userIds = Set(parents.compactMap { parent in
      parentUserId(for: parent, dialogsByChatId: dialogsByChatId)
    })
    guard userIds.isEmpty == false else { return [:] }

    let users = try User
      .userInfoQuery()
      .filter(userIds.contains(Column("id")))
      .fetchAll(db)
    return Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
  }

  private static func parentUserId(for chat: Chat, dialogsByChatId: [Int64: Dialog]) -> Int64? {
    guard chat.type == .privateChat else { return nil }
    return dialogsByChatId[chat.id]?.peerUserId ?? chat.peerUserId
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
