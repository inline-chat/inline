import Foundation
import GRDB
public final class AppDatabase: @unchecked Sendable {
    /// Access to the database.
    public private(set) var dbWriter: any DatabaseWriter

    /// The shared database instance
    public static let shared = AppDatabase()
    
    /// Private initializer to ensure singleton usage
    private init() {
        do {
            dbWriter = try DatabaseQueue()
            // We'll set up the database later when we have a token
        } catch {
            fatalError("Failed to initialize DatabaseQueue: \(error)")
        }
    }
    
    /// Sets up the database
    public func setupDatabase(forceReset: Bool = false) throws {
        guard let token = Auth.shared.getToken() else {
            throw AppDatabaseError.noToken
        }
        
        let fileManager = FileManager.default
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        
        let databaseFolderURL = applicationSupportURL.appendingPathComponent("Database", isDirectory: true)
        let databaseURL = databaseFolderURL.appendingPathComponent("db.sqlite")
        
        try fileManager.createDirectory(at: databaseFolderURL, withIntermediateDirectories: true, attributes: nil)
        
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.removeItem(at: databaseURL)
            print("Existing database deleted due to force reset")
        }
        
        do {
            try fileManager.removeItem(at: databaseURL)
        } catch {
            print("Failed to remove DB \(error)")
        }
        
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(token)
        }
        
        do {
            let dbPool = try DatabasePool(path: databaseURL.path, configuration: config)
            dbWriter = dbPool
            
            // Attempt to read from the database to verify encryption
            do {
                try dbPool.read { db in
                    
                    // ?
                    try db.execute(sql: "SELECT 1")
                }
                print("Database encryption verified successfully")
            } catch {
                print("Error verifying database encryption: \(error)")
                // If verification fails, remove the existing database and create a new one
              
                dbWriter = try DatabasePool(path: databaseURL.path, configuration: config)
                print("Created new database due to encryption verification failure")
            }

            // If we got here, the database is valid and decrypted correctly
            try migrator.migrate(dbWriter)
            print("Database migrations completed successfully")

            print("📁 Database opened and migrated at: \(databaseURL.path)")
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            print("Failed to open database, likely due to encryption mismatch. Creating new database.")
            
            // Remove the existing file and create a new one
            
            let newDbPool = try DatabasePool(path: databaseURL.path, configuration: config)
            dbWriter = newDbPool
            
            // Migrate the new database
            try migrator.migrate(newDbPool)
            
            print("📁 New database created and migrated at: \(databaseURL.path)")
            
            print("📁 Database path: \(databaseURL.path)")

        } catch {
            print("Unexpected error while setting up database: \(error)")
            throw AppDatabaseError.setupFailed(error)
        }
    }

    /// Provides a read-only access to the database.
    public var reader: any DatabaseReader {
        dbWriter
    }
    
    /// Creates an empty in-memory database for SwiftUI previews and testing
    public static func empty() -> AppDatabase {
        let instance = AppDatabase()
        do {
            let dbQueue = try DatabaseQueue()
            instance.dbWriter = dbQueue
            
            // Migrate the in-memory database
            try instance.migrator.migrate(dbQueue)
            
            print("Empty in-memory database created and migrated")
        } catch {
            fatalError("Failed to create empty in-memory database: \(error)")
        }
        return instance
    }
}

extension AppDatabase {
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        
        migrator.registerMigration("addModels") { db in
            try db.create(table: "user") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("email", .text).notNull().unique()
                t.column("firstName", .text).notNull()
                t.column("lastName", .text)
                t.column("createdAt", .datetime).notNull().defaults(to: GRDB.Date.now)
            }
        }
        
        return migrator
    }
}

enum AppDatabaseError: Error {
    case noToken
    case setupFailed(Error)
}
