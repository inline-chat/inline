import Foundation
import GRDB
import InlineKit

actor UpdatesManager {
  private var database: AppDatabase = .shared
  private var log = Log.scoped("Updates")

  func apply(update: Update, db: Database) throws {
    log.debug("apply update")

    if let update = update.newMessage {
      log.debug("applying new message")
      try update.apply(db: db)
    } else if let update = update.updateMessageId {
      log.debug("applying update message id")
      try update.apply(db: db)
    }
  }

  func applyBatch(updates: [Update]) {
    log.debug("applying \(updates.count) updates")
    do {
      try database.dbWriter.write { db in
        for update in updates {
          try apply(update: update, db: db)
        }
      }
    } catch {
      // handle error
      log.error("Failed to apply updates", error: error)
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
      var message = try Message.filter(Column("randomId") == randomId).fetchOne(db)
      print("found message by randomId \(message)")
      if var message = message {
        message.messageId = self.messageId
        try message.save(db)
      }
    }
  }
}
