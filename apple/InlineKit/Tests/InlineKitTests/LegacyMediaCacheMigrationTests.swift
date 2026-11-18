import Foundation
import Testing

@testable import InlineKit

@Suite("Legacy media cache migration")
struct LegacyMediaCacheMigrationTests {
  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("media-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
  }

  #if os(macOS)
  @Test("macOS media root is scoped by bundle and profile")
  func scopedRoot() {
    let support = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
    let scoped = FileHelpers.mediaCacheRoot(
      applicationSupportDirectory: support,
      bundleIdentifier: "chat.inline.InlineMac",
      userProfile: "work"
    )
    #expect(scoped == support
      .appendingPathComponent("chat.inline.InlineMac", isDirectory: true)
      .appendingPathComponent("Media", isDirectory: true)
      .appendingPathComponent("work", isDirectory: true))

    let defaultProfile = FileHelpers.mediaCacheRoot(
      applicationSupportDirectory: support,
      bundleIdentifier: "chat.inline.InlineMac",
      userProfile: nil
    )
    let namedDefault = FileHelpers.mediaCacheRoot(
      applicationSupportDirectory: support, bundleIdentifier: "chat.inline.InlineMac", userProfile: "default"
    )
    #expect(defaultProfile != namedDefault)
    #expect(!defaultProfile.path.contains("/Media/default"))
    #expect(!namedDefault.path.contains("/Media/default"))
    #expect(defaultProfile != support)
  }
  #endif

  @Test("moves only referenced files and our partials, leaves everything else")
  func movesOnlyOurs() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("Application Support", isDirectory: true)
    let scoped = legacy.appendingPathComponent("chat.inline/Media/default", isDirectory: true)

    try write("photo", to: legacy.appendingPathComponent("Photos/IMG-server-1-y.jpg"))
    try write("other app", to: legacy.appendingPathComponent("Photos/holiday.jpg"))
    try write("doc", to: legacy.appendingPathComponent("Documents/ABC_report.pdf"))
    try write("partial", to: legacy.appendingPathComponent("Documents/IND_1.inline-partial"))
    try write("record", to: legacy.appendingPathComponent("Documents/IND_1.inline-partial.json"))
    try write("other doc", to: legacy.appendingPathComponent("Documents/taxes.pdf"))
    try write("voice", to: legacy.appendingPathComponent("Voices/V1.m4a"))

    let result = LegacyMediaCacheMigration.transferReferencedFiles(
      from: legacy,
      to: scoped,
      referenced: [
        .photos: ["IMG-server-1-y.jpg"],
        .documents: ["ABC_report.pdf", "missing.pdf"],
        .voices: ["V1.m4a"],
      ]
    )

    #expect(result == .init(transferred: 5, skipped: 0, failed: 0))
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: scoped.appendingPathComponent("Photos/IMG-server-1-y.jpg").path))
    #expect(fm.fileExists(atPath: scoped.appendingPathComponent("Documents/ABC_report.pdf").path))
    #expect(fm.fileExists(atPath: scoped.appendingPathComponent("Documents/IND_1.inline-partial").path))
    #expect(fm.fileExists(atPath: scoped.appendingPathComponent("Documents/IND_1.inline-partial.json").path))
    #expect(fm.fileExists(atPath: scoped.appendingPathComponent("Voices/V1.m4a").path))
    // Files this database does not reference stay exactly where they were.
    #expect(fm.fileExists(atPath: legacy.appendingPathComponent("Photos/holiday.jpg").path))
    #expect(fm.fileExists(atPath: legacy.appendingPathComponent("Documents/taxes.pdf").path))
    #expect(!fm.fileExists(atPath: scoped.appendingPathComponent("Photos/holiday.jpg").path))
  }

  @Test("never overwrites an existing destination and rejects paths outside the folder")
  func noOverwriteAndPlainNamesOnly() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("support", isDirectory: true)
    let scoped = root.appendingPathComponent("scoped", isDirectory: true)

    try write("old", to: legacy.appendingPathComponent("Videos/a.mp4"))
    try write("new", to: scoped.appendingPathComponent("Videos/a.mp4"))
    try write("secret", to: legacy.appendingPathComponent("secret.txt"))

    let result = LegacyMediaCacheMigration.transferReferencedFiles(
      from: legacy,
      to: scoped,
      referenced: [.videos: ["a.mp4", "../secret.txt"]]
    )

    #expect(result == .init(transferred: 0, skipped: 2, failed: 0))
    let kept = try String(contentsOf: scoped.appendingPathComponent("Videos/a.mp4"), encoding: .utf8)
    #expect(kept == "new")
    #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Videos/a.mp4").path))
    #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("secret.txt").path))
  }
}
