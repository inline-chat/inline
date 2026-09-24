import GRDB
import InlineKit

struct DockMenuSnapshot {
  struct Chat {
    let peer: Peer
    let chatID: Int64?
    let title: String
  }

  let chats: [Chat]

  /// Read one local snapshot when the Dock opens. Reuse the badge's predicates, including
  /// manual unread marks and catalog exclusions; sidebar space/open state is irrelevant.
  static func fetch(_ db: Database) throws -> Self {
    let dialogs = try Dialog.fetchAll(db, sql: """
      SELECT "dialog".*
      FROM "dialog"
      LEFT JOIN "chat" ON "chat"."id" = "dialog"."chatId"
      LEFT JOIN "message" AS "lastMessage"
        ON "lastMessage"."chatId" = "chat"."id"
        AND "lastMessage"."messageId" = "chat"."lastMsgId"
      WHERE \(Dialog.chatListVisibilitySQL)
        AND ("dialog"."archived" IS NULL OR "dialog"."archived" = 0)
        AND \(Dialog.unreadSQL)
        AND \(Dialog.prominentUnreadSQL)
      ORDER BY COALESCE("lastMessage"."date", "chat"."date") DESC, "dialog"."id" DESC
      """)

    let chats = try dialogs.enumerated().map { index, dialog in
      let peer = dialog.peerId
      var chatID = dialog.chatId
      // Resolve only the five displayed titles. The remaining records are clear-action targets.
      let chat: InlineKit.Chat?
      if index < DockMenu.chatLimit || chatID == nil {
        chat = try InlineKit.Chat.getByPeerId(db: db, peerId: peer)
        chatID = chatID ?? chat?.id
      } else {
        chat = nil
      }

      let title: String
      if index < DockMenu.chatLimit, let userID = dialog.peerUserId {
        title = try User.fetchOne(db, key: userID)?.displayName ?? "User"
      } else {
        title = chat?.title ?? "Untitled Chat"
      }
      return Chat(peer: peer, chatID: chatID, title: title)
    }
    return Self(chats: chats)
  }
}
