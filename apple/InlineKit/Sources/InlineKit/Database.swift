import Auth
import Foundation
import GRDB
import InlineConfig
import Logger

// MARK: - DB main class

public final class AppDatabase: Sendable {
  public let dbWriter: any DatabaseWriter
  static let log = Log.scoped(
    "AppDatabase",
    // Enable tracing for seeing all SQL statements
    enableTracing: false
  )

  public init(_ dbWriter: any GRDB.DatabaseWriter) throws {
    self.dbWriter = dbWriter
    try migrator.migrate(dbWriter)
  }
}

// MARK: - Migrations

public extension AppDatabase {
  var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    #if DEBUG
    migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v1") { db in
      // User table
      try db.create(table: "user") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("email", .text)
        t.column("firstName", .text)
        t.column("lastName", .text)
        t.column("username", .text)
        t.column("date", .datetime).notNull()
      }

      // Space table
      try db.create(table: "space") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("name", .text).notNull()
        t.column("date", .datetime).notNull()
        t.column("creator", .boolean)
      }

      // Member table
      try db.create(table: "member") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("userId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("spaceId", .integer).references("space", column: "id", onDelete: .setNull)
        t.column("date", .datetime).notNull()
        t.column("role", .text).notNull()

        t.uniqueKey(["userId", "spaceId"])
      }

      // Chat table
      try db.create(table: "chat") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("spaceId", .integer).references("space", column: "id", onDelete: .cascade)
        t.column("peerUserId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("title", .text)
        t.column("type", .integer).notNull().defaults(to: 0)
        t.column("date", .datetime).notNull()
        t.column("lastMsgId", .integer)
        t.foreignKey(
          ["id", "lastMsgId"], references: "message", columns: ["chatId", "messageId"],
          onDelete: .setNull, onUpdate: .cascade, deferred: true
        )
      }

      // Message table
      try db.create(table: "message") { t in
        t.autoIncrementedPrimaryKey("globalId").unique()
        t.column("messageId", .integer).notNull()
        t.column("chatId", .integer).references("chat", column: "id", onDelete: .cascade)
        t.column("fromId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("date", .datetime).notNull()
        t.column("text", .text)
        t.column("editDate", .datetime)
        t.column("peerUserId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("peerThreadId", .integer).references("chat", column: "id", onDelete: .setNull)
        t.column("mentioned", .boolean)
        t.column("out", .boolean)
        t.column("pinned", .boolean)
        t.uniqueKey(["messageId", "chatId"], onConflict: .replace)
      }

      // Dialog table
      try db.create(table: "dialog") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("peerUserId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("peerThreadId", .integer).references("chat", column: "id", onDelete: .setNull)
        t.column("spaceId", .integer).references("space", column: "id", onDelete: .setNull)
        t.column("unreadCount", .integer)
        t.column("readInboxMaxId", .integer)
        t.column("readOutboxMaxId", .integer)
        t.column("pinned", .boolean)
      }
    }

    migrator.registerMigration("v2") { db in
      // Message table
      try db.alter(table: "message") { t in
        t.add(column: "randomId", .integer) // .unique()
      }
    }

    migrator.registerMigration("message status") { db in
      try db.alter(table: "message") { t in
        t.add(column: "status", .integer)
      }
    }

    migrator.registerMigration("online") { db in
      try db.alter(table: "user") { t in
        t.add(column: "online", .boolean)
        t.add(column: "lastOnline", .datetime)
      }
    }

    migrator.registerMigration("repliedToMessageId") { db in
      try db.alter(table: "message") { t in
        t.add(column: "repliedToMessageId", .integer)
      }
    }

    migrator.registerMigration("reactions") { db in
      try db.create(table: "reaction") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("messageId", .integer)
          .notNull()

        t.column("userId", .integer)
          .references("user", column: "id", onDelete: .cascade)
          .notNull()

        t.column("chatId", .integer)
          .references("chat", column: "id", onDelete: .cascade)
          .notNull()

        t.column("emoji", .text)
          .notNull()

        t.column("date", .datetime).notNull()

        t.foreignKey(
          ["chatId", "messageId"], references: "message", columns: ["chatId", "messageId"],
          onDelete: .cascade, onUpdate: .cascade, deferred: true
        )
        t.uniqueKey([
          "chatId", "messageId", "userId", "emoji",
        ])
      }
    }

    migrator.registerMigration("message date index") { db in
      try db.create(index: "message_date_idx", on: "message", columns: ["date"])
    }

    migrator.registerMigration("draft") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "draft", .text)
      }
    }

    migrator.registerMigration("files v2") { db in
      // Files table
      try db.create(table: "file") { t in
        t.column("id", .text).primaryKey()
        t.column("fileUniqueId", .text).unique().indexed()
        t.column("fileType", .text).notNull()
        t.column("fileSize", .integer)

        t.column("thumbSize", .text)
        t
          .column("thumbForFileId", .integer)
          .references("file", column: "id", onDelete: .cascade)

        t.column("width", .integer)
        t.column("height", .integer)
        t.column("temporaryUrl", .text)
        t.column("temporaryUrlExpiresAt", .datetime)
        t.column("localPath", .text)
        t.column("duration", .double)
        t.column("bytes", .blob)
        t.column("uploading", .boolean).notNull().defaults(to: false)
      }

      try db.alter(table: "message") { t in
        t.add(column: "fileId", .text).references("file", column: "id", onDelete: .setNull)
      }
    }

    migrator.registerMigration("dialog archived") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "archived", .boolean)
      }
    }

    migrator.registerMigration("message sender random id unique") { db in
      try db
        .create(
          index: "message_randomid_unique",
          on: "message",
          columns: ["fromId", "randomId"],
          unique: true
        )
    }

    migrator.registerMigration("file 2") { db in
      try db.alter(table: "file") { t in
        t.add(column: "fileName", .text)
        t.add(column: "mimeType", .text)
      }
    }

    migrator.registerMigration("user profile photo") { db in
      try db.alter(table: "file") { t in
        t
          .add(column: "profileForUserId", .integer)
          .references("user", column: "id", onDelete: .setNull)
      }

      try db.alter(table: "user") { t in
        t.add(column: "profileFileId", .text)
          .references("file", column: "id", onDelete: .setNull)
      }
    }

    migrator.registerMigration("chat emoji") { db in
      try db.alter(table: "chat") { t in
        t.add(column: "emoji", .text)
      }
    }

    migrator.registerMigration("attachments") { db in
      try db.create(table: "externalTask") { t in
        t.primaryKey("id", .integer)
        t.column("application", .text)
        t.column("taskId", .text)
        t.column("status", .text)
        t.column("assignedUserId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("url", .text)
        t.column("number", .text)
        t.column("title", .text)
        t.column("date", .datetime)
      }

      try db.create(table: "attachment") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("messageId", .integer).references(
          "message", column: "globalId", onDelete: .cascade)
        t.column("externalTaskId", .integer).references(
          "externalTask", column: "id", onDelete: .cascade)
      }
    }

    migrator.registerMigration("media tables") { db in
      // Photo table
      try db.create(table: "photo") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("photoId", .integer).unique().indexed()
        t.column("date", .datetime).notNull()
        t.column("format", .text).notNull() // "jpeg", "png"
      }

      // PhotoSize table
      try db.create(table: "photoSize") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("photoId", .integer)
          .references("photo", column: "id", onDelete: .cascade)
          .notNull()
        t.column("type", .text).notNull() // "b", "c", "d", "f", "s", etc.
        t.column("width", .integer)
        t.column("height", .integer)
        t.column("size", .integer)
        t.column("bytes", .blob) // For stripped thumbnails
        t.column("cdnUrl", .text)
        t.column("localPath", .text)
      }

      // Video table
      try db.create(table: "video") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("videoId", .integer).unique().indexed()
        t.column("date", .datetime).notNull()
        t.column("width", .integer)
        t.column("height", .integer)
        t.column("duration", .integer)
        t.column("size", .integer)
        t.column("thumbnailPhotoId", .integer)
          .references("photo", column: "id", onDelete: .setNull)
        t.column("cdnUrl", .text)
        t.column("localPath", .text)
      }

      // Document table
      try db.create(table: "document") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("documentId", .integer).unique().indexed()
        t.column("date", .datetime).notNull()
        t.column("fileName", .text)
        t.column("mimeType", .text)
        t.column("size", .integer)
        t.column("cdnUrl", .text)
        t.column("localPath", .text)
        t.column("thumbnailPhotoId", .integer)
          .references("photo", column: "id", onDelete: .setNull)
      }

      // Update message table to reference media
      try db.alter(table: "message") { t in
        t.add(column: "photoId", .integer).references(
          "photo", column: "photoId", onDelete: .setNull)
        t.add(column: "videoId", .integer).references(
          "video", column: "videoId", onDelete: .setNull)
        t.add(column: "documentId", .integer).references(
          "document", column: "documentId", onDelete: .setNull)
      }
    }

    migrator.registerMigration("transactionId") { db in
      try db.alter(table: "message") { t in
        t.add(column: "transactionId", .text)
      }
    }

    migrator.registerMigration("isSticker") { db in
      try db.alter(table: "message") { t in
        t.add(column: "isSticker", .boolean)
      }
    }

    migrator.registerMigration("urlPreview") { db in
      try db.create(table: "urlPreview") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("url", .text).notNull()
        t.column("siteName", .text)
        t.column("title", .text)
        t.column("description", .text)
        t.column("photoId", .integer)
          .references("photo", column: "photoId", onDelete: .setNull)
        t.column("duration", .integer)
      }
    }

    migrator.registerMigration("add urlPreviewId to attachment") { db in
      try db.alter(table: "attachment") { t in
        t.add(column: "urlPreviewId", .integer).references(
          "urlPreview", column: "id", onDelete: .cascade)
      }
    }

    migrator.registerMigration("drop attachment table") { db in
      try db.drop(table: "attachment")
    }

    migrator.registerMigration("create attachment table v2") { db in
      try db.create(table: "attachment") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("messageId", .integer).references(
          "message", column: "globalId", onDelete: .cascade)
        t.column("externalTaskId", .integer).references(
          "externalTask", column: "id", onDelete: .cascade)
        t.column("urlPreviewId", .integer).references(
          "urlPreview", column: "id", onDelete: .cascade)
        t.column("attachmentId", .integer).unique().indexed()
      }
    }

    migrator.registerMigration("add pending setup and phone number") { db in
      try db.alter(table: "user") { t in
        t.add(column: "phoneNumber", .text)
        t.add(column: "pendingSetup", .boolean).defaults(to: false)
      }
    }

    migrator.registerMigration("chat is public") { db in
      try db.alter(table: "chat") { t in
        t.add(column: "isPublic", .boolean)
      }
    }

    migrator.registerMigration("chat participants") { db in
      try db.create(table: "chatParticipant") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("chatId", .integer).references("chat", column: "id", onDelete: .cascade)
        t.column("userId", .integer).references("user", column: "id", onDelete: .cascade)
        t.column("date", .datetime).notNull()
        t.uniqueKey(["chatId", "userId"], onConflict: .replace)
      }
    }

    migrator.registerMigration("time zone") { db in
      try db.alter(table: "user") { t in
        t.add(column: "timeZone", .text)
      }
    }

    migrator.registerMigration("translations") { db in
      try db.create(table: "translation") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("messageId", .integer).notNull()
        t.column("chatId", .integer).notNull()
        t.column("translation", .text)
        t.column("language", .text).notNull()
        t.column("date", .datetime).notNull()

        // Add foreign key constraints
        t.foreignKey(
          ["chatId", "messageId"],
          references: "message",
          columns: ["chatId", "messageId"],
          onDelete: .cascade
        )
        t.foreignKey(["chatId"], references: "chat", columns: ["id"], onDelete: .cascade)
      }

      // Add index for faster lookups
      try db.create(
        index: "translation_lookup_idx",
        on: "translation",
        columns: ["chatId", "messageId", "language"],
        unique: true
      )
    }

    /// TODOs:
    /// - Add indexes for performance
    /// - Add timestamp integer types instead of Date for performance and faster sort, less storage
    return migrator
  }
}

