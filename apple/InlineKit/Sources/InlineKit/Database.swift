import Foundation
import GRDB

// MARK: - DB main class

public final class AppDatabase: Sendable {
  public let dbWriter: any DatabaseWriter
  static let log = Log.scoped("AppDatabase")

  public init(_ dbWriter: any GRDB.DatabaseWriter) throws {
    self.dbWriter = dbWriter
    try migrator.migrate(dbWriter)
  }
}

// MARK: - Migrations

extension AppDatabase {
  public var migrator: DatabaseMigrator {
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
          onDelete: .setNull, onUpdate: .cascade, deferred: true)
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

        t.uniqueKey(["messageId", "chatId"])
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

    return migrator
  }
}

// MARK: - Database Configuration

extension AppDatabase {
  /// - parameter base: A base configuration.
  public static func makeConfiguration(_ base: Configuration = Configuration()) -> Configuration {
    var config = base

    if let token = Auth.shared.getToken() {
      #if DEBUG
        log.debug("Database passphrase: \(token)")
      #endif
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

  public static func authenticated() async throws {
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
      log.warning("AppDatabase.authenticated called without token")
    }
  }

  public static func clearDB() throws {
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

    log.info("Database successfully deleted.")
  }

  public static func loggedOut() throws {
    try clearDB()
  }
}

extension AppDatabase {
  public static func deleteDatabaseFile() throws {
    let fileManager = FileManager.default
    let appSupportURL = try fileManager.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false
    )
    let directoryURL = appSupportURL.appendingPathComponent("Database", isDirectory: true)
    let databaseURL = directoryURL.appendingPathComponent("db.sqlite")

    if fileManager.fileExists(atPath: databaseURL.path) {
      try fileManager.removeItem(at: databaseURL)
      log.info("Database file successfully deleted.")
    } else {
      log.warning("Database file not found.")
    }
  }
}

// MARK: - Database Access: Reads

extension AppDatabase {
  /// Provides a read-only access to the database.
  public var reader: any GRDB.DatabaseReader {
    dbWriter
  }
}

// MARK: - The database for the application

extension AppDatabase {
  /// The database for the application
  public static let shared = makeShared()

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

      var path = databaseURL.path(percentEncoded: false)
      path.replace(" ", with: "\\ ")
      log.debug("Database path: \(path)")
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
      if error.localizedDescription.contains("SQLite error 26") {
        // re-create database and re-run
        do {
          log.info("Re-creating database because token was lost")
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
  public static func empty() -> AppDatabase {
    // Connect to an in-memory database
    // Refrence https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databaseconnections
    let dbQueue = try! DatabaseQueue(configuration: AppDatabase.makeConfiguration())
    return try! AppDatabase(dbQueue)
  }

  public static func emptyWithSpaces() -> AppDatabase {
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

  public static func emptyWithChat() -> AppDatabase {
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
  public static func populated() -> AppDatabase {
    let db = AppDatabase.empty()

    // Populate with test data
    try! db.dbWriter.write { db in
      // Create test users
      let users: [User] = [
        User(
          id: 1, email: "current@example.com", firstName: "Current", lastName: "User",
          username: "current"),
        User(
          id: 2, email: "alice@example.com", firstName: "Alice", lastName: "Smith",
          username: "alice"),
        User(id: 3, email: "bob@example.com", firstName: "Bob", lastName: "Jones", username: "bob"),
        User(
          id: 4, email: "carol@example.com", firstName: "Carol", lastName: "Wilson",
          username: "carol"),
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
          messageId: 1, fromId: 1, date: Date().addingTimeInterval(-3600), text: "Hey Alice!",
          peerUserId: 2, peerThreadId: nil, chatId: 1, out: true),
        Message(
          messageId: 2, fromId: 2, date: Date().addingTimeInterval(-3500),
          text: "Hi there! How are you?", peerUserId: 2, peerThreadId: nil, chatId: 1),
        Message(
          messageId: 3, fromId: 1, date: Date().addingTimeInterval(-3400),
          text: "I'm good! Just checking out the new chat app.", peerUserId: 2, peerThreadId: nil,
          chatId: 1, out: true),

        // Messages in Engineering/General thread
        Message(
          messageId: 1, fromId: 1, date: Date().addingTimeInterval(-7200),
          text: "Welcome to the Engineering space!", peerUserId: nil, peerThreadId: 3, chatId: 3,
          out: true),
        Message(
          messageId: 2, fromId: 2, date: Date().addingTimeInterval(-7100),
          text: "Thanks! Excited to be here.", peerUserId: nil, peerThreadId: 3, chatId: 3),
        Message(
          messageId: 3, fromId: 3, date: Date().addingTimeInterval(-7000),
          text: "Let's build something awesome!", peerUserId: nil, peerThreadId: 3, chatId: 3),
      ]
      try messages.forEach { try $0.save(db) }

      // Create dialogs for quick access
      let dialogs: [Dialog] = [
        // DM dialogs
        Dialog(id: 2, peerUserId: 2, spaceId: nil),  // Dialog with Alice
        Dialog(id: 3, peerUserId: 3, spaceId: nil),  // Dialog with Bob

        // Thread dialogs
        Dialog(id: -3, peerThreadId: 3, spaceId: 1),  // Engineering/General
        Dialog(id: -4, peerThreadId: 4, spaceId: 1),  // Engineering/Random
        Dialog(id: -5, peerThreadId: 5, spaceId: 2),  // Design/Design System
      ]
      try dialogs.forEach { try $0.save(db) }
    }

    return db
  }
}
