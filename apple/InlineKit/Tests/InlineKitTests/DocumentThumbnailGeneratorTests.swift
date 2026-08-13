import CoreGraphics
import Foundation
import GRDB
import InlineThumbnailing
import Testing

@testable import InlineKit

@Suite("Document thumbnails")
struct DocumentThumbnailGeneratorTests {
  @Test("renders the first PDF page within the bounded pixel size")
  func rendersPDFPreview() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-document-thumbnail-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }

    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 40, y: 40, width: 532, height: 712))
    context.endPDFPage()
    context.closePDF()

    let artifact = try #require(await DocumentThumbnailer().thumbnail(
      for: url,
      policy: ThumbnailPolicy(enabledCohorts: [.core])
    ))

    #expect(artifact.pixelWidth > 0)
    #expect(artifact.pixelHeight > 0)
    #expect(max(artifact.pixelWidth, artifact.pixelHeight) <= 320)
  }

  @Test("fails soft for unsupported documents")
  func ignoresUnsupportedDocument() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-document-thumbnail-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("hello".utf8).write(to: url)

    #expect(await DocumentThumbnailer().thumbnail(
      for: url,
      policy: ThumbnailPolicy(enabledCohorts: [.core])
    ) == nil)
  }

  @Test("links a local thumbnail to its document")
  func linksThumbnailToDocument() throws {
    let queue = try DatabaseQueue()
    try queue.write { db in
      try db.create(table: "photo") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("photoId", .integer).unique()
        table.column("date", .datetime).notNull()
        table.column("format", .text).notNull()
      }
      try db.create(table: "photoSize") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("photoId", .integer).notNull().references("photo", column: "id")
        table.column("type", .text).notNull()
        table.column("width", .integer)
        table.column("height", .integer)
        table.column("size", .integer)
        table.column("bytes", .blob)
        table.column("cdnUrl", .text)
        table.column("localPath", .text)
      }
      try db.create(table: "document") { table in
        table.autoIncrementedPrimaryKey("id")
        table.column("documentId", .integer).unique()
        table.column("date", .datetime).notNull()
        table.column("fileName", .text)
        table.column("mimeType", .text)
        table.column("size", .integer)
        table.column("cdnUrl", .text)
        table.column("localPath", .text)
        table.column("thumbnailPhotoId", .integer).references("photo", column: "id")
      }

      let photo = try Photo(photoId: -1, format: .jpeg).insertAndFetch(db)
      let photoSize = try PhotoSize(
        photoId: try #require(photo.id),
        width: 240,
        height: 320,
        localPath: "thumbnail.jpg"
      ).insertAndFetch(db)
      let thumbnail = PhotoInfo(photo: photo, sizes: [photoSize])

      let document = try Document.createLocalDocument(
        db,
        fileName: "example.pdf",
        mimeType: "application/pdf",
        size: 42,
        localPath: "document.pdf",
        thumbnail: thumbnail
      )

      #expect(document.thumbnail == thumbnail)
      #expect(document.document.thumbnailPhotoId == photo.id)
    }
  }
}