// MARK: - Database Configuration

public extension AppDatabase {
  /// - parameter base: A base configuration.
  static func makeConfiguration(_ base: Configuration = Configuration()) -> Configuration {
    var config = base

    config.prepareDatabase { db in
      db.trace(options: .statement) { log.trace($0.expandedDescription) }

      if let token = Auth.shared.getToken() {
        #if DEBUG
        log.debug("Database passphrase: \(token)")
        #endif
        try db.usePassphrase(token)
      } else {
        try db.usePassphrase("123")
      }
    }

    return config
  }

  static func authenticated() async throws {
    if let token = Auth.shared.getToken() {
      try AppDatabase.changePassphrase(token)
    } else {
      log.warning("AppDatabase.authenticated called without token")
    }
  }

  static func clearDB() throws {
    _ = try AppDatabase.shared.dbWriter.write { db in

      // Disable foreign key checks temporarily
      try db.execute(sql: "PRAGMA foreign_keys = OFF")

      // Get all table names excluding sqlite_* tables
      let tables = try String.fetchAll(
        db,
        sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table'
        AND name NOT LIKE 'sqlite_%'
        AND name NOT LIKE 'grdb_%'
        """
      )

      // Delete all rows from each table
      for table in tables {
        try db.execute(sql: "DELETE FROM \(table)")

        // Reset the auto-increment counters
        try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name = ?", arguments: [table])
      }

      // Re-enable foreign key checks
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }

    // Note(@mo): Commented because database file won't be availble for the next user!!!!! If you need this
    // find a way to re-create the database file
    // try deleteDatabaseFile()

    log.info("Database successfully cleared.")
  }

  static func loggedOut() throws {
    try clearDB()

    // Reset the database passphrase to a default value
    try AppDatabase.changePassphrase("123")
  }

  internal static func changePassphrase(_ passphrase: String) throws {
    do {
      if let dbPool = AppDatabase.shared.dbWriter as? DatabasePool {
        try dbPool.barrierWriteWithoutTransaction { db in
          try db.changePassphrase(passphrase)
          dbPool.invalidateReadOnlyConnections()
        }
      } else if let dbQueue = AppDatabase.shared.dbWriter as? DatabaseQueue {
        try dbQueue.write { db in
          try db.changePassphrase(passphrase)
        }
      }
    } catch {
      log.error("Failed to change passphrase", error: error)
      throw error
    }
  }
}

public extension AppDatabase {
  static func deleteDatabaseFile() throws {
    let fileManager = FileManager.default
    let databaseUrl = getDatabaseUrl()
    let databasePath = databaseUrl.path

    if fileManager.fileExists(atPath: databasePath) {
      try fileManager.removeItem(at: databaseUrl)
      log.info("Database file successfully deleted.")
    } else {
      log.warning("Database file not found.")
    }
  }
}

// MARK: - Database Access: Reads

public extension AppDatabase {
  /// Provides a read-only access to the database.
  var reader: any GRDB.DatabaseReader {
    dbWriter
  }
}

// MARK: - The database for the application

public extension AppDatabase {
  /// The database for the application
  static let shared = makeShared()

  private static func getDatabaseUrl() -> URL {
    do {
      let fileManager = FileManager.default
      let appSupportURL = try fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: false
      )

      let directory =
        if let userProfile = ProjectConfig.userProfile {
          "Database_\(userProfile)"
        } else {
          "Database"
        }

      let directoryURL = appSupportURL.appendingPathComponent(directory, isDirectory: true)
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

      // Open or create the database
      //            #if DEBUG
      //            let databaseURL = directoryURL.appendingPathComponent("db_dev.sqlite")
      //            #else
      let databaseURL = directoryURL.appendingPathComponent("db.sqlite")
      //            #endif

      return databaseURL
    } catch {
      log.error("Failed to resolve database path", error: error)
      fatalError("Failed to resolve database path \(error)")
    }
  }

  private static func makeShared() -> AppDatabase {
    do {
      let databaseUrl = getDatabaseUrl()
      let databasePath = databaseUrl.path
      let config = AppDatabase.makeConfiguration()
      //      let dbPool = try DatabaseQueue(path: databasePath, configuration: config)
      let dbPool = try DatabasePool(path: databasePath, configuration: config)

      var path = databasePath
      path.replace(" ", with: "\\ ")
      log.debug("Database path: \(path)")

      let iOSLink = "https://testflight.apple.com/join/FkC3f7fz"
      let macOSLink = "https://testflight.apple.com/join/Z8zUcWZH"

      print(
        """
        |TestFlight links|

        iOS: \(iOSLink)
        macOS: \(macOSLink)
        🍎🍎🍎
        """
      )

      // Create the AppDatabase
      let appDatabase = try AppDatabase(dbPool)

      return appDatabase
    } catch {
      // Replace this implementation with code to handle the error appropriately.
      // fatalError() causes the application to generate a crash log and terminate.
      //
      // Typical reasons for an error here include:
      // * The parent directory cannot be created, or disallows writing.
      // * The database is not accessible, due to permissions or data protection when the device is locked.
      // * The device is out of space.
      // * The database could not be migrated to its latest schema version.
      // Check the error message to determine what the actual problem was.
      log.error("Unresolved error", error: error)

      // handle db password issue and create a new one
      log.error("Database initialization error", error: error)

      // Handle different error scenarios
      if error.localizedDescription.contains("SQLite error 26") {
        // Password/encryption error
        log.info("Re-creating database because token was lost")
        do {
          try AppDatabase.deleteDatabaseFile()
          return AppDatabase.makeShared()
        } catch {
          log.error("Failed to recreate database after encryption error", error: error)
        }
      } else if error.localizedDescription.contains("FOREIGN KEY constraint violation") {
        // Foreign key constraint violation
        log.info("Attempting to recover from foreign key constraint violation")
        do {
          // try recoverFromConstraintViolation()
          try AppDatabase.deleteDatabaseFile()
          return AppDatabase.makeShared()
        } catch {
          log.error("Failed to recover from constraint violation", error: error)
        }
      } else if error.localizedDescription.contains("database disk image is malformed") {
        // Corrupted database
        log.info("Database appears to be corrupted, recreating")
        do {
          try AppDatabase.deleteDatabaseFile()
          return AppDatabase.makeShared()
        } catch {
          log.error("Failed to recreate corrupted database", error: error)
        }
      }

      // Create a new empty database as last resort
      log.warning("Creating new empty database as fallback")
      do {
        try AppDatabase.deleteDatabaseFile()
        return AppDatabase.makeShared()
      } catch {
        // If we still can't create a database, we have a serious problem
        log.error("Fatal database error: \(error.localizedDescription)")

        // Instead of crashing, create an in-memory database to allow app to function
        do {
          let dbQueue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
          return try AppDatabase(dbQueue)
        } catch {
          // At this point we have no choice but to crash
          fatalError("Completely unable to initialize database: \(error)")
        }
      }
    }
  }

  /// Creates an empty database for SwiftUI previews
  static func empty() -> AppDatabase {
    // Connect to an in-memory database
    // Refrence https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databaseconnections
    let dbQueue = try! DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    return try! AppDatabase(dbQueue)
  }

  static func emptyWithSpaces() -> AppDatabase {
    let db = AppDatabase.empty()
    do {
      try db.dbWriter.write { db in
        let space1 = Space(name: "Space X", date: Date.now)
        let space2 = Space(name: "Space Y", date: Date.now)
        let space3 = Space(name: "Space Z", date: Date.now)

        try space1.insert(db)
        try space2.insert(db)
        try space3.insert(db)
      }
    } catch {}
    return db
  }

  static func emptyWithChat() -> AppDatabase {
    let db = AppDatabase.empty()
    do {
      try db.dbWriter.write { db in
        let chat = Chat(id: 1_234, date: Date.now, type: .thread, title: "Main", spaceId: nil)

        try chat.insert(db)
      }
    } catch {}
    return db
  }

  /// Used for previews
  static func populated() -> AppDatabase {
    let db = AppDatabase.empty()

    // Populate with test data
    try! db.dbWriter.write { db in
      // Create test users
      let users: [User] = [
        User(
          id: 1, email: "current@example.com", firstName: "Current", lastName: "User",
          username: "current"
        ),
        User(
          id: 2, email: "alice@example.com", firstName: "Alice", lastName: "Smith",
          username: "alice"
        ),
        User(id: 3, email: "bob@example.com", firstName: "Bob", lastName: "Jones", username: "bob"),
        User(
          id: 4, email: "carol@example.com", firstName: "Carol", lastName: "Wilson",
          username: "carol"
        ),
      ]
      try users.forEach { try $0.save(db) }

      // Create test spaces
      let spaces: [Space] = [
        Space(id: 1, name: "Engineering", date: Date(), creator: true),
        Space(id: 2, name: "Design", date: Date(), creator: true),
      ]
      try spaces.forEach { try $0.save(db) }

      // Create test chats (both DMs and threads)
      let chats: [Chat] = [
        // DM chats
        Chat(id: 1, date: Date(), type: .privateChat, title: nil, spaceId: nil, peerUserId: 2),
        Chat(id: 2, date: Date(), type: .privateChat, title: nil, spaceId: nil, peerUserId: 3),

        // Thread chats
        Chat(id: 3, date: Date(), type: .thread, title: "General", spaceId: 1),
        Chat(id: 4, date: Date(), type: .thread, title: "Random", spaceId: 1),
        Chat(id: 5, date: Date(), type: .thread, title: "Design System", spaceId: 2),
      ]
      try chats.forEach { try $0.save(db) }

      // Create test messages
      let messages: [Message] = [
        // Messages in DM with Alice
        Message(
          messageId: 1, fromId: 1, date: Date().addingTimeInterval(-3_600), text: "Hey Alice!",
          peerUserId: 2, peerThreadId: nil, chatId: 1, out: true
        ),
        Message(
          messageId: 2, fromId: 2, date: Date().addingTimeInterval(-3_500),
          text: "Hi there! How are you?", peerUserId: 2, peerThreadId: nil, chatId: 1
        ),
        Message(
          messageId: 3, fromId: 1, date: Date().addingTimeInterval(-3_400),
          text: "I'm good! Just checking out the new chat app.", peerUserId: 2, peerThreadId: nil,
          chatId: 1, out: true
        ),

        // Messages in Engineering/General thread
        Message(
          messageId: 1, fromId: 1, date: Date().addingTimeInterval(-7_200),
          text: "Welcome to the Engineering space!", peerUserId: nil, peerThreadId: 3, chatId: 3,
          out: true
        ),
        Message(
          messageId: 2, fromId: 2, date: Date().addingTimeInterval(-7_100),
          text: "Thanks! Excited to be here.", peerUserId: nil, peerThreadId: 3, chatId: 3
        ),
        Message(
          messageId: 3, fromId: 3, date: Date().addingTimeInterval(-7_000),
          text: "Let's build something awesome!", peerUserId: nil, peerThreadId: 3, chatId: 3
        ),
      ]
      try messages.forEach { try $0.save(db) }

      // Create dialogs for quick access
      let dialogs: [Dialog] = [
        // DM dialogs
        Dialog(id: 2, peerUserId: 2, spaceId: nil), // Dialog with Alice
        Dialog(id: 3, peerUserId: 3, spaceId: nil), // Dialog with Bob

        // Thread dialogs
        Dialog(id: -3, peerThreadId: 3, spaceId: 1), // Engineering/General
        Dialog(id: -4, peerThreadId: 4, spaceId: 1), // Engineering/Random
        Dialog(id: -5, peerThreadId: 5, spaceId: 2), // Design/Design System
      ]
      try dialogs.forEach { try $0.save(db) }
    }

    return db
  }
}
