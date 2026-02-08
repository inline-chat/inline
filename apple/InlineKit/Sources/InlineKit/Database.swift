import Auth
import Foundation
import GRDB
import InlineConfig
import Logger

// MARK: - DB main class

public final class AppDatabase: @unchecked Sendable {
  private let writerLock = NSLock()
  private var _dbWriter: any DatabaseWriter
#if DEBUG
  private static let warnLock = NSLock()
  nonisolated(unsafe) private static var warnedInMemoryObservationSites: Set<String> = []
#endif

  public var dbWriter: any DatabaseWriter {
    writerLock.withLock { _dbWriter }
  }

  public var isPersistent: Bool {
    dbWriter is DatabasePool
  }

#if DEBUG
  /// Debug helper to detect GRDB observations being created while `AppDatabase` is using the
  /// in-memory fallback. Observations capture the provided reader/writer; if they bind to the
  /// in-memory DB before promotion, they will not automatically "follow" the promoted DB.
  ///
  /// Call this immediately before creating a `ValueObservation.publisher(in:)` / `.start(in:)`.
  public func warnIfInMemoryDatabaseForObservation(
    _ context: StaticString,
    file: StaticString = #fileID,
    line: UInt = #line
  ) {
    guard isPersistent == false else { return }
    guard dbWriter is DatabaseQueue else { return }

    let key = "\(file):\(line):\(context)"
    let shouldLog = Self.warnLock.withLock {
      if Self.warnedInMemoryObservationSites.contains(key) { return false }
      Self.warnedInMemoryObservationSites.insert(key)
      return true
    }
    guard shouldLog else { return }

    let stack = Thread.callStackSymbols.prefix(18).joined(separator: "\n")
    AppDatabase.log.warning(
      "DB_INMEMORY_OBSERVATION context=\(context) site=\(file):\(line)\n\(stack)"
    )
  }
#endif
  static let log = Log.scoped(
    "AppDatabase",
    // Enable tracing for seeing all SQL statements
    enableTracing: false
  )

  public init(_ dbWriter: any GRDB.DatabaseWriter) throws {
    _dbWriter = dbWriter
    try migrator.migrate(dbWriter)
  }

