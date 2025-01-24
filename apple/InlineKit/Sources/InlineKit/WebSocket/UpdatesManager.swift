import Foundation
import GRDB

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
      } else if let update = update.updateMessageId {
//        self.log.debug("applying update message id")
        try update.apply(db: db)
      } else if let update = update.updateUserStatus {
//        self.log.debug("applying update user status")
        try update.apply(db: db)
      } else if let update = update.updateComposeAction {
//        self.log.debug("applying update compose action")
        update.apply()
      }
    } catch {
      self.log.error("Failed to apply update", error: error)
    }
  }

  func applyBatch(updates: [Update]) {
    self.log.debug("applying \(updates.count) updates")
    do {
      try self.database.dbWriter.write { db in
        for update in updates {
          self.apply(update: update, db: db)
        }
      }
    } catch {
      // handle error
      self.log.error("Failed to apply updates", error: error)
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
}

struct UpdateNewMessage: Codable {
  var message: ApiMessage

  func apply(db: Database) throws {
    var message = Message(from: message)
    try message
      .saveMessage(
        db,
        onConflict: .ignore,
        publishChanges: true
      ) // handles update internally
//    try message.save(db, onConflict: .ignore) // NOTE: @Mo: we ignore to avoid animation issues for our own messages
    var chat = try Chat.fetchOne(db, id: message.chatId)
    chat?.lastMsgId = message.messageId
    try chat?.save(db)
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
      if var message = message {
        message.status = .sent
        message.messageId = self.messageId
        message.randomId = nil
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
      }
    }
  }
}

struct UpdateUserStatus: Codable {
  var userId: Int64
  var online: Bool
  var lastOnline: Int64?

  func apply(db: Database) throws {
    try User.filter(id: self.userId).updateAll(
      db,
      [
        Column("online").set(to: self.online),
        Column("lastOnline").set(to: self.lastOnline)
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
    if let action = self.action {
      Task { await ComposeActions.shared.addComposeAction(for: self.peerId, action: action, userId: self.userId) }
    } else {
      // cancel
      Task { await ComposeActions.shared.removeComposeAction(for: self.peerId) }
    }
  }
}
