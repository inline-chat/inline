import Foundation
import GRDB
import Testing
@testable import InlineKit

@Suite("Storage usage")
struct StorageUsageTests {
  @Test func groupsDownloadsByCategoryAndChatAndProtectsUnsentMedia() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let report = try await fixture.service.scan()

    #expect(report.count(for: .files) == 2)
    #expect(report.count(for: .other) == 1)

    let sent = try #require(report.items.first { $0.id.fileName == "sent.pdf" })
    #expect(sent.displayName == "Report.pdf")
    #expect(sent.chatId == 7)
    #expect(sent.isRemovable)

    let unsent = try #require(report.items.first { $0.id.fileName == "unsent.pdf" })
    #expect(unsent.protection == .unsent)

    // Nothing refers to it yet and it just arrived: an upload being prepared.
    let orphan = try #require(report.items.first { $0.id.fileName == "orphan.pdf" })
    #expect(orphan.protection == .recent)
    #expect(orphan.category == .other)

    let chat = try #require(report.chats.first)
    #expect(chat.chatId == 7)
    #expect(chat.title == "Design")
    #expect(report.bytes(for: .files) == sent.bytes + unsent.bytes)
    #expect(chat.bytes == sent.bytes + unsent.bytes)
    #expect(chat.removableBytes == sent.bytes)
  }

  @Test func removingADownloadClearsItsPointerAndKeepsProtectedFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    // Two hours on, the orphan is no longer new.
    let later = Date().addingTimeInterval(2 * 60 * 60)
    let report = try await fixture.service.scan(now: later)
    let result = try await fixture.service.remove(report.items, now: later)

    // The sent file and the orphan go; the unsent message's file stays.
    #expect(result.removed == 2)
    #expect(result.skipped == 1)
    #expect(!fixture.exists(.documents, "sent.pdf"))
    #expect(!fixture.exists(.documents, "orphan.pdf"))
    #expect(fixture.exists(.documents, "unsent.pdf"))

    let paths = try await fixture.database.dbWriter.read { db in
      try Document.order(Column("documentId")).fetchAll(db).map(\.localPath)
    }
    #expect(paths == [nil, "unsent.pdf"])
  }

  @Test func keepMediaOnlyExpiresChatDownloads() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }

    let later = Date().addingTimeInterval(10 * 24 * 60 * 60)
    let report = try await fixture.service.scan(now: later)
    let expired = StorageUsageService.cleanupItems(in: report, keepMedia: .week, cacheLimit: .unlimited, now: later)
    #expect(expired.map(\.id.fileName) == ["sent.pdf"])
    #expect(StorageUsageService.cleanupItems(in: report, keepMedia: .forever, cacheLimit: .unlimited, now: later).isEmpty)
  }

  @Test func cacheLimitRemovesTheLeastRecentlyUsedChatDownloadsFirst() {
    func item(_ name: String, bytes: Int64, daysAgo: Double, chatId: Int64? = 7, protection: StorageItem.Protection? = nil) -> StorageItem {
      StorageItem(
        id: .init(folder: .documents, fileName: name), category: chatId == nil ? .other : .files,
        displayName: name, url: URL(fileURLWithPath: "/tmp/\(name)"), bytes: bytes,
        fileDate: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60), messageDate: nil,
        chatId: chatId, messageId: chatId == nil ? nil : 1, isProfilePhoto: false, protection: protection
      )
    }
    let gb: Int64 = 1_000_000_000
    let report = StorageUsageReport(
      items: [
        item("newest", bytes: gb, daysAgo: 1),
        item("oldest", bytes: gb, daysAgo: 30),
        item("middle", bytes: gb, daysAgo: 10),
        item("unsent", bytes: gb, daysAgo: 60, protection: .unsent),
        item("orphan", bytes: gb, daysAgo: 90, chatId: nil),
      ],
      chats: [], databaseBytes: 0, scannedAt: Date()
    )
    // 5 GB of downloads; the unsent and the orphan can't go, so 1 GB is out of reach and every
    // chat download goes, oldest first. At 5 GB nothing is over.
    let removed = StorageUsageService.cleanupItems(in: report, keepMedia: .forever, cacheLimit: .gb1, now: Date())
    #expect(removed.map(\.id.fileName) == ["oldest", "middle", "newest"])
    let trimmed = StorageUsageService.cleanupItems(in: report, keepMedia: .forever, cacheLimit: .gb5, now: Date())
    #expect(trimmed.isEmpty)
  }

  @Test func filesTheFileTablePointsAtStay() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try await fixture.database.dbWriter.write { db in
      try db.execute(
        sql: "INSERT INTO \(File.databaseTableName) (id, fileUniqueId, fileType, localPath) VALUES ('f1', 'f1', 'document', 'orphan.pdf')"
      )
    }
    let later = Date().addingTimeInterval(2 * 60 * 60)
    let report = try await fixture.service.scan(now: later)
    let orphan = try #require(report.items.first { $0.id.fileName == "orphan.pdf" })
    #expect(orphan.protection == .inUse)
    _ = try await fixture.service.remove(report.items, now: later)
    #expect(fixture.exists(.documents, "orphan.pdf"))
  }

  private struct Fixture {
    let root: URL
    let folders: [FileLocalCacheDirectory: URL]
    let database: AppDatabase
    let service: StorageUsageService

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("storage-usage-\(UUID().uuidString)", isDirectory: true)
      let root = root
      folders = Dictionary(uniqueKeysWithValues: LegacyMediaCacheMigration.kinds.map {
        ($0, root.appendingPathComponent(FileHelpers.cacheFolderName(for: $0), isDirectory: true))
      })
      database = AppDatabase.empty()
      let database = database
      let folders = folders
      service = StorageUsageService(database: { database }, folders: { folders })

      try database.dbWriter.write { db in
        try User(id: 1, email: nil, firstName: "Mo").insert(db)
        try Chat(id: 7, date: Date(), type: .thread, title: "Design", spaceId: nil).insert(db)
        try Document(
          id: 1, documentId: 50, date: Date(), fileName: "Report.pdf", mimeType: "application/pdf", size: 4,
          localPath: "sent.pdf"
        ).insert(db)
        try Document(
          id: 2, documentId: 51, date: Date(), fileName: "Draft.pdf", mimeType: "application/pdf", size: 4,
          localPath: "unsent.pdf"
        ).insert(db)
        try Message(
          messageId: 10, fromId: 1, date: Date(), text: nil, peerUserId: nil, peerThreadId: 7, chatId: 7,
          status: .sent, documentId: 50
        ).insert(db)
        try Message(
          messageId: -11, fromId: 1, date: Date(), text: nil, peerUserId: nil, peerThreadId: 7, chatId: 7,
          out: true, status: .sending, documentId: 51
        ).insert(db)
      }

      let old = Date().addingTimeInterval(-2 * 60 * 60)
      try write(.documents, "sent.pdf", date: old)
      try write(.documents, "unsent.pdf", date: old)
      try write(.documents, "orphan.pdf", date: old)
    }

    func write(_ folder: FileLocalCacheDirectory, _ name: String, date: Date) throws {
      let directory = folders[folder]!
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(name)
      try Data("data".utf8).write(to: url)
      try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    func exists(_ folder: FileLocalCacheDirectory, _ name: String) -> Bool {
      FileManager.default.fileExists(atPath: folders[folder]!.appendingPathComponent(name).path)
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
  }
}
