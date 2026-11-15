import Foundation
import GRDB
import Logger

/// Moves media cached before macOS scoped the cache root by bundle and profile.
///
/// Older builds kept media in `Application Support/{Photos,Videos,Documents,Voices}`. On the
/// unsandboxed Direct build those folders are shared with every other app, so only files this
/// database references (plus native partial downloads, which carry our own suffix) are moved.
/// Nothing else in the old folders is touched.
enum LegacyMediaCacheMigration {
  static let markerName = ".legacy-media-moved-v1"
  static let kinds: [FileLocalCacheDirectory] = [.photos, .videos, .documents, .voices]

  private static let log = Log.scoped("LegacyMediaCacheMigration")

  struct Result: Equatable {
    var moved = 0
    /// Already present at the destination, or not a plain file name.
    var skipped = 0
    var failed = 0
  }

  /// Runs once per media root, synchronously, right after the database opens.
  static func runIfNeeded(database: AppDatabase) {
    #if os(macOS)
    let fileManager = FileManager.default
    let legacyRoot = FileHelpers.getApplicationSupportDirectory()
    let newRoot = FileHelpers.mediaCacheRoot()
    guard legacyRoot.standardizedFileURL != newRoot.standardizedFileURL else { return }
    let marker = newRoot.appendingPathComponent(markerName)
    guard !fileManager.fileExists(atPath: marker.path) else { return }

    let hasLegacyFolders = kinds.contains {
      fileManager.fileExists(atPath: legacyRoot.appendingPathComponent(FileHelpers.cacheFolderName(for: $0)).path)
    }
    if hasLegacyFolders {
      let span = PerformanceTrace.begin("LegacyMediaCacheMigration", category: .launch)
      let referenced: [FileLocalCacheDirectory: Set<String>]
      do {
        referenced = try database.dbWriter.read { db in try referencedLocalPaths(db) }
      } catch {
        span.end("success=0")
        log.error("Failed to read cached media paths; will retry next launch", error: error)
        return
      }
      let result = moveReferencedFiles(from: legacyRoot, to: newRoot, referenced: referenced)
      span.end("moved=\(result.moved) skipped=\(result.skipped) failed=\(result.failed)")
      log.info("Moved legacy media: moved=\(result.moved) skipped=\(result.skipped) failed=\(result.failed)")
      // Leave the marker unwritten so the remaining files move on a later launch.
      guard result.failed == 0 else { return }
    }

    do {
      try fileManager.createDirectory(at: newRoot, withIntermediateDirectories: true)
      try Data().write(to: marker, options: .atomic)
    } catch {
      log.error("Failed to record legacy media migration", error: error)
    }
    #endif
  }

  /// Relative cache paths the database points to, by media folder.
  static func referencedLocalPaths(_ db: Database) throws -> [FileLocalCacheDirectory: Set<String>] {
    func paths(_ table: String, _ column: String) throws -> [String] {
      try String.fetchAll(
        db,
        sql: "SELECT \(column) FROM \(table) WHERE \(column) IS NOT NULL AND \(column) != ''"
      )
    }

    var photos = Set(try paths(PhotoSize.databaseTableName, "localPath"))
    photos.formUnion(try paths(User.databaseTableName, "profileLocalPath"))

    var voices = Set<String>()
    let cursor = try Message.filter(sql: "contentPayload IS NOT NULL").fetchCursor(db)
    while let message = try cursor.next() {
      if let localPath = message.voiceLocalRelativePath { voices.insert(localPath) }
    }

    return [
      .photos: photos,
      .videos: Set(try paths(Video.databaseTableName, "localPath")),
      .documents: Set(try paths(Document.databaseTableName, "localPath")),
      .voices: voices,
    ]
  }

  /// Moves each referenced file, and native partial downloads, from the legacy folders into
  /// the new root. Never overwrites, never deletes, never touches unreferenced files.
  static func moveReferencedFiles(
    from legacyRoot: URL,
    to newRoot: URL,
    referenced: [FileLocalCacheDirectory: Set<String>],
    fileManager: FileManager = .default
  ) -> Result {
    var result = Result()
    for kind in kinds {
      let folder = FileHelpers.cacheFolderName(for: kind)
      let source = legacyRoot.appendingPathComponent(folder, isDirectory: true)
      guard fileManager.fileExists(atPath: source.path) else { continue }

      var names = referenced[kind] ?? []
      if kind == .documents || kind == .videos {
        // Native partial downloads carry our own suffix; moving them keeps their progress.
        let contents = (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? []
        names.formUnion(contents.filter {
          $0.hasSuffix(".inline-partial") || $0.hasSuffix(".inline-partial.json")
        })
      }
      guard !names.isEmpty else { continue }

      let destination = newRoot.appendingPathComponent(folder, isDirectory: true)
      do {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
      } catch {
        result.failed += names.count
        continue
      }

      for name in names {
        guard isPlainFileName(name) else {
          result.skipped += 1
          continue
        }
        let from = source.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: from.path) else { continue }
        let to = destination.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: to.path) else {
          result.skipped += 1
          continue
        }
        do {
          try fileManager.moveItem(at: from, to: to)
          result.moved += 1
        } catch {
          result.failed += 1
        }
      }
    }
    return result
  }

  /// Cache paths are flat names. Anything with a separator or a parent reference could
  /// resolve outside our folders, so it is never moved.
  static func isPlainFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }
}
