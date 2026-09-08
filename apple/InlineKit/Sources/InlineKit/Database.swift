@_spi(LogoutCoordinator) import Auth
import Foundation
import GRDB
import InlineConfig
import Logger
import Sentry

enum DatabaseCredentialPreparationError: Error, Equatable, PrivacySafeErrorCategoryProviding {
  case keychainLocked
  case keyUnavailable
  case keychainFailure(Int32)
  case persistentDatabaseUnavailable

  var privacySafeErrorCategory: String {
    switch self {
    case .keychainLocked: "database_credentials:keychain_locked"
    case .keyUnavailable: "database_credentials:key_unavailable"
    case .keychainFailure: "database_credentials:keychain_failure"
    case .persistentDatabaseUnavailable: "database_credentials:persistent_unavailable"
    }
  }
}

public enum PersistentStoreOpenFailureReason: String, Sendable, Equatable {
  case keychainLocked = "keychain_locked"
  case keyUnavailable = "key_unavailable"
  case keychainFailure = "keychain_failure"
  case databaseBusy = "database_busy"
  case databaseLocked = "database_locked"
  case databaseFull = "database_full"
  case databaseReadOnly = "database_read_only"
  case databaseCannotOpen = "database_cannot_open"
  case databaseIO = "database_io"
  case databaseUnreadable = "database_unreadable"
  case migration = "migration"
  case unknown = "unknown"
}

public struct PersistentStoreOpenFailure: Error, Sendable, Equatable, PrivacySafeErrorCategoryProviding {
  public enum Disposition: String, Sendable, Equatable {
    case retryable
    case terminal
  }

  public let reason: PersistentStoreOpenFailureReason
  public let disposition: Disposition
  public let sqliteCode: Int32?
  public let sqliteExtendedCode: Int32?

  public var privacySafeErrorCategory: String {
    "database_open:\(reason.rawValue)"
  }
}

public enum PersistentStoreAdmission: Sendable, Equatable {
  case ready
  case retryable(PersistentStoreOpenFailure)
  case terminal(PersistentStoreOpenFailure)
}

private enum PersistentStoreStartupDiagnostics {
  private static let slowOpenThresholdMs = 5_000
  private static let reportLock = NSLock()
  nonisolated(unsafe) private static var reportedEvents: Set<String> = []
  nonisolated(unsafe) private static var startupAttemptCount = 0

  static func report(
    admission: PersistentStoreAdmission,
    durationMs: Int,
    fileExistedAtStart: Bool,
    candidateAttempts: Int,
    lastCandidateLabel: String
  ) {
    guard SentrySDK.isEnabled else { return }
    let startupAttempt = reportLock.withLock {
      startupAttemptCount += 1
      return startupAttemptCount
    }

    let state: String
    let failure: PersistentStoreOpenFailure?
    switch admission {
    case .ready:
      state = "ready"
      failure = nil
    case .retryable(let value):
      state = "retryable"
      failure = value
    case .terminal(let value):
      state = "terminal"
      failure = value
    }

    let breadcrumb = Breadcrumb(
      level: failure == nil ? .info : .warning,
      category: "storage.admission"
    )
    breadcrumb.message = "persistent_store_admission"
    breadcrumb.data = [
      "duration_ms": durationMs,
      "file_existed": fileExistedAtStart,
      "persistent": failure == nil,
      "attempts": candidateAttempts,
      "retry_count": max(0, startupAttempt - 1),
    ]
    SentrySDK.addBreadcrumb(breadcrumb)

    let event: String?
    if state == "terminal" {
      event = "apple_persistent_store_unavailable"
    } else if durationMs >= slowOpenThresholdMs {
      event = "apple_persistent_store_open_slow"
    } else {
      event = nil
    }
    guard let event else { return }

    let reason = failure?.reason.rawValue ?? "none"
    let eventKey = "\(event):\(state):\(reason)"
    let shouldReport = reportLock.withLock { reportedEvents.insert(eventKey).inserted }
    guard shouldReport else { return }

    _ = SentrySDK.capture(message: event) { scope in
      scope.setLevel(state == "terminal" ? .error : .warning)
      scope.setFingerprint([event, state, reason])
      scope.clearBreadcrumbs()
      scope.setTag(value: event, key: "event")
      scope.setTag(value: "PersistentStoreStartup", key: "scope")
      scope.setTag(value: state, key: "storage.admission")
      scope.setTag(value: reason, key: "storage.failure_reason")
      scope.setTag(value: fileExistedAtStart ? "true" : "false", key: "storage.file_existed")
      scope.setTag(value: lastCandidateLabel, key: "storage.last_candidate")
      scope.setExtra(value: durationMs, key: "storage.duration_ms")
      scope.setExtra(value: candidateAttempts, key: "storage.candidate_attempts")
      scope.setExtra(value: max(0, startupAttempt - 1), key: "storage.retry_count")
      if let sqliteCode = failure?.sqliteCode {
        scope.setExtra(value: sqliteCode, key: "storage.sqlite_code")
      }
      if let sqliteExtendedCode = failure?.sqliteExtendedCode {
        scope.setExtra(value: sqliteExtendedCode, key: "storage.sqlite_extended_code")
      }
    }
  }
}

// MARK: - DB main class

public final class AppDatabase: @unchecked Sendable {
  private let writerLock = NSLock()
  public let translationPreferences = DialogTranslationPreferences()
  private var _dbWriter: any DatabaseWriter
  private var preparedDatabaseKey: String?
  private var persistentOpenFailure: PersistentStoreOpenFailure?
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

