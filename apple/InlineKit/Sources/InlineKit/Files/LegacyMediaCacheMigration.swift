import Foundation
import GRDB
import InlineConfig
import Logger

/// Moves media cached before macOS scoped the cache root by bundle and profile.
///
/// Older builds used Application Support, then shared Media/default between two profiles.
/// Copy files from shared profile storage so each database can recover its references independently.
enum LegacyMediaCacheMigration {
  static let markerName = ".legacy-media-moved-v2"
  static let kinds: [FileLocalCacheDirectory] = [.photos, .videos, .documents, .voices]

  private static let log = Log.scoped("LegacyMediaCacheMigration")

  struct Result: Equatable {
    var transferred = 0
    /// Already present at the destination, or not a plain file name.
    var skipped = 0
    var failed = 0
  }

  /// Runs once per media root, synchronously, right after the database opens.
  static func runIfNeeded(database: AppDatabase) {
    #if os(macOS)
    let support = FileHelpers.getApplicationSupportDirectory()
    let profile = ProjectConfig.userProfile
    let oldRoot = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "chat.inline", isDirectory: true)
      .appendingPathComponent("Media", isDirectory: true)
      .appendingPathComponent(profile.flatMap { $0.isEmpty ? nil : $0 } ?? "default", isDirectory: true)
    let newRoot = FileHelpers.mediaCacheRoot()
    runIfNeeded(database: database, legacyRoot: support, newRoot: newRoot,
                sharedRoot: oldRoot == newRoot ? nil : oldRoot)
    #endif
  }

  static func runIfNeeded(database: AppDatabase, legacyRoot: URL, newRoot: URL, sharedRoot: URL? = nil) {
    #if os(macOS)
    let fileManager = FileManager.default
    guard legacyRoot.standardizedFileURL != newRoot.standardizedFileURL else { return }
    let marker = newRoot.appendingPathComponent(markerName)
    guard !fileManager.fileExists(atPath: marker.path) else { return }

    let hasLegacyFolders = kinds.contains {
      fileManager.fileExists(atPath: legacyRoot.appendingPathComponent(FileHelpers.cacheFolderName(for: $0)).path)
    }
    let sharedSource = sharedRoot.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
    if hasLegacyFolders || sharedSource != nil {
      let span = PerformanceTrace.begin("LegacyMediaCacheMigration", category: .launch)
      let referenced: [FileLocalCacheDirectory: Set<String>]
      let draftsComplete: Bool
      do {
        (referenced, draftsComplete) = try database.dbWriter.read { db in
          var complete = true
          let names = try MediaCacheSweep.referencedNames(db) { _ in complete = false }
          return (names, complete)
        }
      } catch {
        span.end("success=0")
        log.error("Failed to read cached media paths; will retry next launch", error: error)
        return
      }
      // Prefer the most recent copy. Both databases may reference the same old file.
      if let sharedSource {
        let result = transferReferencedFiles(from: sharedSource, to: newRoot, referenced: referenced,
                                         includePartials: false, preserveSource: true)
        guard result.failed == 0 else {
          span.end("success=0")
          log.error("Failed to copy shared media; will retry next launch")
          return
        }
      }
      let v1Marker = newRoot.appendingPathComponent(".legacy-media-moved-v1")
      let needsPartials = sharedRoot == nil && !fileManager.fileExists(atPath: v1Marker.path)
      let result = transferReferencedFiles(from: legacyRoot, to: newRoot, referenced: referenced,
                                       includePartials: needsPartials, preserveSource: sharedRoot != nil)
      span.end("transferred=\(result.transferred) skipped=\(result.skipped) failed=\(result.failed)")
      log.info("Recovered legacy media: transferred=\(result.transferred) skipped=\(result.skipped) failed=\(result.failed)")
      // Leave the marker unwritten so the remaining files move on a later launch.
      guard result.failed == 0, draftsComplete else {
        log.warning("Media migration incomplete; will retry remaining files next launch")
        return
      }
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

  /// Recover referenced files without overwriting newer copies. Shared sources stay available to other profiles.
  static func transferReferencedFiles(
    from legacyRoot: URL,
    to newRoot: URL,
    referenced: [FileLocalCacheDirectory: Set<String>],
    includePartials: Bool = true,
    preserveSource: Bool = false,
    fileManager: FileManager = .default
  ) -> Result {
    var result = Result()
    for kind in kinds {
      let folder = FileHelpers.cacheFolderName(for: kind)
      let source = legacyRoot.appendingPathComponent(folder, isDirectory: true)
      guard fileManager.fileExists(atPath: source.path) else { continue }

      var names = referenced[kind] ?? []
      if includePartials && (kind == .documents || kind == .videos) {
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
          if preserveSource {
            let values = try from.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
              result.skipped += 1
              continue
            }
            // A crash during copying must not leave a partial file at the final name.
            let temp = destination.appendingPathComponent(".migration-" + UUID().uuidString)
            defer { try? fileManager.removeItem(at: temp) }
            try fileManager.copyItem(at: from, to: temp)
            try fileManager.moveItem(at: temp, to: to)
          } else {
            try fileManager.moveItem(at: from, to: to)
          }
          result.transferred += 1
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
