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

  @Test("detached rich photo download updates the existing local size row")
  func detachedRichPhotoDownloadUsesLocalPhotoIdentity() throws {
    let dbQueue = try makeInMemoryDB()

    try dbQueue.write { db in
      var decoy = Photo(id: 42, photoId: 9_042, format: .png)
      try decoy.insert(db)
      var decoySize = PhotoSize(
        photoId: 42,
        type: "f",
        width: 64,
        height: 64,
        localPath: "decoy.png"
      )
      try decoySize.insert(db)

      let proto = makePhoto(cdnURL: "https://cdn.example.com/rich-photo.jpg")
      let savedPhoto = try Photo.updateFromProtocol(db, protoPhoto: proto)
      let localPhotoID = try #require(savedPhoto.id)
      #expect(localPhotoID != proto.id)
      var duplicateFullSize = PhotoSize(
        photoId: localPhotoID,
        type: "f",
        width: 640,
        height: 480,
        cdnUrl: "https://cdn.example.com/rich-photo-fallback.jpg"
      )
      try duplicateFullSize.insert(db)
      let beforeRows = try PhotoSize
        .filter(PhotoSize.Columns.photoId == localPhotoID)
        .fetchAll(db)
      let beforeTotal = try PhotoSize.fetchCount(db)
      let fullRowIDs = Set(beforeRows.filter { $0.type == "f" }.compactMap(\.id))
      #expect(fullRowIDs.count == 2)

      // Rich block planners build this detached projection directly from the
      // wire photo, so its size carries the server ID rather than the DB FK.
      let detached = PhotoInfo(
        photo: Photo.from(proto: proto),
        sizes: proto.sizes.map { PhotoSize.from(proto: $0, photoId: proto.id) }
      )
      try FileCache.persistDownloadedPhotoPath("IMGf42.jpg", for: detached, in: db)

      let afterRows = try PhotoSize
        .filter(PhotoSize.Columns.photoId == localPhotoID)
        .fetchAll(db)
      let fullRows = afterRows.filter { $0.type == "f" }
      #expect(Set(fullRows.compactMap(\.id)) == fullRowIDs)
      #expect(fullRows.allSatisfy { $0.localPath == "IMGf42.jpg" })
      #expect(afterRows.count == beforeRows.count)
      let afterTotal = try PhotoSize.fetchCount(db)
      #expect(afterTotal == beforeTotal)
      let storedDecoy = try PhotoSize
        .filter(PhotoSize.Columns.photoId == 42)
        .filter(PhotoSize.Columns.type == "f")
        .fetchOne(db)
      #expect(storedDecoy?.localPath == "decoy.png")
    }
  }

  @Test("download persistence fails closed when the server photo is absent")
  func detachedDownloadRequiresPersistedPhoto() throws {
    let dbQueue = try makeInMemoryDB()
    let detached = PhotoInfo(
      photo: Photo(photoId: 8_888, format: .jpeg),
      sizes: [PhotoSize(photoId: 8_888, type: "f", cdnUrl: "https://cdn.example.com/missing.jpg")]
    )

    try dbQueue.write { db in
      #expect(throws: FileCacheError.self) {
        try FileCache.persistDownloadedPhotoPath("IMGf8888.jpeg", for: detached, in: db)
      }
      let remainingSizeCount = try PhotoSize.fetchCount(db)
      #expect(remainingSizeCount == 0)
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