  internal func swapWriter(_ newWriter: any DatabaseWriter) {
    writerLock.withLock { _dbWriter = newWriter }
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

    migrator.registerMigration("dialog chat id") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "chatId", .integer).references("chat", column: "id", onDelete: .setNull)
      }
    }

    migrator.registerMigration("user photo field") { db in
      try db.alter(table: "user") { t in
        t.add(column: "profileCdnUrl", .text)
        t.add(column: "profileLocalPath", .text)
      }
    }

    migrator.registerMigration("entities") { db in
      try db.alter(table: "message") { t in
        t.add(column: "entities", .blob)
      }
    }

    migrator.registerMigration("draft message") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "draftMessage", .blob)
      }
      try db.alter(table: "dialog") { t in
        t.drop(column: "draft")
      }
    }

    migrator.registerMigration("translation entities") { db in
      try db.alter(table: "translation") { t in
        t.add(column: "entities", .blob)
      }
    }

    migrator.registerMigration("pts tracking") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "pts", .integer)
      }

      try db.alter(table: "space") { t in
        t.add(column: "pts", .integer)
      }
    }

    migrator.registerMigration("drop pts tracking in model tables") { db in
      try db.alter(table: "dialog") { t in
        t.drop(column: "pts")
      }

      try db.alter(table: "space") { t in
        t.drop(column: "pts")
      }
    }

    migrator.registerMigration("dialog unread mark") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "unreadMark", .boolean)
      }
    }

    migrator.registerMigration("user profile file unique id") { db in
      try db.alter(table: "user") { t in
        t.add(column: "profileFileUniqueId", .text)
      }
    }

    migrator.registerMigration("sync_v1") { db in
      // Table to store the state of each sync bucket (chat, space, user)
      try db.create(table: "sync_bucket_state") { t in
        // Composite primary key: bucketType + entityId
        t.column("bucketType", .integer).notNull() // 1=chat, 2=user, 3=space
        t.column("entityId", .integer).notNull() // Chat ID, Space ID, or 0 for user
        t.column("seq", .integer).notNull() // Last synced sequence number
        t.column("date", .integer).notNull() // Last synced date

        t.primaryKey(["bucketType", "entityId"])
      }

      // Table to store global sync state (e.g., last overall sync date)
      try db.create(table: "sync_global_state") { t in
        t.primaryKey("id", .integer).notNull().unique() // Always 1
        t.column("lastSyncDate", .integer).notNull()
      }
    }

    migrator.registerMigration("member public access") { db in
      try db.alter(table: "member") { t in
        t.add(column: "canAccessPublicChats", .boolean).notNull().defaults(to: true)
      }
    }

    migrator.registerMigration("chat message list indexes") { db in
      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS message_peerThread_date_idx
        ON message(peerThreadId, date DESC)
        WHERE peerThreadId IS NOT NULL
        """
      )

      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS message_peerUser_date_idx
        ON message(peerUserId, date DESC)
        WHERE peerUserId IS NOT NULL
        """
      )

      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS attachment_messageId_idx
        ON attachment(messageId)
        """
      )

      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS photoSize_photoId_idx
        ON photoSize(photoId)
        """
      )

      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS file_profileForUserId_idx
        ON file(profileForUserId)
        """
      )

      try db.execute(sql: "ANALYZE")
      try db.execute(sql: "PRAGMA optimize")
    }

    migrator.registerMigration("chat message prefetch indexes") { db in
      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS message_chat_message_idx
        ON message(chatId, messageId)
        """
      )

      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS attachment_messageId_notnull_idx
        ON attachment(messageId)
        WHERE messageId IS NOT NULL
        """
      )

      try db.execute(
        sql: """
        CREATE INDEX IF NOT EXISTS file_profileForUserId_notnull_idx
        ON file(profileForUserId)
        WHERE profileForUserId IS NOT NULL
        """
      )

      try db.execute(sql: "ANALYZE")
      try db.execute(sql: "PRAGMA optimize")
    }

    migrator.registerMigration("message forward header") { db in
      try db.alter(table: "message") { t in
        t.add(column: "forwardFromPeerUserId", .integer)
        t.add(column: "forwardFromPeerThreadId", .integer)
        t.add(column: "forwardFromMessageId", .integer)
        t.add(column: "forwardFromUserId", .integer)
      }
    }

    migrator.registerMigration("message has link") { db in
      try db.alter(table: "message") { t in
        t.add(column: "hasLink", .boolean)
      }
    }

    migrator.registerMigration("pinned messages") { db in
      try db.create(table: "pinnedMessage") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("chatId", .integer).notNull().references("chat", column: "id", onDelete: .cascade)
        t.column("messageId", .integer).notNull()
        t.column("position", .integer).notNull()
        t.uniqueKey(["chatId", "messageId"], onConflict: .replace)
      }

      try db.create(
        index: "pinned_message_chat_position_idx",
        on: "pinnedMessage",
        columns: ["chatId", "position"]
      )
    }

    migrator.registerMigration("chat created by") { db in
      try db.alter(table: "chat") { t in
        t.add(column: "createdBy", .integer).references("user", column: "id", onDelete: .setNull)
      }
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
    // Default configuration: prefer the stable database key if available; fall back to legacy "123".
    let passphrase: String = switch DatabaseKeyStore.load() {
    case .available(let key):
      key
    default:
      "123"
    }
    return makeConfiguration(passphrase: passphrase, base)
  }

  static func makeConfiguration(passphrase: String, _ base: Configuration = Configuration()) -> Configuration {
    var config = base

    config.prepareDatabase { db in
      db.trace(options: .statement) { log.trace($0.expandedDescription) }
      try db.usePassphrase(passphrase)
    }

    return config
  }

  static func authenticated() async throws {
    switch DatabaseKeyStore.getOrCreate() {
    case .available(let key):
      try AppDatabase.changePassphrase(key)
    case .locked:
      log.warning("AppDatabase.authenticated called while keychain is locked")
    case .notFound:
      log.warning("AppDatabase.authenticated called without database key")
    case .error(let status):
      log.error("AppDatabase.authenticated failed to get database key status=\(status)")
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
    switch DatabaseKeyStore.getOrCreate() {
    case .available(let key):
      try AppDatabase.changePassphrase(key)
    default:
      try AppDatabase.changePassphrase("123")
    }
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
    let databaseUrl = getDatabaseUrl()
    let databasePath = databaseUrl.path
    let fileManager = FileManager.default
    let fileExists = fileManager.fileExists(atPath: databasePath)

    var pathForLog = databasePath
    pathForLog.replace(" ", with: "\\ ")
    log.debug("Database path: \(pathForLog)")

    func openPersistent(passphrase: String) throws -> (db: AppDatabase, pool: DatabasePool) {
      let config = AppDatabase.makeConfiguration(passphrase: passphrase)
      let pool = try DatabasePool(path: databasePath, configuration: config)
      let db = try AppDatabase(pool)
      return (db: db, pool: pool)
    }

    func openInMemory() -> AppDatabase {
      do {
        // Prefer dbKey if available; fall back to legacy.
        let passphrase: String = switch DatabaseKeyStore.load() {
        case .available(let key):
          key
        default:
          "123"
        }
        let dbQueue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: passphrase))
        return try AppDatabase(dbQueue)
      } catch {
        // At this point we have no choice but to crash
        fatalError("Completely unable to initialize in-memory database: \(error)")
      }
    }

    func rotatePassphrase(pool: DatabasePool, to newPassphrase: String) throws {
      try pool.barrierWriteWithoutTransaction { db in
        try db.changePassphrase(newPassphrase)
        pool.invalidateReadOnlyConnections()
      }
    }

    // If the database file doesn't exist yet, only create it when the keychain is available.
    if fileExists == false {
      switch DatabaseKeyStore.getOrCreate() {
      case .available(let key):
        do {
          return try openPersistent(passphrase: key).db
        } catch {
          log.error("Failed to create persistent database with dbKey; using in-memory", error: error)
          return openInMemory()
        }
      case .locked:
        log.warning("Keychain locked; using in-memory database until credentials are available")
        return openInMemory()
      case .notFound, .error:
        log.warning("No database key available; using in-memory database")
        return openInMemory()
      }
    }

    let dbKey: String? = switch DatabaseKeyStore.load() {
    case .available(let key):
      key
    default:
      nil
    }

    let token = Auth.shared.getToken()

    var candidates: [(label: String, passphrase: String)] = []
    if let dbKey { candidates.append((label: "dbKey", passphrase: dbKey)) }
    if let token, token != dbKey { candidates.append((label: "token", passphrase: token)) }
    candidates.append((label: "legacy123", passphrase: "123"))

    var lastError: (any Error)?

    for candidate in candidates {
      do {
        let opened = try openPersistent(passphrase: candidate.passphrase)

        // Migrate legacy DB encryption (token / "123") to dbKey once we can.
        if candidate.label != "dbKey" {
          switch DatabaseKeyStore.getOrCreate() {
          case .available(let newKey) where newKey != candidate.passphrase:
            do {
              try rotatePassphrase(pool: opened.pool, to: newKey)
              // Drop the old pool (wrong config) and reopen with the new key.
              return try openPersistent(passphrase: newKey).db
            } catch {
              log.error("Failed to rotate DB passphrase to dbKey; continuing with legacy key", error: error)
            }
          default:
            break
          }
        }

        return opened.db
      } catch {
        lastError = error
        continue
      }
    }

    // IMPORTANT: Do not delete the database file here.
    // A transient keychain failure (or auth token unavailable at launch) must not cause data loss.
    if let lastError {
      log.error("Failed to open persistent database; using in-memory fallback", error: lastError)
    } else {
      log.error("Failed to open persistent database; using in-memory fallback")
    }
    return openInMemory()
  }

  /// If `AppDatabase.shared` was initialized while the keychain was unavailable (common on iOS before
  /// first unlock), it may have fallen back to an in-memory database. This method attempts to reopen
  /// the persistent database and swap `shared`'s writer in-place so callers that hold on to the
  /// `AppDatabase` instance can recover without a process restart.
  ///
  /// Note: any observers that captured the old `DatabaseReader`/`DatabaseWriter` instance directly
  /// (e.g. GRDB `ValueObservation.publisher(in:)`) must be created *after* this promotion runs.
  @discardableResult
  static func promoteSharedToPersistentIfPossible() async -> Bool {
    // Already persistent.
    if shared.dbWriter is DatabasePool {
      return false
    }

    let newWriter: (any DatabaseWriter)? = await Task.detached(priority: .userInitiated) {
      let reopened = makeShared()
      guard reopened.dbWriter is DatabasePool else {
        return nil
      }
      return reopened.dbWriter
    }.value

    guard let newWriter else {
      return false
    }

    shared.swapWriter(newWriter)
    log.info("Promoted in-memory database to persistent database writer")
    return true
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
