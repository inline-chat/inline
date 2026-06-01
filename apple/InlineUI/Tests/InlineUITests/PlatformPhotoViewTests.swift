import CoreGraphics
import Foundation
import InlineKit
import Testing

@testable import InlineUI

#if os(iOS)
import UIKit
private typealias TestPlatformView = UIView
#else
import AppKit
private typealias TestPlatformView = NSView
#endif

@MainActor
@Suite("Platform photo view")
struct PlatformPhotoViewTests {
  @Test("buckets requested target size to reduce resize churn")
  func bucketsTargetSize() {
    #expect(PlatformPhotoLoadPolicy.bucketedTargetSize(CGSize(width: 37, height: 41)) == CGSize(width: 48, height: 48))
    #expect(PlatformPhotoLoadPolicy.bucketedTargetSize(CGSize(width: 0, height: 1)) == CGSize(width: 16, height: 16))
  }

  @Test("requests cover-sized downsample for aspect-fill crops")
  func requestsCoverSizedDownsampleForAspectFill() {
    let targetSize = PlatformPhotoLoadPolicy.imageRequestSize(
      displaySize: CGSize(width: 44, height: 44),
      sourceSize: CGSize(width: 1_600, height: 900),
      contentMode: .aspectFill
    )

    #expect(targetSize.width >= 80)
    #expect(targetSize.height == 48)
  }

  @Test("caps aspect-fill downsample expansion for extreme source ratios")
  func capsAspectFillDownsampleExpansion() {
    let targetSize = PlatformPhotoLoadPolicy.imageRequestSize(
      displaySize: CGSize(width: 44, height: 44),
      sourceSize: CGSize(width: 10_000, height: 100),
      contentMode: .aspectFill
    )

    #expect(targetSize.width <= 144)
  }

  @Test("uses display-sized downsample for aspect-fit images")
  func requestsDisplaySizedDownsampleForAspectFit() {
    let targetSize = PlatformPhotoLoadPolicy.imageRequestSize(
      displaySize: CGSize(width: 44, height: 44),
      sourceSize: CGSize(width: 1_600, height: 900),
      contentMode: .aspectFit
    )

    #expect(targetSize == CGSize(width: 48, height: 48))
  }

  @Test("crops wide images for aspect-fill instead of stretching them")
  func cropsWideImageForAspectFill() {
    let source = PlatformPhotoLoadPolicy.aspectFillSourceRect(
      imageSize: CGSize(width: 160, height: 90),
      displaySize: CGSize(width: 36, height: 36)
    )

    #expect(source == CGRect(x: 35, y: 0, width: 90, height: 90))
  }

  @Test("crops tall images for aspect-fill instead of stretching them")
  func cropsTallImageForAspectFill() {
    let source = PlatformPhotoLoadPolicy.aspectFillSourceRect(
      imageSize: CGSize(width: 90, height: 160),
      displaySize: CGSize(width: 36, height: 36)
    )

    #expect(source == CGRect(x: 0, y: 35, width: 90, height: 90))
  }

  @Test("centers aspect-fit destination without stretching")
  func centersAspectFitDestination() {
    let destination = PlatformPhotoLoadPolicy.aspectFitDestinationRect(
      imageSize: CGSize(width: 160, height: 90),
      displaySize: CGSize(width: 36, height: 36)
    )

    #expect(destination == CGRect(x: 0, y: 7.875, width: 36, height: 20.25))
  }

