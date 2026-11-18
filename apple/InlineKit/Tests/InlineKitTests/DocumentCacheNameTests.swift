import Foundation
import GRDB
import Testing
@testable import InlineKit

@Suite struct DocumentCacheNameTests {
  @Test func incomingDocumentsUseIndependentFlatNames() throws {
    for displayName in ["meeting notes.pdf", "folder/notes.pdf", #"folder\notes.pdf"#, "report", "notes.📝"] {
      let document = Document(documentId: 17, date: Date(), fileName: displayName)
      let name = document.newDownloadCacheName()
      let url = URL(fileURLWithPath: "/cache").appendingPathComponent(name)
      #expect(url.deletingLastPathComponent().path == "/cache")
      #expect(UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil)
      #expect(url.pathExtension == (displayName == "meeting notes.pdf" ? "pdf" : ""))
      #expect(name != document.newDownloadCacheName())
      #expect(document.fileName == displayName)
    }
  }

  @Test func legacyAppleFilenameRemainsReadableAndGetsAPortableUploadName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileName = #"week 1\notes.pdf"#
    let localPath = UUID().uuidString + "-" + fileName
    let bytes = Data("saved document".utf8)
    try bytes.write(to: root.appendingPathComponent(localPath))
    let database = AppDatabase.empty()
    let stored = try database.dbWriter.write { db in
      try Document(documentId: 17, date: Date(), fileName: fileName, localPath: localPath).insertAndFetch(db)
    }
    let draft = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(stored))
    let restoredPath = try #require(draft.localPath)
    let restoredURL = root.appendingPathComponent(restoredPath)
    #expect(restoredURL.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    #expect(try Data(contentsOf: restoredURL) == bytes)
    #expect(draft.fileName == fileName)
    let upload = NativeMediaUploadRequest(
      logicalID: "draft", fileURL: restoredURL, fileName: try #require(draft.fileName),
      mimeType: "application/pdf", kind: .document
    )
    #expect(upload.fileName == "week 1_notes.pdf")
    #expect(upload.fileURL == restoredURL)
  }

  @Test func persistedDocumentPathsMustBeSingleFileNames() throws {
    let database = AppDatabase.empty()
    try database.dbWriter.write { db in
      for (index, path) in ["old_report.pdf", "folder/report.pdf", ".", ""].enumerated() {
        let document = Document(documentId: Int64(index + 1), date: Date(), localPath: path)
        let stored = try document.insertAndFetch(db)
        let draft = try JSONDecoder().decode(Document.self, from: JSONEncoder().encode(document))
        let expected = index == 0 ? path : nil
        #expect(stored.localPath == expected)
        #expect(draft.localPath == expected)
      }
    }
  }
}
