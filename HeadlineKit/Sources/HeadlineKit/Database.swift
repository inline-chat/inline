import Foundation
import GRDB
import os.log

public final class AppDatabase: Sendable {
    /// Access to the database.
    private let dbWriter: any DatabaseWriter

    /// Creates a `AppDatabase`, and makes sure the database schema
    /// is ready.
    ///
    /// - important: Create the `DatabaseWriter` with a configuration
    ///   returned by ``makeConfiguration(_:)``.
    public init(_ dbWriter: any GRDB.DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }

    /// The DatabaseMigrator that defines the database schema.
    ///
    /// See <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/migrations>
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
            // Speed up development by nuking the database when migrations change
            // See <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/migrations#The-eraseDatabaseOnSchemaChange-Option>
            migrator.eraseDatabaseOnSchemaChange = true
        #endif

        // Migrations for future application versions will be inserted here:
        // migrator.registerMigration(...) { db in
        //     ...
        // }

        return migrator
    }
}

// MARK: - Database Configuration

public extension AppDatabase {
    // Uncomment for enabling SQL logging
    // private static let sqlLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SQL")

    /// Returns a database configuration suited for `AppDatabase`.
    ///
    /// SQL statements are logged if the `SQL_TRACE` environment variable
    /// is set.
    ///
    /// - parameter base: A base configuration.
    static func makeConfiguration(_ base: Configuration = Configuration()) -> Configuration {
        var config = base

        return config
    }
}

// MARK: - Database Access: Reads

public extension AppDatabase {
    /// Provides a read-only access to the database.
    var reader: any GRDB.DatabaseReader {
        dbWriter
    }
}

public extension AppDatabase {
    /// The database for the application
    static let shared = makeShared()

    private static func makeShared() -> AppDatabase {
        do {
            if let token = CurrentDataModel.shared.token {
                print("Token is exist for \(token).")
       
                return try setup(token: token)
            } else {
                print("Waiting for logging in...")
                return AppDatabase.empty()
            }
        } catch {
            print("Error setting up database: \(error.localizedDescription)")
            return AppDatabase.empty()
        }
    }

    private static func setup(token: String) throws -> AppDatabase {
        // Apply recommendations from
        // <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databaseconnections>
        print("Setup called")
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directoryURL = appSupportURL.appendingPathComponent("Database", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let databaseURL = directoryURL.appendingPathComponent("db.sqlite")
        var config = AppDatabase.makeConfiguration()

        // encryption
        config.prepareDatabase { db in
            try db.usePassphrase(token)
        }

        let dbPool = try DatabasePool(path: databaseURL.path, configuration: config)

        return try AppDatabase(dbPool)
    }

    /// Creates an empty database for SwiftUI previews
    static func empty() -> AppDatabase {
        // Connect to an in-memory database
        // See https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databaseconnections

        let dbQueue = try! DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        return try! AppDatabase(dbQueue)
    }
}
