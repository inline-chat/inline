import Foundation
import GRDB

// MARK: - DB main class

public final class AppDatabase: Sendable {
  public let dbWriter: any DatabaseWriter

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
      // Speed up development by nuking the database when migrations change
      // See <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/migrations#The-eraseDatabaseOnSchemaChange-Option>
      migrator.eraseDatabaseOnSchemaChange = true
    #endif

    migrator.registerMigration("v0") { db in
      try db.create(table: "user") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("email", .text)
        t.column("firstName", .text)
        t.column("lastName", .text)
        t.column("username", .text)
        t.column("date", .datetime).notNull()
      }
    }

    // Migrations for future application versions will be inserted here:
    migrator.registerMigration("Space flow") { db in

      try db.create(table: "space") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("name", .text).notNull()
        t.column("date", .datetime).notNull()
      }

      try db.create(table: "member") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("userId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("spaceId", .integer).references("space", column: "id", onDelete: .setNull)
        t.column("date", .datetime).notNull()
        t.column("role", .text).notNull()

        t.uniqueKey(["userId", "spaceId"])
      }
    }

    migrator.registerMigration("Chat flow 2") { db in
      try db.create(table: "chat") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("spaceId", .integer).references("space", column: "id", onDelete: .cascade)
        t.column("peerUserId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("title", .text)
        t.column("type", .integer).notNull().defaults(to: 0)
        t.column("date", .datetime).notNull()
        t.column("lastMessageId", .integer).references("message", column: "id", onDelete: .cascade)
      }

      try db.create(table: "message") { t in
        t.autoIncrementedPrimaryKey("id").notNull().unique()
        t.column("messageId", .integer).notNull()
        t.column("chatId", .integer).references("chat", column: "id", onDelete: .cascade)
        t.column("fromId", .integer).references("user", column: "id", onDelete: .setNull)
        t.column("date", .datetime).notNull()
        t.column("text", .text)
        t.column("editDate", .datetime)

        t.uniqueKey(["messageId", "chatId"])
      }
    }

    migrator.registerMigration("space creator") { db in
      try db.alter(table: "space") { t in
        t.add(column: "creator", .boolean)
      }
    }

    migrator.registerMigration("dialog") { db in
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

      // Add new columns
      try db.alter(table: "message") { t in
        t.add(column: "peerUserId", .integer).references("user", column: "id", onDelete: .setNull)
        t.add(column: "peerThreadId", .integer).references("chat", column: "id", onDelete: .setNull)
        t.add(column: "mentioned", .boolean)
        t.add(column: "out", .boolean)
        t.add(column: "pinned", .boolean)
      }

      // Migrate existing data: copy chatId to peerThreadId
      try db.execute(
        sql: """
            UPDATE message 
            SET peerThreadId = chatId 
            WHERE chatId IS NOT NULL
        """)
    }

    migrator.registerMigration("fix last message") { db in

      try db.alter(table: "chat") { t in
        t.rename(column: "lastMessageId", to: "lastMsgId")
      }
    }

    return migrator
  }
}

// MARK: - Database Configuration

public extension AppDatabase {
  /// - parameter base: A base configuration.
  static func makeConfiguration(_ base: Configuration = Configuration()) -> Configuration {
    var config = base
    print("makeConfiguration called")

    if let token = Auth.shared.getToken() {
      print("Token in makeConfiguration \(token)")
      config.prepareDatabase { db in
        try db.usePassphrase(token)
      }
    } else {
      config.prepareDatabase { db in
        try db.usePassphrase("123")
      }
    }
    return config
  }

  static func authenticated() async throws {
    if let token = Auth.shared.getToken() {
      try await AppDatabase.shared.dbWriter.barrierWriteWithoutTransaction { db in
        try db.changePassphrase(token)
        try db.usePassphrase(token)
        // Needed for stupid swift. actually smart. ew.
        if let db = AppDatabase.shared.dbWriter as? DatabasePool {
          print("invalidateReadOnlyConnections")
          db.invalidateReadOnlyConnections()
        }
      }
    } else {
      Log.shared.warning("AppDatabase.authenticated called without token")
    }
  }

  static func clearDB() throws {
    _ = try AppDatabase.shared.dbWriter.write { db in
      try User.deleteAll(db)
      try Chat.deleteAll(db)
      try Message.deleteAll(db)
      try Space.deleteAll(db)
    }

    // Optionally, delete the database file
    // Uncomment the next line if you want to delete the file
    // try deleteDatabaseFile()

    // Reset the database passphrase to a default value
    try AppDatabase.shared.dbWriter.write { db in
      try db.changePassphrase("123")
    }

    Log.shared.info("Database successfully deleted.")
  }

  static func loggedOut() throws {
    try clearDB()
  }
}

public extension AppDatabase {
  static func deleteDatabaseFile() throws {
    let fileManager = FileManager.default
    let appSupportURL = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false
    )
    let directoryURL = appSupportURL.appendingPathComponent("Database", isDirectory: true)
    let databaseURL = directoryURL.appendingPathComponent("db.sqlite")

    if fileManager.fileExists(atPath: databaseURL.path) {
      try fileManager.removeItem(at: databaseURL)
      Log.shared.info("Database file successfully deleted.")
    } else {
      Log.shared.warning("Database file not found.")
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

  private static func makeShared() -> AppDatabase {
    do {
      // Create the "Application Support/Database" directory if needed
      let fileManager = FileManager.default
      let appSupportURL = try fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
      let directoryURL = appSupportURL.appendingPathComponent("Database", isDirectory: true)
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

      // Open or create the database
      //            #if DEBUG
      //            let databaseURL = directoryURL.appendingPathComponent("db_dev.sqlite")
      //            #else
      let databaseURL = directoryURL.appendingPathComponent("db.sqlite")
      //            #endif

      let config = AppDatabase.makeConfiguration()
      let dbPool = try DatabaseQueue(path: databaseURL.path, configuration: config)
      // Crashed iOS
      //            let dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
      print("DB created in \(databaseURL) ")
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
      print("Unresolved error \(error)")

      // handle db password issue and create a new one
      if error.localizedDescription.contains("SQLite error 26") {
        // re-create database and re-run
        do {
          print("Re-creating database because token was lost")
          try AppDatabase.deleteDatabaseFile()
          return AppDatabase.makeShared()
        } catch {
          fatalError("Unresolved error \(error)")
        }
      } else {
        fatalError("Unresolved error \(error)")
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
        let chat = Chat(id: 1234, date: Date.now, type: .thread, title: "Main", spaceId: nil)

        try chat.insert(db)
      }
    } catch {}
    return db
  }

  /// Used for previews
  static func populated() -> AppDatabase {
    let db = AppDatabase.empty()
    do {
      try db.dbWriter.write { db in
        // Add current user
        let user = User(id: 1, email: "mo@inline.chat", firstName: "Mohamed", username: "mo")
        try user.save(db)

        // Add spaces
        let space1 = Space(id: 1, name: "Space 1 with data", date: Date.now)
        let space2 = Space(id: 2, name: "Space 2", date: Date.now)
        let space3 = Space(id: 3, name: "Space 3", date: Date.now)
        try space1.insert(db)
        try space2.insert(db)
        try space3.insert(db)

        // Add chats to space 1
        let chat = Chat(id: 1, date: Date.now, type: .thread, title: "Main", spaceId: 1)
        try chat.insert(db)
      }
    } catch {}
    return db
  }
}
