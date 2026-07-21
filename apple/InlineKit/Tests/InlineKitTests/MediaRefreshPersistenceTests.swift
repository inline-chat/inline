import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Media refresh persistence")
struct MediaRefreshPersistenceTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("photo refresh preserves cached path and row identity when CDN URL rotates")
  func photoRefreshPreservesLocalCacheAssociation() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      let initial = makePhoto(cdnURL: "https://cdn.example.com/photo.jpg?signature=first")
      let savedPhoto = try Photo.updateFromProtocol(db, protoPhoto: initial)
      let photoRowID = try #require(savedPhoto.id)

      let storedFullSize = try PhotoSize
        .filter(PhotoSize.Columns.photoId == photoRowID)
        .filter(PhotoSize.Columns.type == "f")
        .fetchOne(db)
      var fullSize = try #require(storedFullSize)
      let fullSizeRowID = try #require(fullSize.id)
      fullSize.localPath = "IMGf42.jpeg"
      try fullSize.update(db)

      let refreshed = makePhoto(cdnURL: "https://cdn.example.com/photo.jpg?signature=second")
      let refreshedPhoto = try Photo.updateFromProtocol(db, protoPhoto: refreshed)
      let storedRefreshedFullSize = try PhotoSize
        .filter(PhotoSize.Columns.photoId == photoRowID)
        .filter(PhotoSize.Columns.type == "f")
        .fetchOne(db)
      let refreshedFullSize = try #require(storedRefreshedFullSize)

      #expect(refreshedPhoto.id == photoRowID)
      #expect(refreshedFullSize.id == fullSizeRowID)
      #expect(refreshedFullSize.localPath == "IMGf42.jpeg")
      #expect(refreshedFullSize.cdnUrl == "https://cdn.example.com/photo.jpg?signature=second")
      #expect(try PhotoSize.filter(PhotoSize.Columns.photoId == photoRowID).fetchCount(db) == 2)
    }
  }

  private func makePhoto(cdnURL: String) -> InlineProtocol.Photo {
    .with {
      $0.id = 42
      $0.date = 1_700_000_000
      $0.format = .jpeg
      $0.sizes = [
        .with {
          $0.type = "s"
          $0.w = 40
          $0.h = 30
          $0.size = 6
          $0.bytes = Data([1, 30, 40, 1, 2, 3])
        },
        .with {
          $0.type = "f"
          $0.w = 1_280
          $0.h = 960
          $0.size = 96_000
          $0.cdnURL = cdnURL
        },
      ]
    }
  }
}