  @Test("reuses loaded image for small resize changes only")
  func reusesLoadedImageForSmallResizeChanges() {
    #expect(PlatformPhotoLoadPolicy.canReuseLoadedImage(
      loadedSize: CGSize(width: 160, height: 96),
      targetSize: CGSize(width: 172, height: 103)
    ))
    #expect(!PlatformPhotoLoadPolicy.canReuseLoadedImage(
      loadedSize: CGSize(width: 160, height: 96),
      targetSize: CGSize(width: 176, height: 104)
    ))
    #expect(!PlatformPhotoLoadPolicy.canReuseLoadedImage(
      loadedSize: .zero,
      targetSize: CGSize(width: 16, height: 16)
    ))
  }

  @Test("does not reuse loaded image across backing scale changes")
  func doesNotReuseLoadedImageAcrossBackingScaleChanges() {
    #expect(PlatformPhotoLoadPolicy.canReuseLoadedImage(
      loadedSize: CGSize(width: 160, height: 96),
      loadedScale: 2,
      targetSize: CGSize(width: 160, height: 96),
      targetScale: 2
    ))
    #expect(!PlatformPhotoLoadPolicy.canReuseLoadedImage(
      loadedSize: CGSize(width: 160, height: 96),
      loadedScale: 1,
      targetSize: CGSize(width: 160, height: 96),
      targetScale: 2
    ))
  }

  @Test("keeps local fallback while requesting larger remote image")
  func keepsLocalFallbackWhileRequestingBestRemote() {
    let photo = Photo(photoId: 43, format: .jpeg)
    let info = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 43, type: "b", width: 120, height: 90, size: 5_000, localPath: "small.jpg"),
        PhotoSize(photoId: 43, type: "f", width: 1_200, height: 900, size: 80_000, cdnUrl: "https://example.com/full.jpg"),
      ]
    )

    #expect(PlatformPhotoLoadPolicy.bestLocalPhotoSize(from: info)?.type == "b")
    #expect(PlatformPhotoLoadPolicy.needsBestPhotoDownload(info))
  }

  @Test("orders local candidates by best size then fallbacks")
  func ordersLocalCandidatesByBestSizeThenFallbacks() {
    let photo = Photo(photoId: 45, format: .jpeg)
    let info = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 45, type: "b", width: 120, height: 90, size: 5_000, localPath: "small.jpg"),
        PhotoSize(photoId: 45, type: "c", width: 320, height: 240, size: 15_000, localPath: "medium.jpg"),
        PhotoSize(photoId: 45, type: "f", width: 1_200, height: 900, size: 80_000, cdnUrl: "https://example.com/full.jpg"),
      ]
    )

    let paths = PlatformPhotoLoadPolicy.localPhotoSizeCandidates(from: info).compactMap(\.localPath)

    #expect(paths == ["medium.jpg", "small.jpg"])
  }

  @Test("does not request download when best image is already local")
  func doesNotRequestDownloadWhenBestImageIsLocal() {
    let photo = Photo(photoId: 44, format: .jpeg)
    let info = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(
          photoId: 44,
          type: "f",
          width: 1_200,
          height: 900,
          size: 80_000,
          cdnUrl: "https://example.com/full.jpg",
          localPath: "full.jpg"
        ),
      ]
    )

    #expect(!PlatformPhotoLoadPolicy.needsBestPhotoDownload(info))
  }

  @Test("shows tiny thumbnail background when enabled for stripped photo bytes")
  func showsTinyThumbnailBackgroundForStrippedPhotos() {
    let view = PlatformPhotoView()
    view.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
    view.showsTinyThumbnailBackground = true
    let strippedBytes = Data(base64Encoded: "ARkoAAwDAQACEQMRAD8AqUUUV0mAUUUUAFFFFABRRRQAUUUUAFFFFAE=")
    #expect(strippedBytes != nil)
    guard let strippedBytes else { return }

    let photo = Photo(photoId: 42, format: .jpeg)
    let photoInfo = PhotoInfo(
      photo: photo,
      sizes: [
        PhotoSize(photoId: 42, type: "s", width: 40, height: 30, size: strippedBytes.count, bytes: strippedBytes),
      ]
    )

    view.setPhoto(photoInfo)
    layout(view)

    let backgroundView = findTinyThumbnailBackground(in: view)
    #expect(backgroundView != nil)
    #expect(backgroundView?.isHidden == false)
  }

  private func findTinyThumbnailBackground(in view: TestPlatformView) -> InlineTinyThumbnailBackgroundView? {
    if let backgroundView = view as? InlineTinyThumbnailBackgroundView {
      return backgroundView
    }

    for subview in view.subviews {
      if let backgroundView = findTinyThumbnailBackground(in: subview) {
        return backgroundView
      }
    }

    return nil
  }

  private func layout(_ view: PlatformPhotoView) {
    #if os(iOS)
    view.layoutIfNeeded()
    #else
    view.layoutSubtreeIfNeeded()
    #endif
  }
}