  public var persistentStoreAdmission: PersistentStoreAdmission {
    writerLock.withLock {
      if _dbWriter is DatabasePool {
        return .ready
      }
      let failure = persistentOpenFailure ?? PersistentStoreOpenFailure(
        reason: .unknown,
        disposition: .terminal,
        sqliteCode: nil,
        sqliteExtendedCode: nil
      )
      switch failure.disposition {
      case .retryable:
        return .retryable(failure)
      case .terminal:
        return .terminal(failure)
      }
    }
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
#else
  @inlinable
  public func warnIfInMemoryDatabaseForObservation(
    _ context: StaticString,
    file: StaticString = #fileID,
    line: UInt = #line
  ) {
    // Debug-only logging; intentionally a no-op in Release.
    _ = context
    _ = file
    _ = line
  }
#endif
  static let log = Log.scoped(
    "AppDatabase",
    // Enable tracing for seeing all SQL statements
    enableTracing: false
  )

  public init(_ dbWriter: any GRDB.DatabaseWriter) throws {
    _dbWriter = dbWriter
    preparedDatabaseKey = nil
    persistentOpenFailure = nil
    let span = PerformanceTrace.begin("DatabaseMigrate", category: .launch)
    defer { span.end() }
    try migrator.migrate(dbWriter)
    try translationPreferences.observe(dbWriter)
  }

  internal func swapWriter(_ newWriter: any DatabaseWriter) {
    do {
      try translationPreferences.observe(newWriter)
    } catch {
      Self.log.error("Failed to initialize translation preferences", error: error)
    }
    writerLock.withLock {
      _dbWriter = newWriter
      preparedDatabaseKey = nil
      persistentOpenFailure = nil
    }
  }

  internal func recordPersistentOpenFailure(_ failure: PersistentStoreOpenFailure) {
    writerLock.withLock {
      persistentOpenFailure = failure
    }
  }

  internal func isCredentialStoragePrepared(for key: String) -> Bool {
    writerLock.withLock { preparedDatabaseKey == key }
  }

  internal func markCredentialStoragePrepared(for key: String?) {
    writerLock.withLock { preparedDatabaseKey = key }
  }

  /// Closes the on-disk pool after its admitted work completes.
  /// The promotable in-memory fallback is process-local and intentionally remains open.
  public func closePersistentStorage() throws {
    guard let databasePool = dbWriter as? DatabasePool else { return }
    try databasePool.close()
  }

  /// Waits for already-admitted reads and writes without invalidating the shared process owner.
  public func waitForPendingOperationsForTermination() async throws {
    try await dbWriter.barrierWriteWithoutTransaction { _ in () }
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

    migrator.registerMigration("user bot") { db in
      try db.alter(table: "user") { t in
        t.add(column: "bot", .boolean).notNull().defaults(to: false)
      }
    }

    migrator.registerMigration("dialog notification settings") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "notificationSettings", .blob)
      }
    }

    migrator.registerMigration("message content payload") { db in
      try db.alter(table: "message") { t in
        t.add(column: "contentPayload", .blob)
      }
    }

    migrator.registerMigration("reserved chat ids") { db in
      try db.create(table: "reservedChatId") { t in
        t.primaryKey("chatId", .integer).notNull().unique()
        t.column("expiresAt", .datetime).notNull()
        t.column("createdAt", .datetime).notNull()
      }

      try db.alter(table: "chat") { t in
        t.add(column: "createState", .text)
      }
    }

    migrator.registerMigration("chat parent threading metadata") { db in
      try db.alter(table: "chat") { t in
        t.add(column: "parentChatId", .integer).references("chat", column: "id", onDelete: .setNull)
        t.add(column: "parentMessageId", .integer)
      }
    }

    migrator.registerMigration("dialog sidebar visible") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "sidebarVisible", .boolean)
      }
    }

    migrator.registerMigration("message and translation rev") { db in
      try db.alter(table: "message") { t in
        t.add(column: "rev", .integer).notNull().defaults(to: 0)
      }

      try db.alter(table: "translation") { t in
        t.add(column: "msgRev", .integer).notNull().defaults(to: 0)
      }
    }

    migrator.registerMigration("dialog chat list hidden") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "chatListHidden", .boolean)
      }
    }

    migrator.registerMigration("dialog sidebar open") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "open", .boolean).notNull().defaults(to: false)
        t.add(column: "openedDate", .datetime)
      }
    }

    migrator.registerMigration("dialog sidebar order") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "order", .text)
        t.add(column: "pinnedOrder", .text)
      }
    }

    migrator.registerMigration("backfill dialog chat list hidden") { db in
      try db.execute(sql: """
        UPDATE dialog
        SET chatListHidden = 1
        WHERE chatListHidden IS NULL AND sidebarVisible = 0
        """)
      try db.execute(sql: """
        UPDATE dialog
        SET chatListHidden = NULL
        WHERE chatListHidden = 1 AND sidebarVisible = 1
        """)
    }

    migrator.registerMigration("url preview media type") { db in
      try db.alter(table: "urlPreview") { t in
        t.add(column: "mediaType", .text)
      }
    }

    migrator.registerMigration("url preview typed media") { db in
      try db.alter(table: "urlPreview") { t in
        t.add(column: "displayUrl", .text)
        t.add(column: "provider", .text)
        t.add(column: "author", .text)
        t.add(column: "mediaKind", .text)
        t.add(column: "videoId", .integer)
        t.add(column: "documentId", .integer)
        t.add(column: "externalUrl", .text)
        t.add(column: "externalMimeType", .text)
        t.add(column: "externalWidth", .integer)
        t.add(column: "externalHeight", .integer)
        t.add(column: "externalDuration", .integer)
        t.add(column: "embedUrl", .text)
        t.add(column: "embedType", .text)
        t.add(column: "embedWidth", .integer)
        t.add(column: "embedHeight", .integer)
        t.add(column: "embedDuration", .integer)
        t.add(column: "hasLargeMedia", .boolean)
        t.add(column: "showLargeMedia", .boolean)
      }
    }

    migrator.registerMigration("chat is untitled") { db in
      try db.alter(table: "chat") { t in
        t.add(column: "isUntitled", .boolean)
      }
    }

    migrator.registerMigration("chat number") { db in
      try db.alter(table: "chat") { t in
        t.add(column: "number", .integer)
      }
    }

    migrator.registerMigration("dialog follow mode") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "followMode", .text)
      }
    }

    migrator.registerMigration("drafts2") { db in
      try db.create(table: "draft2") { t in
        t.primaryKey("peerKey", .text)
        t.column("text", .text).notNull().defaults(to: "")
        t.column("entities", .blob)
        t.column("attachments", .blob)
        t.column("updatedAt", .integer).notNull()
        t.column("revision", .integer).notNull()
      }
    }

    migrator.registerMigration("message text fts") { db in
      try db.create(virtualTable: "messageTextFts", using: FTS5()) { t in
        t.synchronize(withTable: "message")
        t.tokenizer = .unicode61()
        t.prefixes = [2, 3, 4]
        t.column("text")
      }

      try db.execute(sql: "PRAGMA optimize")
    }

    migrator.registerMigration("user bio") { db in
      guard try !db.columns(in: "user").contains(where: { $0.name == "bio" }) else {
        return
      }

      try db.alter(table: "user") { t in
        t.add(column: "bio", .text)
      }
    }

    migrator.registerMigration("url preview author photo") { db in
      try db.alter(table: "urlPreview") { t in
        t.add(column: "authorPhotoId", .integer)
      }
    }

    migrator.registerMigration("user groups") { db in
      try db.create(table: "userGroup") { t in
        t.primaryKey("id", .integer).notNull().unique()
        t.column("spaceId", .integer)
          .notNull()
          .references("space", column: "id", onDelete: .cascade)
        t.column("name", .text).notNull()
        t.column("description", .text)
        t.column("memberCount", .integer).notNull().defaults(to: 0)
        t.column("currentUserIsMember", .boolean).notNull().defaults(to: false)
        t.column("date", .datetime).notNull()
      }

      try db.create(index: "userGroup_spaceId_idx", on: "userGroup", columns: ["spaceId"])

      try db.create(table: "userGroupMember") { t in
        t.column("groupId", .integer)
          .notNull()
          .references("userGroup", column: "id", onDelete: .cascade)
        t.column("userId", .integer)
          .notNull()
          .references("user", column: "id", onDelete: .cascade)
        t.primaryKey(["groupId", "userId"])
      }

      try db.create(index: "userGroupMember_userId_idx", on: "userGroupMember", columns: ["userId"])

      try db.create(table: "chatParticipantGroup") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("chatId", .integer)
          .notNull()
          .references("chat", column: "id", onDelete: .cascade)
        t.column("groupId", .integer)
          .notNull()
          .references("userGroup", column: "id", onDelete: .cascade)
        t.column("date", .datetime).notNull()
        t.uniqueKey(["chatId", "groupId"], onConflict: .replace)
      }

      try db.create(
        index: "chatParticipantGroup_chatId_idx",
        on: "chatParticipantGroup",
        columns: ["chatId"]
      )
      try db.create(
        index: "chatParticipantGroup_groupId_idx",
        on: "chatParticipantGroup",
        columns: ["groupId"]
      )
    }

    migrator.registerMigration("animated video metadata") { db in
      let columnNames = Set(try db.columns(in: "video").map(\.name))

      try db.alter(table: "video") { t in
        if !columnNames.contains("isAnimated") {
          t.add(column: "isAnimated", .boolean).notNull().defaults(to: false)
        }
        if !columnNames.contains("hasAudio") {
          t.add(column: "hasAudio", .boolean)
        }
      }
    }

    migrator.registerMigration("chat permissions") { db in
      try db.alter(table: "chat") { t in
        t.add(column: "canUpdateInfo", .boolean)
      }
    }

    migrator.registerMigration("space public handle") { db in
      let columnNames = Set(try db.columns(in: "space").map(\.name))
      try db.alter(table: "space") { t in
        if !columnNames.contains("handle") {
          t.add(column: "handle", .text)
        }
        if !columnNames.contains("isPublic") {
          t.add(column: "isPublic", .boolean)
        }
      }
    }

    migrator.registerMigration("dialog collapsed max id") { db in
      try db.alter(table: "dialog") { t in
        t.add(column: "collapsedMaxId", .integer)
      }
    }

    migrator.registerMigration("dialog folders") { db in
      try db.create(table: "dialogFolder") { table in
        table.column("id", .integer).primaryKey()
        table.column("title", .text)
        table.column("order", .text).notNull()
      }
      try db.create(index: "dialogFolder_order_idx", on: "dialogFolder", columns: ["order"])
      try db.alter(table: "dialog") { table in
        table.add(column: "folderId", .integer)
          .references("dialogFolder", onDelete: .setNull)
      }
      try db.create(
        index: "dialog_folderId_order_idx",
        on: "dialog",
        columns: ["folderId", "order"]
      )
    }

    migrator.registerMigration("message block content payload") { db in
      try db.alter(table: "message") { table in
        table.add(column: "blockContentPayload", .blob)
      }
    }

    migrator.registerMigration("message history holes and space recovery state") { db in
      try db.create(table: "messageHistoryHole") { table in
        table.column("chatId", .integer)
          .notNull()
          .references("chat", column: "id", onDelete: .cascade)
        table.column("lowerId", .integer).notNull()
        table.column("upperId", .integer).notNull()
        table.primaryKey(["chatId", "lowerId", "upperId"])
        table.check(Column("lowerId") > 0)
        table.check(Column("upperId") >= Column("lowerId"))
      }
      try db.create(
        index: "messageHistoryHole_chatId_lowerId_idx",
        on: "messageHistoryHole",
        columns: ["chatId", "lowerId"]
      )
      try db.execute(
        sql: """
        INSERT INTO messageHistoryHole (chatId, lowerId, upperId)
        SELECT id, 1, 9223372036854775806 FROM chat
        """
      )
      try db.execute(
        sql: """
        CREATE TRIGGER messageHistoryHole_seed_chat
        AFTER INSERT ON chat
        BEGIN
          INSERT OR IGNORE INTO messageHistoryHole (chatId, lowerId, upperId)
          VALUES (NEW.id, 1, 9223372036854775806);
        END
        """
      )

      try db.alter(table: "space") { table in
        table.add(column: "seq", .integer)
        table.add(column: "memberRosterComplete", .boolean).notNull().defaults(to: false)
      }
      try db.alter(table: "chat") { table in
        table.add(column: "participantRosterComplete", .boolean).notNull().defaults(to: false)
      }
      try db.create(table: "spaceRecoverySettings") { table in
        table.column("spaceId", .integer)
          .primaryKey()
          .references("space", column: "id", onDelete: .cascade)
        table.column("payload", .blob).notNull()
      }
    }

    migrator.registerMigration("dialog folder emoji") { db in
      try db.alter(table: "dialogFolder") { table in
        table.add(column: "emoji", .text)
      }
    }

    migrator.registerMigration("dialog folder pinned order") { db in
      try db.alter(table: "dialogFolder") { table in
        table.add(column: "pinnedOrder", .text)
      }
      try db.create(
        index: "dialogFolder_pinnedOrder_idx",
        on: "dialogFolder",
        columns: ["pinnedOrder"]
      )
    }

    // Keep this identifier stable for development databases that may have
    // recorded the WIP migration before it was appended to the committed tail.
    migrator.registerMigration("repair invalid cached user presence") { db in
      let repairedCount = try Self.repairInvalidCachedUserPresence(in: db)
      if repairedCount > 0 {
        Self.log.error("Repaired invalid cached user presence values count=\(repairedCount)")
      }
    }

    migrator.registerMigration("explicit acknowledgement cursors") { db in
      try db.create(table: "acknowledgement") { table in
        table.column("chatId", .integer).notNull().references("chat", onDelete: .cascade)
        table.column("userId", .integer).notNull()
        table.column("maxId", .integer).notNull()
        table.primaryKey(["chatId", "userId"])
      }
      try db.create(index: "acknowledgement_message", on: "acknowledgement", columns: ["chatId", "maxId"])
    }

    migrator.registerMigration("revisioned acknowledgement clear") { db in
      try db.alter(table: "acknowledgement") { table in
        table.add(column: "revision", .integer).notNull().defaults(to: 0)
        table.add(column: "cleared", .boolean).notNull().defaults(to: false)
      }
    }

    migrator.registerMigration("space active catalog exclusions") { db in
      try db.create(table: "spaceCatalogExclusion") { table in
        table.column("spaceId", .integer)
          .primaryKey()
          .references("space", column: "id", onDelete: .cascade)
      }
      try db.create(table: "dialogCatalogExclusion") { table in
        // Keep this marker independent from Dialog lifecycle: a later
        // authoritative dialog update can re-create and re-include the peer.
        table.column("dialogId", .integer).primaryKey()
      }
    }

    migrator.registerMigration("agent thread context and catalog") { db in
      try db.alter(table: "chat") { table in
        table.add(column: "agentContext", .blob)
      }
      try db.create(table: "agentConfigurationCatalog") { table in
        table.column("botUserId", .integer).primaryKey()
        table.column("payload", .blob).notNull()
        table.column("fetchedAt", .datetime).notNull()
      }
    }

    migrator.registerMigration("dialogTranslationEnabled") { db in
      try db.alter(table: "dialog") { table in
        table.add(column: "translationEnabled", .boolean)
      }
      // Preserve the current account's old local choices without copying them to
      // other accounts. The first explicit synced toggle replaces this value.
      for row in try Row.fetchAll(db, sql: "SELECT id, peerUserId, peerThreadId FROM dialog") {
        let peer: Peer
        if let userID = row["peerUserId"] as Int64? {
          peer = .user(id: userID)
        } else if let threadID = row["peerThreadId"] as Int64? {
          peer = .thread(id: threadID)
        } else {
          continue
        }
        let id: Int64 = row["id"]
        let key = "translation_enabled_" + peer.toString()
        if let enabled = UserDefaults.standard.object(forKey: key) as? Bool {
          try db.execute(
            sql: "UPDATE dialog SET translationEnabled = ? WHERE id = ?",
            arguments: [enabled, id]
          )
        }
      }
    }

    migrator.registerMigration("dialogTranslationLegacyImport") { db in
      try db.alter(table: "dialog") { table in
        table.add(column: "translationLegacyImportPending", .boolean).defaults(to: false)
      }
      // The preceding migration preserved device-local choices. Only enabled
      // choices are uploaded; a legacy off must never disable another device.
      try db.execute(sql: "UPDATE dialog SET translationLegacyImportPending = 1 WHERE translationEnabled = 1")
    }

    migrator.registerMigration("sync destructive removal revision") { db in
      try db.create(table: "sync_removal_revision") { table in
        table.column("id", .integer).primaryKey().check { $0 == 1 }
        table.column("revision", .integer).notNull().defaults(to: 0)
      }
      try db.execute(sql: "INSERT INTO sync_removal_revision (id, revision) VALUES (1, 0)")
    }

    /// TODOs:
    /// - Add indexes for performance
    /// - Add timestamp integer types instead of Date for performance and faster sort, less storage
    return migrator
  }
}

