import Foundation
import GRDB
import InlineConfig
import Logger

/// Removes media files nothing refers to any more: files of deleted messages and chats,
/// replaced avatars, a download saved again under a new name. They are otherwise only removed
/// by Clear Cache, so they pile up.
///
/// A file stays when the database or a draft refers to it, when it is a hidden or partial
/// download file, or when it changed in the last week (it may be on its way to being
/// referenced: an upload being prepared, a download being finalized). If any draft cannot be
/// read, nothing is removed.
enum MediaCacheSweep {
  static let minimumAge: TimeInterval = 7 * 24 * 60 * 60
  static let interval: TimeInterval = 24 * 60 * 60
  static let launchDelay: Duration = .seconds(60)
  static let stampName = ".media-sweep-last-run"
  static let kinds = LegacyMediaCacheMigration.kinds

  private static let log = Log.scoped("MediaCacheSweep")

  struct Result: Equatable {
    var removed = 0
    var removedBytes: Int64 = 0
    var failed = 0
  }

  /// Sweeps once a day, a while after launch, off the main thread.
  static func scheduleIfDue(database: AppDatabase) {
    // Extensions do not own the cache. A profile named "default" shares the unnamed profile's
    // media folder but not its database, so neither could tell the other's files apart.
    guard !Bundle.main.bundlePath.hasSuffix(".appex"), ProjectConfig.userProfile != "default" else { return }
    Task.detached(priority: .background) {
      try? await Task.sleep(for: launchDelay)
      _ = runIfDue(database: database)
    }
  }

  @discardableResult
  static func runIfDue(
    database: AppDatabase, root: URL = FileHelpers.mediaCacheRoot(), now: Date = Date(),
    folders: [FileLocalCacheDirectory: URL]? = nil
  ) -> Result? {
    let stamp = root.appendingPathComponent(stampName)
    if let last = (try? stamp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
       now.timeIntervalSince(last) < interval, last <= now
    {
      return nil
    }
    let folders = folders ?? Dictionary(uniqueKeysWithValues: kinds.map {
      ($0, FileHelpers.getLocalCacheDirectory(for: $0, createIfNeeded: false))
    })
    // List first, then read references, so a reference added meanwhile is still seen.
    let candidates = oldFiles(in: folders, now: now)
    var result: Result?
    do {
      let referenced = try database.dbWriter.read { db in try referencedNames(db) }
      result = remove(candidates, keeping: referenced, now: now)
      log.info("Media sweep removed=\(result?.removed ?? 0) bytes=\(result?.removedBytes ?? 0) failed=\(result?.failed ?? 0)")
    } catch {
      // Removes nothing, and tries again tomorrow rather than on every launch.
      log.error("Skipping media sweep: references could not be read", error: error)
    }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data().write(to: stamp, options: .atomic)
      try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: stamp.path)
    } catch {
      log.error("Failed to record the media sweep", error: error)
    }
    return result
  }

  /// Every cache name the database or a draft refers to, by folder.
  static func referencedNames(_ db: Database) throws -> [FileLocalCacheDirectory: Set<String>] {
    var names = try LegacyMediaCacheMigration.referencedLocalPaths(db)
    // Never set today, and resolved elsewhere; kept in every folder to be safe.
    let files = try String.fetchAll(db, sql: "SELECT localPath FROM \(File.databaseTableName) WHERE localPath IS NOT NULL AND localPath != ''")
    for kind in kinds { names[kind, default: []].formUnion(files) }
    // A paused voice recording is referenced only by its draft.
    let blobs = try Data.fetchAll(
      db, sql: "SELECT attachments FROM \(Drafts2Row.databaseTableName) WHERE attachments IS NOT NULL"
    )
    for blob in blobs {
      // A draft that cannot be read might hold any file: throw, so nothing is removed.
      for attachment in try JSONDecoder().decode(Drafts2AttachmentBlob.self, from: blob).attachments {
        insert(attachment.media, into: &names)
      }
    }
    return names
  }

  private static func insert(_ media: FileMediaItem, into names: inout [FileLocalCacheDirectory: Set<String>]) {
    func add(_ kind: FileLocalCacheDirectory, _ name: String?) {
      guard let name, !name.isEmpty else { return }
      names[kind, default: []].insert(name)
    }
    switch media {
    case let .photo(photo):
      photo.sizes.forEach { add(.photos, $0.localPath) }
    case let .video(video):
      add(.videos, video.video.localPath)
      video.thumbnail?.sizes.forEach { add(.photos, $0.localPath) }
    case let .document(document):
      add(.documents, document.document.localPath)
      document.thumbnail?.sizes.forEach { add(.photos, $0.localPath) }
    case let .voice(voice):
      add(.voices, voice.localRelativePath.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  struct Candidate: Equatable {
    let kind: FileLocalCacheDirectory
    let url: URL
  }

  /// Plain files in the folders that have not changed for `minimumAge`.
  static func oldFiles(in folders: [FileLocalCacheDirectory: URL], now: Date) -> [Candidate] {
    folders.flatMap { kind, folder in
      let contents = (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )) ?? []
      return contents.compactMap { url -> Candidate? in
        guard isSweepable(url.lastPathComponent), isOld(url, now: now) else { return nil }
        return Candidate(kind: kind, url: url)
      }
    }
  }

  /// Hidden files (staging, markers) and native partials belong to their writers.
  static func isSweepable(_ name: String) -> Bool {
    LegacyMediaCacheMigration.isPlainFileName(name) && !name.hasPrefix(".") &&
      !name.hasSuffix(".inline-partial") && !name.hasSuffix(".inline-partial.json")
  }

  /// A copy or a rename keeps a file's creation and modification dates, so a file attached a
  /// moment ago can carry old ones; its attribute change date (ctime) is when it arrived.
  private static func isOld(_ url: URL, now: Date) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey,
      .attributeModificationDateKey,
    ]), values.isRegularFile == true, values.isSymbolicLink != true,
    let created = values.creationDate, let modified = values.contentModificationDate,
    let changed = values.attributeModificationDate
    else { return false }
    return now.timeIntervalSince(max(created, modified, changed)) >= minimumAge
  }

  private static func remove(
    _ candidates: [Candidate], keeping referenced: [FileLocalCacheDirectory: Set<String>], now: Date
  ) -> Result {
    var result = Result()
    for candidate in candidates where !(referenced[candidate.kind]?.contains(candidate.url.lastPathComponent) ?? false) {
      // Checked again right before removal: something may have just rewritten it.
      guard isOld(candidate.url, now: now) else { continue }
      let size = (try? candidate.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
      do {
        try FileManager.default.removeItem(at: candidate.url)
        result.removed += 1
        result.removedBytes += size
      } catch {
        result.failed += 1
      }
    }
    return result
  }
}
