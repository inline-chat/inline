import Foundation
import GRDB
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Media cache sweep")
struct MediaCacheSweepTests {
  /// Files can't be backdated past their arrival (the attribute change date), so the sweeps
  /// here run eight days from now: a file written now is old, one dated `now` is fresh.
  private let now = Date().addingTimeInterval(8 * 24 * 60 * 60)
  private let old = Date()

  @Test func removesOnlyWeekOldFilesThatNothingRefersTo() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folders = folders(in: root)
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try Document(
        id: 1, documentId: 52, date: Date(), fileName: "kept.pdf", mimeType: "application/pdf", size: 4,
        localPath: "kept.pdf"
      ).save(db)
      try saveDraft(db, media: .voice(.with { $0.voiceID = -1; $0.localRelativePath = "draft-voice.m4a" }))
    }
    let kept = [
      try write(folders[.voices]!, "draft-voice.m4a", modified: old),
      try write(folders[.documents]!, "kept.pdf", modified: old),
      try write(folders[.documents]!, "fresh.pdf", modified: now),
      try write(folders[.documents]!, "IND_1.inline-partial", modified: old),
      try write(folders[.documents]!, "IND_1.inline-partial.json", modified: old),
      try write(folders[.photos]!, ".native-ABC", modified: old),
      // A photo name the voices folder refers to is still unreferenced in photos, and vice versa.
      try write(folders[.photos]!, "fresh-avatar.jpg", modified: now),
    ]
    let removed = [
      try write(folders[.documents]!, "orphan.pdf", modified: old),
      try write(folders[.videos]!, "orphan.mp4", modified: old),
      try write(folders[.photos]!, "draft-voice.m4a", modified: old),
    ]

    let result = MediaCacheSweep.runIfDue(database: database, root: root, now: now, folders: folders)
    #expect(result == .init(removed: 3, removedBytes: 12, failed: 0))
    for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
    for url in removed { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }

    // Once a day.
    #expect(MediaCacheSweep.runIfDue(database: database, root: root, now: now, folders: folders) == nil)
    let later = now.addingTimeInterval(2 * 24 * 60 * 60)
    #expect(MediaCacheSweep.runIfDue(database: database, root: root, now: later, folders: folders) == .init())
  }

  @Test func aDraftThatCannotBeReadStopsTheSweep() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folders = folders(in: root)
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      try db.execute(
        sql: "INSERT INTO \(Drafts2Row.databaseTableName) (peerKey, text, attachments, updatedAt, revision) VALUES (?, '', ?, 0, 1)",
        arguments: ["user_9", Data("not json".utf8)]
      )
    }
    let orphan = try write(folders[.documents]!, "orphan.pdf", modified: old)
    #expect(MediaCacheSweep.runIfDue(database: database, root: root, now: now, folders: folders) == nil)
    #expect(FileManager.default.fileExists(atPath: orphan.path))
    // It tries again tomorrow, not on every launch.
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(MediaCacheSweep.stampName).path))
  }

  @Test func aFileThatJustArrivedWithOldDatesIsKept() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folders = folders(in: root)
    // A copy keeps its source's dates; it arrived now all the same.
    let copied = try write(folders[.videos]!, "attached.mp4", modified: Date().addingTimeInterval(-90 * 24 * 60 * 60))
    #expect(MediaCacheSweep.runIfDue(database: AppDatabase.empty(), root: root, folders: folders) == .init())
    #expect(FileManager.default.fileExists(atPath: copied.path))
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("media-sweep-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func folders(in root: URL) -> [FileLocalCacheDirectory: URL] {
    Dictionary(uniqueKeysWithValues: MediaCacheSweep.kinds.map {
      ($0, root.appendingPathComponent(FileHelpers.cacheFolderName(for: $0), isDirectory: true))
    })
  }

  private func write(_ folder: URL, _ name: String, modified: Date) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data("data".utf8).write(to: url)
    try FileManager.default.setAttributes([.creationDate: modified, .modificationDate: modified], ofItemAtPath: url.path)
    return url
  }

  private func saveDraft(_ db: Database, media: FileMediaItem) throws {
    let blob = Drafts2AttachmentBlob(attachments: [Drafts2Attachment(id: "a", media: media)])
    try db.execute(
      sql: "INSERT INTO \(Drafts2Row.databaseTableName) (peerKey, text, attachments, updatedAt, revision) VALUES (?, '', ?, 0, 1)",
      arguments: ["user_5", blob.databaseValue]
    )
  }
}
