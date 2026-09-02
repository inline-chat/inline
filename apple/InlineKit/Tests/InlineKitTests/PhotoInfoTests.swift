import Foundation
import InlineKit
import Testing

@Suite("PhotoInfo")
struct PhotoInfoTests {
  @Test("a metadata-only original cannot hide a usable smaller regular representation")
  func prefersLoadableRepresentationOverMetadata() {
    for local in [false, true] {
      let info = PhotoInfo(photo: Photo(photoId: 47, format: .jpeg), sizes: [
        PhotoSize(photoId: 47, type: "f", width: 1280, height: 960, size: 96_000, cdnUrl: "", localPath: ""),
        PhotoSize(photoId: 47, type: "c", width: 320, height: 240, size: 12_000,
                  cdnUrl: local ? nil : "https://example.com/c", localPath: local ? "c.jpg" : nil),
      ])
      #expect(info.hasDisplayablePreview)
      #expect(info.bestPhotoSize()?.type == "c")
    }
  }

  @Test("metadata-only photos retain their largest dimensions for placeholder layout")
  func metadataDimensions() {
    let info = PhotoInfo(photo: Photo(photoId: 48, format: .jpeg), sizes: [
      PhotoSize(photoId: 48, type: "c", width: 320, height: 240),
      PhotoSize(photoId: 48, type: "f", width: 1280, height: 960),
    ])
    #expect(!info.hasDisplayablePreview)
    #expect(info.bestPhotoSize()?.type == "f")
  }

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
    #expect(!info.hasDisplayablePreview)
  }

  @Test("displayable preview requires a loadable non-stripped representation")
  func displayablePreviewEligibility() {
    let photo = Photo(photoId: 46, format: .jpeg)
    let metadataOnly = PhotoInfo(
      photo: photo,
      sizes: [PhotoSize(photoId: 1, type: "f", width: 600, height: 600, size: 12_000)]
    )
    let remote = PhotoInfo(
      photo: photo,
      sizes: [PhotoSize(photoId: 1, type: "f", width: 600, height: 600, size: 12_000, cdnUrl: "https://example.com/f")]
    )
    let local = PhotoInfo(
      photo: photo,
      sizes: [PhotoSize(photoId: 1, type: "f", width: 600, height: 600, size: 12_000, localPath: "thumb.jpg")]
    )

    #expect(!metadataOnly.hasDisplayablePreview)
    #expect(remote.hasDisplayablePreview)
    #expect(local.hasDisplayablePreview)
  }

  @Test("local candidates keep the best explicit file first and deduplicate fallbacks")
  func localCandidateOrdering() {
    let info = PhotoInfo(photo: Photo(photoId: 49, format: .jpeg), sizes: [
      PhotoSize(photoId: 49, type: "b", width: 120, height: 90, size: 5_000, localPath: "small.jpg"),
      PhotoSize(photoId: 49, type: "c", width: 320, height: 240, size: 15_000, localPath: "medium.jpg"),
      PhotoSize(photoId: 49, type: "d", width: 800, height: 600, size: 30_000, localPath: "medium.jpg"),
      PhotoSize(photoId: 49, type: "f", width: 1_200, height: 900, size: 80_000,
                cdnUrl: "https://example.com/full.jpg"),
      PhotoSize(photoId: 49, type: "s", width: 40, height: 30, localPath: "stripped.jpg"),
    ])

    #expect(info.localPhotoSizeCandidates().compactMap(\.localPath) == ["medium.jpg", "small.jpg"])
  }

  @Test("download source identity changes only with the actual remote representation")
  func downloadSourceIdentity() {
    let base = PhotoInfo(photo: Photo(photoId: 50, format: .jpeg), sizes: [
      PhotoSize(photoId: 50, type: "f", width: 1_200, height: 900,
                cdnUrl: "https://example.com/photo.jpg?token=one"),
    ])
    var presentationChange = base
    presentationChange.sizes[0].width = 1_201
    var rotatedURL = base
    rotatedURL.sizes[0].cdnUrl = "https://example.com/photo.jpg?token=two"
    var differentType = base
    differentType.sizes[0].type = "d"
    var differentPhoto = base
    differentPhoto.photo.photoId = 51

    #expect(base.downloadSourceKey() == presentationChange.downloadSourceKey())
    #expect(base.downloadSourceKey() != rotatedURL.downloadSourceKey())
    #expect(base.downloadSourceKey() != differentType.downloadSourceKey())
    #expect(base.downloadSourceKey() != differentPhoto.downloadSourceKey())
  }
}
