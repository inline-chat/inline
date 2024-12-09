import Foundation
import GRDB

actor UpdatesManager {
  private var database: AppDatabase = .shared
  private var log = Log.scoped("Updates")

  func apply(update: Update, db: Database) throws {
    self.log.debug("apply update")

    if let update = update.newMessage {
      self.log.debug("applying new message")
      try update.apply(db: db)
    } else if let update = update.updateMessageId {
      self.log.debug("applying update message id")
      try update.apply(db: db)
    }
  }

  func applyBatch(updates: [Update]) {
    self.log.debug("applying \(updates.count) updates")
    do {
      try self.database.dbWriter.write { db in
        for update in updates {
          try self.apply(update: update, db: db)
        }
      }
    } catch {
      // handle error
      self.log.error("Failed to apply updates", error: error)
    }
  }
}

// MARK: Types

struct Update: Codable {
  /// New message received
  var newMessage: UpdateNewMessage?
  var updateMessageId: UpdateUpdateMessageId?
}

struct UpdateNewMessage: Codable {
  var message: ApiMessage

  func apply(db: Database) throws {
    let message = Message(from: message)
    try message.save(db, onConflict: .ignore) // NOTE: @Mo: we ignore to avoid animation issues for our own messages
    var chat = try Chat.fetchOne(db, id: message.chatId)
    chat?.lastMsgId = message.messageId
    try chat?.save(db)
  }
}

struct UpdateUpdateMessageId: Codable {
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
        try message.save(db)
        var chat = try Chat.fetchOne(db, id: message.chatId)
        chat?.lastMsgId = message.messageId
        try chat?.save(db)
      }
    }
  }
}
