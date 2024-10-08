import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
    /// Access to the database.
    public private(set) var dbWriter: any DatabaseWriter

    /// The shared database instance
    public static let shared = AppDatabase()
    
    /// Private initializer to ensure singleton usage
    private init() {
        self.dbWriter = try! DatabaseQueue()
        // TODO: FIXME
        try! migrator.migrate(self.dbWriter)
    }
    
    /// Sets up the database
    /// Summery of functionality:
    /// - We need to create db after saving token, so we create a fake empty db till token is not exist with calling empty() funtion.
    /// - Then after reciving toekn from api result and saving it in Auth class, will call this func to:
    ///     1. Check if any db is exist, delete it and create new one using token
    ///     2. Othervise if it was not created yet, creatre one using token
    public func setupDatabase() throws {
        guard let token = Auth.shared.getToken() else {
            print("No token available. Database will not be created.")
            throw NSError(domain: "AppDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: "No token available"])
        }
            
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = appSupportURL.appendingPathComponent("Database", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            
        let databaseURL = directoryURL.appendingPathComponent("db.sqlite")
        var config = Configuration()
            
        print("Setting up database with token: \(token)")
        config.prepareDatabase { db in
            try db.usePassphrase(token)
        }
            
        do {
            // Try to open existing database
            let dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
            self.dbWriter = dbPool
            print("📁 Existing database opened at: \(databaseURL.path)")
        } catch {
            Log.shared.error("Failed to open existing database", error: error)
            Log.shared.debug("Attempting to create a new database...")

            // If opening fails, remove the existing file and create a new one
            try? fileManager.removeItem(at: databaseURL)
                
            let newDbPool = try DatabasePool(path: databaseURL.path, configuration: config)
            self.dbWriter = newDbPool
            Log.shared.debug("📁 New database created at: \(databaseURL.path)")
        }
            
        // Verify that we can read from the database
        try self.dbWriter.read { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    /// Provides a read-only access to the database.
    public var reader: any GRDB.DatabaseReader {
        return self.dbWriter
    }
    
    /// Creates an empty in-memory database for SwiftUI previews and testing
    public static func empty() -> AppDatabase {
        let instance = AppDatabase()
        do {
            let dbQueue = try DatabaseQueue()
            instance.dbWriter = dbQueue
        
            Log.shared.debug("Empty in-memory database created")

        } catch {
            Log.shared.error("Failed to create empty in-memory database", error: error)
        }
        return instance
    }
}

extension AppDatabase {
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
#if DEBUG
        // Speed up development by nuking the database when migrations change
        // See <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/migrations>
        migrator.eraseDatabaseOnSchemaChange = true
#endif
        migrator.registerMigration("addModels") { db in
            try db.create(table: "user") { t in
                t.primaryKey("id", .integer).notNull()
                t.column("email", .text).notNull()
                t.column("firstName", .text).notNull()
                t.column("lastName", .text)
                t.column("createdAt", .date)
            }
        }
        return migrator
    }
}
