import Foundation
import GRDB

class UpdatesManager {
  private var database: AppDatabase = .shared
  private var log = Log.scoped("UpdatesManager")

  func apply(update: Update, db: Database) throws {
    log.debug("apply update")

    if let update = update.newMessage {
      try update.apply(db: db)
    }
  }

  func applyBatch(updates: [Update]) {
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

struct Update {
  /// New message received
  var newMessage: UpdateNewMessage?
}

struct UpdateNewMessage {
  var message: ApiMessage

  func apply(db: Database) throws {
    let message = Message(from: message)
    try message.save(db)
  }
}
