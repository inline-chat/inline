import Foundation
import InlineKit
import Testing

@Suite("PhotoInfo")
struct PhotoInfoTests {
  @Test("bestPhotoSize ignores stripped bytes when a regular photo size exists")
  func ignoresStrippedSizeForDisplaySelection() {
    let photo = Photo(photoId: 42, format: .jpeg)
    let info = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 1, type: "s", width: 40, height: 30, size: 6, bytes: Data([1, 30, 40, 1, 2, 3])),
        PhotoSize(photoId: 1, type: "c", width: 320, height: 240, size: 12_000, cdnUrl: "https://example.com/c"),
        PhotoSize(photoId: 1, type: "f", width: 1280, height: 960, size: 96_000, cdnUrl: "https://example.com/f"),
      ]
    )

    #expect(info.bestPhotoSize()?.type == "f")
  }

  @Test("bestPhotoSize prefers the largest non-stripped legacy size")
  func prefersLargestLegacySize() {
    let photo = Photo(photoId: 43, format: .jpeg)
    let info = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 1, type: "s", width: 40, height: 30, size: 6, bytes: Data([1, 30, 40, 1, 2, 3])),
        PhotoSize(photoId: 1, type: "b", width: 140, height: 140, size: 4_000, cdnUrl: "https://example.com/b"),
        PhotoSize(photoId: 1, type: "d", width: 800, height: 600, size: 48_000, cdnUrl: "https://example.com/d"),
      ]
    )

    #expect(info.bestPhotoSize()?.type == "d")
  }

  @Test("bestPhotoSize does not let a smaller cached size outrank a larger remote size")
  func keepsLargestRegularSizeAsPrimarySelection() {
    let photo = Photo(photoId: 45, format: .jpeg)
    let info = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 1, type: "s", width: 40, height: 30, size: 6, bytes: Data([1, 30, 40, 1, 2, 3])),
        PhotoSize(photoId: 1, type: "b", width: 140, height: 140, size: 4_000, cdnUrl: "https://example.com/b", localPath: "b.jpg"),
        PhotoSize(photoId: 1, type: "f", width: 1280, height: 960, size: 96_000, cdnUrl: "https://example.com/f"),
      ]
    )

    #expect(info.bestPhotoSize()?.type == "f")
  }

  @Test("bestPhotoSize falls back to stripped when it is the only available size")
  func fallsBackToStrippedWhenNeeded() {
    let photo = Photo(photoId: 44, format: .jpeg)
    let info = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 1, type: "s", width: 40, height: 30, size: 6, bytes: Data([1, 30, 40, 1, 2, 3])),
      ]
    )

    #expect(info.bestPhotoSize()?.type == "s")
  }
}
