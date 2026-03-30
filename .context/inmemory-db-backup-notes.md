In-memory DB clone + debounced disk backup (notes)

Summary
- Rewired AppDatabase startup to open the on-disk database, clone it into an in-memory DatabaseQueue, and use the in-memory queue as the app writer.
- Added a TransactionObserver that schedules a debounced full backup from in-memory back to disk on commit.
- Added optional disk persistence flags and logging so the behavior could be enabled/disabled and verified.
- Ensured passphrase updates are applied to both the in-memory writer and the on-disk writer.

GRDB APIs used
- DatabaseQueue(path:configuration:) to open the on-disk database.
- DatabaseQueue(named:nil, configuration:) to create an in-memory database.
- backup(to:) to clone on-disk -> in-memory and to sync in-memory -> disk.
- TransactionObserver to detect inserts/updates/deletes and commits.
- DatabaseWriter.add(transactionObserver:extent:) to register the observer.
- DatabaseEventKind.insert/delete/update to filter events.

Key behavior decisions
- Debounced backup every 0.5s on commit (coalesces bursts, avoids per-commit full backups).
- Disk persistence flag set to false by default so perf can be measured without disk syncing.
- Logs for disk path, in-memory path, and backup scheduling/completion.

Approximate diff (for re-apply later)
```diff
--- a/apple/InlineKit/Sources/InlineKit/Database.swift
+++ b/apple/InlineKit/Sources/InlineKit/Database.swift
@@
 public final class AppDatabase: Sendable {
   public let dbWriter: any DatabaseWriter
 + private let diskWriter: (any DatabaseWriter)?
 + private let diskSyncObserver: DiskSyncObserver?
 + private static let diskPersistenceEnabled = false
 + private static let diskPersistenceDebounce: TimeInterval = 0.5
   static let log = Log.scoped(...)
@@
-  public init(_ dbWriter: any GRDB.DatabaseWriter) throws {
+  init(
+    _ dbWriter: any GRDB.DatabaseWriter,
+    diskWriter: (any GRDB.DatabaseWriter)? = nil,
+    diskSyncObserver: DiskSyncObserver? = nil
+  ) throws {
     self.dbWriter = dbWriter
 +   self.diskWriter = diskWriter
 +   self.diskSyncObserver = diskSyncObserver
     try migrator.migrate(dbWriter)
   }
 }

+// Disk sync observer
+private final class DiskSyncObserver: TransactionObserver, @unchecked Sendable {
+  private let source: DatabaseQueue
+  private let destination: DatabaseQueue
+  private let debounceInterval: TimeInterval
+  private let queue: DispatchQueue
+  private var pendingWorkItem: DispatchWorkItem?
+  private var hasChanges = false
+
+  init(source: DatabaseQueue, destination: DatabaseQueue, debounceInterval: TimeInterval, queueLabel: String = "AppDatabase.diskSync") { ... }
+
+  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
+    switch eventKind { case .insert, .delete, .update: return true }
+  }
+
+  func databaseDidChange(with _: DatabaseEvent) { hasChanges = true }
+  func databaseDidCommit(_ db: Database) { guard hasChanges else { return }; hasChanges = false; scheduleBackup() }
+  func databaseDidRollback(_ db: Database) { hasChanges = false }
+  func requestBackup() { scheduleBackup() }
+
+  private func scheduleBackup() {
+    queue.async { [weak self] in
+      guard let self else { return }
+      pendingWorkItem?.cancel()
+      AppDatabase.log.debug("Scheduling database backup to disk")
+      let workItem = DispatchWorkItem { [weak self] in
+        guard let self else { return }
+        do { try source.backup(to: destination); AppDatabase.log.debug("Database backup to disk completed") }
+        catch { AppDatabase.log.error("Failed to backup in-memory database to disk", error: error) }
+      }
+      pendingWorkItem = workItem
+      queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
+    }
+  }
+}

@@
 internal static func changePassphrase(_ passphrase: String) throws {
   do {
-    if let dbPool = AppDatabase.shared.dbWriter as? DatabasePool { ... }
-    else if let dbQueue = AppDatabase.shared.dbWriter as? DatabaseQueue { ... }
+    try applyPassphrase(passphrase, to: AppDatabase.shared.dbWriter)
+    if let diskWriter = AppDatabase.shared.diskWriter {
+      try applyPassphrase(passphrase, to: diskWriter)
+    }
   } catch { ... }
 }

+private static func applyPassphrase(_ passphrase: String, to writer: any DatabaseWriter) throws {
+  if let dbPool = writer as? DatabasePool {
+    try dbPool.barrierWriteWithoutTransaction { db in
+      try db.changePassphrase(passphrase)
+      dbPool.invalidateReadOnlyConnections()
+    }
+  } else if let dbQueue = writer as? DatabaseQueue {
+    try dbQueue.write { db in try db.changePassphrase(passphrase) }
+  }
+}

@@
 private static func makeShared() -> AppDatabase {
   do {
     let databaseUrl = getDatabaseUrl()
     let databasePath = databaseUrl.path
     let config = AppDatabase.makeConfiguration()
-    let dbPool = try DatabasePool(path: databasePath, configuration: config)
+    let (inMemoryQueue, diskQueue, diskSyncObserver) = try makeInMemoryClone(
+      databasePath: databasePath,
+      configuration: config
+    )
     ...
+    log.debug("In-memory database path: \\(inMemoryQueue.path)")
+    log.debug("Disk persistence enabled: \\(diskPersistenceEnabled)")
     let appDatabase = try AppDatabase(
-      dbPool
+      inMemoryQueue,
+      diskWriter: diskQueue,
+      diskSyncObserver: diskSyncObserver
     )
+    diskSyncObserver?.requestBackup()
     return appDatabase
   } catch { ... }
 }

+private static func makeInMemoryClone(
+  databasePath: String,
+  configuration: Configuration
+ ) throws -> (DatabaseQueue, DatabaseQueue, DiskSyncObserver?) {
+  let diskQueue = try DatabaseQueue(path: databasePath, configuration: configuration)
+  let inMemoryQueue = try DatabaseQueue(named: nil, configuration: configuration)
+  try diskQueue.backup(to: inMemoryQueue)
+
+  guard diskPersistenceEnabled else {
+    log.info("Disk persistence disabled; in-memory database will not replicate to disk.")
+    return (inMemoryQueue, diskQueue, nil)
+  }
+
+  let diskSyncObserver = DiskSyncObserver(
+    source: inMemoryQueue,
+    destination: diskQueue,
+    debounceInterval: diskPersistenceDebounce
+  )
+  inMemoryQueue.add(transactionObserver: diskSyncObserver, extent: .observerLifetime)
+  return (inMemoryQueue, diskQueue, diskSyncObserver)
+}
```

Notes for re-apply
- This diff replaced the prior DatabasePool usage with an in-memory DatabaseQueue. If you want DatabasePool semantics for reads, we would need to re-check GRDB APIs for an in-memory pool or use a pool backed by a temporary file.
- The observer uses a full backup on commit, debounced at 500ms. This is intended as a temporary approach before a row-level sync (future work).
