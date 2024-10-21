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

        migrator.registerMigration("v0") { db in
            try db.create(table: "user") { t in
                t.primaryKey("id", .integer).notNull().unique()
                t.column("email", .text).notNull()
                t.column("firstName", .text).notNull()
                t.column("lastName", .text)
                t.column("date", .datetime).notNull().defaults(to: GRDB.Date.now)
            }
        }

        // Migrations for future application versions will be inserted here:
        migrator.registerMigration("Space flow") { db in

            try db.create(table: "space") { t in
                t.primaryKey("id", .integer).notNull().unique()
                t.column("name", .text).notNull()
                t.column("date", .datetime).notNull().defaults(to: GRDB.Date.now)
            }

            try db.create(table: "member") { t in
                t.primaryKey("id", .integer).notNull().unique()
                t.column("userId", .integer).references("user", column: "id", onDelete: .setNull)
                t.column("spaceId", .integer).references("space", column: "id", onDelete: .setNull)
                t.column("date", .datetime).notNull().defaults(to: GRDB.Date.now)
                t.column("role", .text).notNull().defaults(to: "member")

                t.uniqueKey(["userId", "spaceId"])
            }
        }

        migrator.registerMigration("Chat flow") { db in
            try db.create(table: "chat") { t in
                t.primaryKey("id", .integer).notNull().unique()
                t.column("spaceId", .integer).references("space", column: "id", onDelete: .cascade)
                t.column("peerUserId", .integer).references("user", column: "id", onDelete: .setNull)
                t.column("title", .text)
                t.column("type", .integer).notNull().defaults(to: 0)
                t.column("date", .datetime).notNull().defaults(to: GRDB.Date.now)
            }

            try db.create(table: "message") { t in
                t.primaryKey("id", .integer).notNull().unique()
                t.column("chatId", .integer).references("chat", column: "id", onDelete: .cascade)
                t.column("fromId", .integer).references("user", column: "id", onDelete: .setNull)
                t.column("date", .datetime).notNull()
                t.column("text", .text)
                t.column("editDate", .datetime)
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

        if let token = Auth.shared.getToken() {
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

    static func authenticated() throws {
        if let token = Auth.shared.getToken() {
            try AppDatabase.shared.dbWriter.barrierWriteWithoutTransaction { db in
                try db.changePassphrase(token)
                // maybe dbPool.invalidateReadOnlyConnections()???
            }
        } else {
            Log.shared.warning("AppDatabase.authenticated called without token")
        }
    }

    static func clearDB() throws {
        _ = try AppDatabase.shared.dbWriter.write { db in
            try User.deleteAll(db)
        }
        Log.shared.info("Database successfully deleted.")
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
            let databaseURL = directoryURL.appendingPathComponent("db.sqlite")
            let config = AppDatabase.makeConfiguration()
            let dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
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
            fatalError("Unresolved error \(error)")
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
}
