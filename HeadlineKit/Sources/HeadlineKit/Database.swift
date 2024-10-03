import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
    /// Access to the database.
    private var dbWriter: (any DatabaseWriter)?
    
    /// The shared database instance
    public static let shared = AppDatabase()
    
    /// Private initializer to ensure singleton usage
    private init() {}
    
    /// Sets up the database
    /// Summery of functionality:
    /// - We need to create db after saving token, so we create a fake empty db till token is not exist with calling empty() funtion.
    /// - Then after reciving toekn from api result and saving it in CurrentData class, will call this func to:
    ///     1. Check if any db is exist, delete it and create new one using token
    ///     2. Othervise if it was not created yet, creatre one using token
    public func setupDatabase() throws {
        guard let token = CurrentDataModel.shared.token else {
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
            print("Failed to open existing database: \(error)")
            print("Attempting to create a new database...")
                
            // If opening fails, remove the existing file and create a new one
            try? fileManager.removeItem(at: databaseURL)
                
            let newDbPool = try DatabasePool(path: databaseURL.path, configuration: config)
            self.dbWriter = newDbPool
            print("📁 New database created at: \(databaseURL.path)")
        }
            
        // Verify that we can read from the database
        try self.dbWriter?.read { db in
            try db.execute(sql: "SELECT 1")
        }
    }

    /// Provides a read-only access to the database.
    public var reader: any GRDB.DatabaseReader {
        guard let dbWriter = dbWriter else {
            fatalError("Database has not been set up. Call setupDatabase() first.")
        }
        return dbWriter
    }
    
    /// Creates an empty in-memory database for SwiftUI previews and testing
    public static func empty() -> AppDatabase {
        let instance = AppDatabase()
        do {
            let dbQueue = try DatabaseQueue()
            instance.dbWriter = dbQueue
            print("Empty in-memory database created")
        } catch {
            print("Failed to create empty in-memory database: \(error)")
        }
        return instance
    }
}
