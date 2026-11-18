import Foundation
import GRDB
import Testing
@testable import InlineKit

@Suite struct DocumentCacheNameTests {
  @Test func incomingDocumentsUseIndependentFlatNames() throws {
    for displayName in ["meeting notes.pdf", "folder/notes.pdf", "report", "notes.📝"] {
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