extension AppDatabase {
  /// Repairs the known legacy presence representation before GRDB records are observed.
  /// `lastOnline` is cache metadata, so an undecodable or out-of-range value safely degrades to unknown.
  @discardableResult
  static func repairInvalidCachedUserPresence(in db: Database) throws -> Int {
    try db.execute(
      sql: """
      UPDATE "user"
      SET "lastOnline" = NULL
      WHERE "lastOnline" IS NOT NULL
        AND (
          typeof("lastOnline") NOT IN ('integer', 'real', 'text')
          OR (typeof("lastOnline") = 'text' AND julianday("lastOnline") IS NULL)
          OR (
            typeof("lastOnline") IN ('integer', 'real')
            AND ("lastOnline" < 0 OR "lastOnline" > 253402300799)
          )
        )
      """
    )
    return db.changesCount
  }
}

// MARK: - Database Configuration

public extension AppDatabase {
  struct LogoutCleanupError: Error, LocalizedError, Sendable, PrivacySafeErrorCategoryProviding {
    enum Phase: String, Equatable, Sendable {
      case openPersistent = "open_persistent"
      case discoverTables = "discover_tables"
      case deleteRows = "delete_rows"
      case resetSequence = "reset_sequence"
      case verifyEmpty = "verify_empty"
      case rotatePassphrase = "rotate_passphrase"
    }

