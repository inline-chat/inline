import Foundation
import GRDB
import Logger

actor UpdatesManager {
  public static let shared = UpdatesManager()

  private var database: AppDatabase = .shared
  private var log = Log.scoped("Updates")

  func apply(update: Update, db: Database) {
//    self.log.debug("apply update")

    do {
      if let update = update.newMessage {
//        self.log.debug("applying new message")
        try update.apply(db: db)
        UnreadManager.shared.updateAppIconBadge()
      } else if let update = update.updateMessageId {
//        self.log.debug("applying update message id")
        try update.apply(db: db)
      } else if let update = update.updateUserStatus {
//        self.log.debug("applying update user status")
        try update.apply(db: db)
      } else if let update = update.updateComposeAction {
//        self.log.debug("applying update compose action")
        update.apply()
      } else if let update = update.deleteMessage {
        try update.apply(db: db)
      } else {
        log.warning("Unknown update type")
      }
    } catch {
      log.error("Failed to apply update", error: error)
    }
  }

  func applyBatch(updates: [Update]) {
    log.debug("applying \(updates.count) updates")
    do {
      try database.dbWriter.write { db in
        for update in updates {
          self.apply(update: update, db: db)
        }
      }
    } catch {
      // handle error
      log.error("Failed to apply updates", error: error)
    }
  }
}

// MARK: Types

public struct Update: Codable, Sendable {
  /// New message received
  var newMessage: UpdateNewMessage?
  var updateMessageId: UpdateMessageId?
  var updateUserStatus: UpdateUserStatus?
  var updateComposeAction: UpdateComposeAction?
  var deleteMessage: UpdateDeleteMessage?
}

struct UpdateNewMessage: Codable {
  var message: ApiMessage

  func apply(db: Database) throws {
    let msg = try message.saveFullMessage(
      db,
      publishChanges: true
    )

    // I think this needs to be faster
    var chat = try Chat.fetchOne(db, id: message.chatId)
    chat?.lastMsgId = msg.messageId
    try chat?.save(db)

    // increase unread count if message is not ours
    if var dialog = try? Dialog.get(peerId: msg.peerId).fetchOne(db) {
      dialog.unreadCount = (dialog.unreadCount ?? 0) + (msg.out == false ? 1 : 0)
      try dialog.update(db)
    }
    UnreadManager.shared.updateAppIconBadge()
  }
}

struct UpdateMessageId: Codable {
  var messageId: Int64
  var randomId: String

  func apply(db: Database) throws {
    if let randomId = Int64(randomId) {
      let message = try Message.filter(Column("randomId") == randomId).fetchOne(
        db
      )
      if var message {
        message.status = .sent
        message.messageId = messageId
        message.randomId = nil // should we do this?
//        try message.save(db)
        try message
          .saveMessage(
            db,
            onConflict: .ignore,
            publishChanges: true
          )

        // TODO: optimize this to update in one go
        var chat = try Chat.fetchOne(db, id: message.chatId)
        chat?.lastMsgId = message.messageId
        try chat?.save(db)
        UnreadManager.shared.updateAppIconBadge()
      }
    }
  }
}

struct UpdateUserStatus: Codable {
  var userId: Int64
  var online: Bool
  var lastOnline: Int64?

  func apply(db: Database) throws {
    Log.shared.debug("Updating user status \(userId) online: \(online)")
    try User.filter(id: userId).updateAll(
      db,
      [
        Column("online").set(to: online),
        Column("lastOnline").set(to: lastOnline),
      ]
    )
  }
}

struct UpdateComposeAction: Codable {
  var userId: Int64
  var peerId: Peer

  // null means cancel
  var action: ApiComposeAction?

  func apply() {
    if let action {
      Task { await ComposeActions.shared.addComposeAction(for: peerId, action: action, userId: userId) }
    } else {
      // cancel
      Task { await ComposeActions.shared.removeComposeAction(for: peerId) }
    }
  }
}

struct UpdateDeleteMessage: Codable {
  var messageId: Int64
  var peerId: Peer

  func apply(db: Database) throws {
    guard let chat = try Chat.getByPeerId(peerId: peerId) else {
      Log.shared.error("Failed to find chat for peer \(peerId)")
      return
    }

    if chat.lastMsgId == messageId {
      let previousMessage = try Message
        .filter(Column("chatId") == chat.id)
        .order(Column("date").desc)
        .limit(1, offset: 1)
        .fetchOne(db)

      var updatedChat = chat
      updatedChat.lastMsgId = previousMessage?.messageId
      try updatedChat.save(db)
    }

    try Message
      .filter(Column("messageId") == messageId)
      .filter(Column("chatId") == chat.id)
      .deleteAll(db)

    Task { @MainActor in
      MessagesPublisher.shared.messagesDeleted(messageIds: [messageId], peer: peerId)
    }
    UnreadManager.shared.updateAppIconBadge()
  }
}
