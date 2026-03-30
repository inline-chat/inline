# Resumable downloads (Range + partial file) — plan

## Context
- Goal: persist download progress so iOS/macOS can resume after app relaunch.
- Target: InlineKit `FileDownloader` (documents + videos). Photos unchanged for now.
- Hosting: Cloudflare; expect `Accept-Ranges: bytes`.
- Approach chosen: HTTP Range requests + partial file + persisted metadata.

## High‑level design
- Persist a download record in the local DB for each in‑flight download.
- Stream bytes to a `.partial` file (not `URLSessionDownloadTask` temp file).
- Resume by sending `Range: bytes=<offset>-` and `If-Range` (ETag/Last‑Modified) when possible.
- On completion, move `.partial` to final path and update media `localPath` in DB.

## Schema / persistence
Add a new migration in `apple/InlineKit/Sources/InlineKit/Database.swift`:
```swift
migrator.registerMigration("download records") { db in
  try db.create(table: "downloadRecord") { t in
    t.column("id", .text).primaryKey()               // "doc_<id>" / "video_<id>"
    t.column("mediaId", .integer).notNull()
    t.column("mediaType", .text).notNull()           // "document" / "video"
    t.column("remoteUrl", .text).notNull()
    t.column("localFinalPath", .text).notNull()
    t.column("partialPath", .text).notNull()
    t.column("bytesReceived", .integer).notNull().defaults(to: 0)
    t.column("totalBytes", .integer)
    t.column("etag", .text)
    t.column("lastModified", .text)
    t.column("state", .integer).notNull()            // enum
    t.column("updatedAt", .datetime).notNull()
  }
  t.uniqueKey(["mediaType", "mediaId"])
}
```

Model file: `apple/InlineKit/Sources/InlineKit/Models/DownloadRecord.swift`
```swift
public enum DownloadState: Int, Codable, Sendable {
  case queued = 0, downloading = 1, paused = 2, failed = 3, completed = 4
}

public struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
  public var id: String
  public var mediaId: Int64
  public var mediaType: String
  public var remoteUrl: String
  public var localFinalPath: String
  public var partialPath: String
  public var bytesReceived: Int64
  public var totalBytes: Int64?
  public var etag: String?
  public var lastModified: String?
  public var state: DownloadState
  public var updatedAt: Date
}
```

## Download store
Create `apple/InlineKit/Sources/InlineKit/Files/DownloadStore.swift` (actor):
```swift
public actor DownloadStore {
  public static let shared = DownloadStore()
  private let db = AppDatabase.shared

  public func upsert(_ record: DownloadRecord) async throws {
    try await db.dbWriter.write { db in
      try record.save(db)
    }
  }

  public func fetch(id: String) async throws -> DownloadRecord? {
    try await db.dbWriter.read { db in
      try DownloadRecord.fetchOne(db, key: id)
    }
  }

  public func fetchPending() async throws -> [DownloadRecord] {
    try await db.dbWriter.read { db in
      try DownloadRecord
        .filter(Column("state") != DownloadState.completed.rawValue)
        .fetchAll(db)
    }
  }

  public func delete(id: String) async throws {
    try await db.dbWriter.write { db in
      _ = try DownloadRecord.deleteOne(db, key: id)
    }
  }
}
```

## FileDownloader changes
File: `apple/InlineKit/Sources/InlineKit/Files/FileDownload.swift`

Key refactor:
- Switch to `URLSessionDataTask` + `URLSessionDataDelegate`.
- Persist `.partial` file and update DB record while streaming.
- Use Range request with `If-Range` header for safe resume.

Add a task context:
```swift
private struct DownloadContext {
  let id: String
  let record: DownloadRecord
  let fileHandle: FileHandle
  var bytesReceived: Int64
  var totalBytes: Int64?
}
```

Request builder:
```swift
private func makeRequest(record: DownloadRecord) -> URLRequest {
  var request = URLRequest(url: URL(string: record.remoteUrl)!)
  if record.bytesReceived > 0 {
    request.setValue("bytes=\(record.bytesReceived)-", forHTTPHeaderField: "Range")
    if let etag = record.etag {
      request.setValue(etag, forHTTPHeaderField: "If-Range")
    } else if let lastModified = record.lastModified {
      request.setValue(lastModified, forHTTPHeaderField: "If-Range")
    }
  }
  return request
}
```

Handle 200/206/416 in `didReceive response`:
```swift
if http.statusCode == 206 {
  // append at current offset
} else if http.statusCode == 200 {
  // server ignored range; truncate partial and restart
} else if http.statusCode == 416 {
  // invalid range; restart
}
```

Streaming writes + progress:
```swift
try context.fileHandle.write(contentsOf: data)
context.bytesReceived += Int64(data.count)
// throttle DB updates
await DownloadStore.shared.upsert(updatedRecord)
updateProgress(id: context.id, bytesReceived: context.bytesReceived, totalBytes: context.totalBytes ?? 0)
```

Completion:
```swift
// close file, move partial -> final, update Document/Video localPath
try await DownloadStore.shared.delete(id: id)
```

Progress publisher seeding:
```swift
if let record = try? await DownloadStore.shared.fetch(id: id) {
  let initial = DownloadProgress(id: id, bytesReceived: record.bytesReceived, totalBytes: record.totalBytes ?? 0)
  publisher.send(initial)
}
```

Resume at launch:
```swift
public func resumePendingDownloads() {
  Task {
    let records = try await DownloadStore.shared.fetchPending()
    for record in records { startDownload(from: record) }
  }
}
```

## App startup hooks
- iOS: `apple/InlineIOS/AppDelegate.swift` in `didFinishLaunchingWithOptions`:
```swift
FileDownloader.shared.resumePendingDownloads()
```
- macOS: `apple/InlineMac/App/AppDelegate.swift` in `applicationDidFinishLaunching`:
```swift
FileDownloader.shared.resumePendingDownloads()
```

## Open decisions
1) Cancel behavior: pause (keep partial/resumable) vs discard (delete partial + record).
2) CDN URL expiry: if short‑lived, add a refresh step before resuming.
3) Auto‑resume on launch (default) vs only user‑triggered.
4) Integrity: size check only vs hash verification.

## Manual test plan
- Start a large download, force‑quit app, relaunch, verify resume continues.
- Validate response status handling (200/206/416) and fallback behavior.
- Verify update of `localPath` and UI progress refresh.