    let phase: Phase
    let table: String?
    let reason: String

    public var errorDescription: String? {
      var details = "phase=\(phase.rawValue)"
      if let table {
        details += " table=\(table)"
      }
      return "Database logout cleanup failed \(details) reason=\(reason)"
    }

    public var privacySafeErrorCategory: String {
      "database_cleanup:\(phase.rawValue)"
    }
  }

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

    // Let short-lived contention between database connections finish instead
    // of turning ordinary reads and writes into SQLITE_BUSY.
    config.busyMode = .timeout(5)

    config.prepareDatabase { db in
      db.trace(options: .statement) { log.trace($0.expandedDescription) }
      try db.usePassphrase(passphrase)
    }

    return config
  }

  static func authenticated() async throws {
    let key = try requiredDatabaseKey(for: DatabaseKeyStore.getOrCreate())

    if AppDatabase.shared.isPersistent,
       AppDatabase.shared.isCredentialStoragePrepared(for: key)
    {
      return
    }

    if !AppDatabase.shared.isPersistent {
      _ = await promoteSharedToPersistentIfPossible()
      guard AppDatabase.shared.isPersistent else {
        log.error("AppDatabase.authenticated could not promote the in-memory database")
        throw DatabaseCredentialPreparationError.persistentDatabaseUnavailable
      }
    }

    try AppDatabase.changePassphrase(key)
    AppDatabase.shared.markCredentialStoragePrepared(for: key)
  }

  /// Establishes durable database authority and removes stale account projection before credential
  /// authority changes. The post-key and in-transaction generation checks fence a logout that
  /// starts while passphrase preparation is suspended.
  @concurrent
  static func prepareForLogin(
    auth: AuthHandle,
    loginAttempt: AuthLoginAttempt
  ) async throws {
    try await authenticated()
    guard auth.isLoginAttemptCurrent(loginAttempt) else {
      throw AuthStorageError.loginSuperseded
    }
    try await AppDatabase.shared.dbWriter.write { db in
      try prepareLoginDatabase(db, isCurrent: { auth.isLoginAttemptCurrent(loginAttempt) })
    }
    log.info("Database prepared for login.")
  }

  /// Adds the new user's minimum projection only after credential authority was durably committed.
  /// A failed projection transaction leaves the already-cleared database empty for safe recovery.
  @concurrent
  static func commitLoginProjection<Result: Sendable>(
    auth: AuthHandle,
    loginAttempt: AuthLoginAttempt,
    writeProjection: @escaping @Sendable (Database) throws -> Result
  ) async throws -> Result {
    try await AppDatabase.shared.dbWriter.write { db in
      try writeLoginProjection(
        db,
        isCurrent: { auth.isLoginAttemptCurrent(loginAttempt) },
        reserveCommit: { auth.reserveLoginCommit(loginAttempt) },
        writeProjection: writeProjection
      )
    }
  }

  internal static func prepareLoginDatabase(
    _ db: Database,
    isCurrent: () -> Bool
  ) throws {
    guard isCurrent() else { throw AuthStorageError.loginSuperseded }
    try clearTables(db)
    guard isCurrent() else { throw AuthStorageError.loginSuperseded }
  }

  internal static func writeLoginProjection<Result>(
    _ db: Database,
    isCurrent: () -> Bool,
    reserveCommit: () -> Bool,
    writeProjection: (Database) throws -> Result
  ) throws -> Result {
    guard isCurrent() else { throw AuthStorageError.loginSuperseded }
    let result = try writeProjection(db)
    guard isCurrent() else { throw AuthStorageError.loginSuperseded }
    guard reserveCommit() else { throw AuthStorageError.loginSuperseded }
    return result
  }

  static func requiredDatabaseKey(
    for availability: DatabaseKeyAvailability
  ) throws -> String {
    switch availability {
    case .available(let key):
      return key
    case .locked:
      log.warning("AppDatabase.authenticated called while keychain is locked")
      throw DatabaseCredentialPreparationError.keychainLocked
    case .notFound:
      log.warning("AppDatabase.authenticated called without database key")
      throw DatabaseCredentialPreparationError.keyUnavailable
    case .error(let status):
      log.error("AppDatabase.authenticated failed to get database key status=\(status)")
      throw DatabaseCredentialPreparationError.keychainFailure(status)
    }
  }

  static func clearDB() throws {
    try AppDatabase.shared.dbWriter.write { db in
      try clearTables(db)
    }

    // Note(@mo): Commented because database file won't be availble for the next user!!!!! If you need this
    // find a way to re-create the database file
    // try deleteDatabaseFile()

    log.info("Database successfully cleared.")
  }

  internal static func clearTables(_ db: Database) throws {
    let ftsTables: Set<String>
    let tables: [String]
    do {
      ftsTables = try ftsTableNamesToSkip(db)
      tables = try String.fetchAll(
        db,
        sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table'
        AND name NOT LIKE 'sqlite_%'
        AND name NOT LIKE 'grdb_%'
        """
      )
    } catch {
      throw logoutCleanupError(phase: .discoverTables, error: error)
    }

    for table in tables where !ftsTables.contains(table) {
      do {
        try db.execute(sql: "DELETE FROM \(quotedIdentifier(table))")
      } catch {
        throw logoutCleanupError(phase: .deleteRows, table: table, error: error)
      }
      do {
        try db.execute(sql: "DELETE FROM sqlite_sequence WHERE name = ?", arguments: [table])
      } catch {
        throw logoutCleanupError(phase: .resetSequence, table: table, error: error)
      }
    }

    let ftsVirtualTables = ftsVirtualTableNames(in: ftsTables)
    let verifiableTables = tables.filter { table in
      !ftsTables.contains(table) || ftsVirtualTables.contains(table)
    }
    for table in verifiableTables {
      do {
        let remaining = try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM \(quotedIdentifier(table))"
        ) ?? 0
        guard remaining == 0 else {
          throw LogoutCleanupError(
            phase: .verifyEmpty,
            table: table,
            reason: "remaining_rows=\(remaining)"
          )
        }
      } catch let error as LogoutCleanupError {
        throw error
      } catch {
        throw logoutCleanupError(phase: .verifyEmpty, table: table, error: error)
      }
    }
  }

  private static func ftsTableNamesToSkip(_ db: Database) throws -> Set<String> {
    let virtualTables = try String.fetchAll(
      db,
      sql: """
      SELECT name FROM sqlite_master
      WHERE type = 'table'
      AND lower(sql) LIKE '%using fts%'
      """
    )

    let shadowSuffixes = ["_data", "_idx", "_docsize", "_config", "_content"]
    var names = Set(virtualTables)
    for table in virtualTables {
      for suffix in shadowSuffixes {
        names.insert("\(table)\(suffix)")
      }
    }
    return names
  }

  private static func ftsVirtualTableNames(in skippedNames: Set<String>) -> Set<String> {
    let shadowSuffixes = ["_data", "_idx", "_docsize", "_config", "_content"]
    return Set(skippedNames.filter { name in
      !shadowSuffixes.contains(where: name.hasSuffix)
    })
  }

  private static func logoutCleanupError(
    phase: LogoutCleanupError.Phase,
    table: String? = nil,
    error: any Error
  ) -> LogoutCleanupError {
    LogoutCleanupError(
      phase: phase,
      table: table,
      reason: "\(type(of: error)): \(error.localizedDescription)"
    )
  }

  private static func quotedIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  static func loggedOut() throws {
    do {
      guard AppDatabase.shared.isPersistent else {
        throw LogoutCleanupError(
          phase: .openPersistent,
          table: nil,
          reason: "persistent database unavailable"
        )
      }
      try clearDB()

      do {
        // Reset the database passphrase to a default value
        switch DatabaseKeyStore.getOrCreate() {
        case .available(let key):
          try AppDatabase.changePassphrase(key)
          AppDatabase.shared.markCredentialStoragePrepared(for: key)
        default:
          try AppDatabase.changePassphrase("123")
          AppDatabase.shared.markCredentialStoragePrepared(for: nil)
        }
      } catch {
        throw logoutCleanupError(phase: .rotatePassphrase, error: error)
      }
    } catch {
      log.error(error.localizedDescription, error: error)
      throw error
    }
  }

  /// Logout cleanup can scan and clear every local table and rekey SQLCipher.
  /// Keep that synchronous database work off UI actors while preserving one
  /// awaited, fail-closed completion point for callers.
  @concurrent
  static func loggedOutAsync() async throws {
    try await requirePersistentStorageForLogout()
    try loggedOut()
  }

  /// Returns an opaque proof only after table discovery, deletion, empty verification, and
  /// passphrase rotation have all succeeded for the authoritative logout fence.
  @concurrent
  static func loggedOutAsync(fence: AuthLogoutFence) async throws -> AuthDatabaseCleanupProof {
    try await requirePersistentStorageForLogout()
    try loggedOut()
    return AuthDatabaseCleanupProof(fence: fence)
  }

  /// A logout proof must apply to the on-disk account store, never only to the process-local
  /// fallback used while protected keychain authority is unavailable. If promotion cannot open the
  /// persistent store, fail closed and retain the durable logout marker for a later recovery retry.
  @concurrent
  internal static func requirePersistentStorageForLogout(
    _ database: AppDatabase = AppDatabase.shared,
    promote: @escaping @Sendable () async -> Bool = {
      await AppDatabase.promoteSharedToPersistentIfPossible()
    }
  ) async throws {
    guard database.isPersistent == false else { return }
    _ = await promote()
    guard database.isPersistent else {
      throw LogoutCleanupError(
        phase: .openPersistent,
        table: nil,
        reason: "persistent database unavailable"
      )
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
  private static func databaseFilesOnDisk() -> [URL] {
    let databaseUrl = getDatabaseUrl()
    return [
      databaseUrl,
      URL(fileURLWithPath: "\(databaseUrl.path)-wal"),
      URL(fileURLWithPath: "\(databaseUrl.path)-shm"),
      URL(fileURLWithPath: "\(databaseUrl.path)-journal"),
    ]
  }

  @discardableResult
  static func deleteDatabaseFilesOnDisk() throws -> [URL] {
    let fileManager = FileManager.default
    var deleted: [URL] = []

    for url in databaseFilesOnDisk() {
      guard fileManager.fileExists(atPath: url.path) else { continue }
      try fileManager.removeItem(at: url)
      deleted.append(url)
    }

    if deleted.isEmpty {
      log.warning("Database files not found.")
    } else {
      let names = deleted.map(\.lastPathComponent).joined(separator: ", ")
      log.info("Database files successfully deleted: \(names)")
    }

    return deleted
  }

  static func deleteDatabaseFile() throws {
    try deleteDatabaseFilesOnDisk()
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

  private static var buildFlavor: String {
    #if DEBUG
    "debug"
    #elseif DEBUG_BUILD
    "debugBuild"
    #else
    "release"
    #endif
  }

  private static func keyStatus(_ availability: DatabaseKeyAvailability) -> String {
    switch availability {
    case .available:
      return "available"
    case .locked:
      return "locked"
    case .notFound:
      return "notFound"
    case .error(let status):
      return "error(\(status))"
    }
  }

  internal static func persistentOpenFailure(
    for availability: DatabaseKeyAvailability
  ) -> PersistentStoreOpenFailure? {
    switch availability {
    case .available:
      return nil
    case .locked:
      return PersistentStoreOpenFailure(
        reason: .keychainLocked,
        disposition: .retryable,
        sqliteCode: nil,
        sqliteExtendedCode: nil
      )
    case .notFound:
      return PersistentStoreOpenFailure(
        reason: .keyUnavailable,
        disposition: .terminal,
        sqliteCode: nil,
        sqliteExtendedCode: nil
      )
    case .error:
      return PersistentStoreOpenFailure(
        reason: .keychainFailure,
        disposition: .terminal,
        sqliteCode: nil,
        sqliteExtendedCode: nil
      )
    }
  }

  internal static func persistentOpenFailure(
    for error: any Error,
    duringMigration: Bool = false
  ) -> PersistentStoreOpenFailure {
    guard let databaseError = error as? DatabaseError else {
      return PersistentStoreOpenFailure(
        reason: duringMigration ? .migration : .unknown,
        disposition: .terminal,
        sqliteCode: nil,
        sqliteExtendedCode: nil
      )
    }

    let reason: PersistentStoreOpenFailureReason
    let disposition: PersistentStoreOpenFailure.Disposition
    switch databaseError.resultCode {
    case .SQLITE_BUSY:
      reason = .databaseBusy
      disposition = .retryable
    case .SQLITE_LOCKED:
      reason = .databaseLocked
      disposition = .retryable
    case .SQLITE_FULL:
      reason = .databaseFull
      disposition = .terminal
    case .SQLITE_READONLY:
      reason = .databaseReadOnly
      disposition = .terminal
    case .SQLITE_CANTOPEN:
      reason = .databaseCannotOpen
      disposition = .terminal
    case .SQLITE_IOERR:
      reason = .databaseIO
      disposition = .terminal
    case .SQLITE_CORRUPT, .SQLITE_NOTADB:
      reason = .databaseUnreadable
      disposition = .terminal
    default:
      reason = duringMigration ? .migration : .unknown
      disposition = .terminal
    }
    return PersistentStoreOpenFailure(
      reason: reason,
      disposition: disposition,
      sqliteCode: Int32(databaseError.resultCode.rawValue),
      sqliteExtendedCode: Int32(databaseError.extendedResultCode.rawValue)
    )
  }

  /// A failed passphrase probe cannot prove corruption while the authoritative
  /// database key is unavailable. Preserve the key-authority classification so
  /// a normal protected-data delay never becomes a terminal database reset.
  internal static func persistentOpenFailure(
    afterExhaustingCandidatesWith keyAvailability: DatabaseKeyAvailability,
    authoritativeKeyError: (any Error)? = nil,
    lastError: (any Error)?
  ) -> PersistentStoreOpenFailure {
    if let keyFailure = persistentOpenFailure(for: keyAvailability) {
      return keyFailure
    }
    if let authoritativeKeyError {
      return persistentOpenFailure(for: authoritativeKeyError, duringMigration: true)
    }
    if let lastError {
      return persistentOpenFailure(for: lastError)
    }
    return PersistentStoreOpenFailure(
      reason: .unknown,
      disposition: .terminal,
      sqliteCode: nil,
      sqliteExtendedCode: nil
    )
  }

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
    let startedAt = Date()
    let sharedSpan = PerformanceTrace.begin("DatabaseMakeShared", category: .launch)
    defer { sharedSpan.end() }

    let pathSpan = PerformanceTrace.begin("DatabaseResolvePath", category: .launch)
    let databaseUrl = getDatabaseUrl()
    pathSpan.end()
    let databasePath = databaseUrl.path
    let fileManager = FileManager.default
    let fileExists = fileManager.fileExists(atPath: databasePath)
    var finalAdmission: PersistentStoreAdmission?
    var candidateAttempts = 0
    var lastCandidateLabel = "none"
    defer {
      if let finalAdmission {
        PersistentStoreStartupDiagnostics.report(
          admission: finalAdmission,
          durationMs: PerformanceTrace.elapsedMilliseconds(since: startedAt),
          fileExistedAtStart: fileExists,
          candidateAttempts: candidateAttempts,
          lastCandidateLabel: lastCandidateLabel
        )
      }
    }

    func admit(_ database: AppDatabase) -> AppDatabase {
      finalAdmission = database.persistentStoreAdmission
      return database
    }

    var pathForLog = databasePath
    pathForLog.replace(" ", with: "\\ ")
    log.debug("Database path: \(pathForLog)")
    let keySpan = PerformanceTrace.begin("DatabaseKeyLoad", category: .launch)
    let keyAvailability = DatabaseKeyStore.load()
    keySpan.end()
    log.info(
      "Database config: build=\(buildFlavor)" +
        " profile=\(ProjectConfig.userProfile ?? "default")" +
        " keyAccount=\(DatabaseKeyStore.expectedKeychainAccount())" +
        " keyStatus=\(keyStatus(keyAvailability))" +
        " fileExists=\(fileExists ? 1 : 0)"
    )
    #if !DEBUG_BUILD
    if ProjectConfig.userProfile == "devbuild" {
      log.error("DevBuild profile is active without DEBUG_BUILD; build devbuilds through scripts/macos/build-local-app.sh")
    }
    #endif

    func openPersistent(
      passphrase: String,
      candidateLabel: String
    ) throws -> (db: AppDatabase, pool: DatabasePool) {
      candidateAttempts += 1
      lastCandidateLabel = candidateLabel
      let span = PerformanceTrace.begin("DatabaseOpenPersistent", category: .launch)
      do {
        let config = AppDatabase.makeConfiguration(passphrase: passphrase)
        let pool = try DatabasePool(path: databasePath, configuration: config)
        let db = try AppDatabase(pool)
        span.end("success=1")
        return (db: db, pool: pool)
      } catch {
        span.end("success=0")
        throw error
      }
    }

    func openInMemory(after failure: PersistentStoreOpenFailure) -> AppDatabase {
      do {
        // Prefer dbKey if available; fall back to legacy.
        let passphrase: String = switch DatabaseKeyStore.load() {
        case .available(let key):
          key
        default:
          "123"
        }
        let dbQueue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: passphrase))
        let database = try AppDatabase(dbQueue)
        database.recordPersistentOpenFailure(failure)
        return database
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
          return admit(try openPersistent(passphrase: key, candidateLabel: "new_db_key").db)
        } catch {
          log.error("Failed to create persistent database with dbKey; using in-memory", error: error)
          return admit(openInMemory(after: persistentOpenFailure(for: error, duringMigration: true)))
        }
      case .locked:
        log.warning("Keychain locked; using in-memory database until credentials are available")
        return admit(openInMemory(after: persistentOpenFailure(
          afterExhaustingCandidatesWith: .locked,
          lastError: nil
        )))
      case .notFound:
        log.warning("No database key available; using in-memory database")
        return admit(openInMemory(after: persistentOpenFailure(
          afterExhaustingCandidatesWith: .notFound,
          lastError: nil
        )))
      case .error(let status):
        log.warning("Database key creation failed; using in-memory database")
        return admit(openInMemory(after: persistentOpenFailure(
          afterExhaustingCandidatesWith: .error(status: status),
          lastError: nil
        )))
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

    var authoritativeKeyError: (any Error)?
    var lastError: (any Error)?

    for candidate in candidates {
      do {
        let opened = try openPersistent(
          passphrase: candidate.passphrase,
          candidateLabel: candidate.label
        )

        // Migrate legacy DB encryption (token / "123") to dbKey once we can.
        if candidate.label != "dbKey" {
          switch DatabaseKeyStore.getOrCreate() {
          case .available(let newKey) where newKey != candidate.passphrase:
            do {
              try rotatePassphrase(pool: opened.pool, to: newKey)
              // Drop the old pool (wrong config) and reopen with the new key.
              return admit(try openPersistent(
                passphrase: newKey,
                candidateLabel: "rotated_db_key"
              ).db)
            } catch {
              log.error("Failed to rotate DB passphrase to dbKey; continuing with legacy key", error: error)
            }
          default:
            break
          }
        }

        return admit(opened.db)
      } catch {
        if candidate.label == "dbKey" {
          authoritativeKeyError = error
        }
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
    return admit(openInMemory(after: persistentOpenFailure(
      afterExhaustingCandidatesWith: keyAvailability,
      authoritativeKeyError: authoritativeKeyError,
      lastError: lastError
    )))
  }

  /// If `AppDatabase.shared` was initialized while the keychain was unavailable (common on iOS before
  /// first unlock), it may have fallen back to an in-memory database. This method attempts to reopen
  /// the persistent database and swap `shared`'s writer in-place so callers that hold on to the
  /// `AppDatabase` instance can recover without a process restart.
  ///
  /// Note: any observers that captured the old `DatabaseReader`/`DatabaseWriter` instance directly
  /// (e.g. GRDB `ValueObservation.publisher(in:)`) must be created *after* this promotion runs.
  private static func reopenPersistentWriterForShared() -> (any DatabaseWriter)? {
    let reopened = makeShared()
    guard reopened.dbWriter is DatabasePool else {
      switch reopened.persistentStoreAdmission {
      case .ready:
        break
      case .retryable(let failure), .terminal(let failure):
        shared.recordPersistentOpenFailure(failure)
      }
      return nil
    }
    return reopened.dbWriter
  }

  @discardableResult
  static func promoteToPersistentIfPossible(
    _ db: AppDatabase,
    reopenWriter: @escaping @Sendable () -> (any DatabaseWriter)?
  ) async -> Bool {
    // Already persistent.
    if db.dbWriter is DatabasePool {
      return false
    }

    let newWriter: (any DatabaseWriter)? = await Task.detached(priority: .userInitiated) {
      reopenWriter()
    }.value

    guard let newWriter, newWriter is DatabasePool else {
      return false
    }

    db.swapWriter(newWriter)
    log.info("Promoted in-memory database to persistent database writer")
    return true
  }

  @discardableResult
  static func promoteSharedToPersistentIfPossible() async -> Bool {
    await promoteToPersistentIfPossible(shared, reopenWriter: reopenPersistentWriterForShared)
  }

  /// Shared in-memory DB used as the default SwiftUI environment fallback.
  /// Keeping this cached avoids repeated in-memory database bootstrap work.
  static let environmentDefault = makeInMemory(passphrase: "123")

  private static func makeInMemory(passphrase: String) -> AppDatabase {
    do {
      let dbQueue = try DatabaseQueue(
        configuration: AppDatabase.makeConfiguration(passphrase: passphrase)
      )
      return try AppDatabase(dbQueue)
    } catch {
      fatalError("Unable to initialize in-memory database: \(error)")
    }
  }

  /// Creates an empty database for SwiftUI previews
  static func empty() -> AppDatabase {
    // For preview/test in-memory DBs we use the legacy passphrase directly and
    // avoid keychain reads on this hot path.
    makeInMemory(passphrase: "123")
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
