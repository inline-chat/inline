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
  func showsTinyThumbnailBackgroundForStrippedPhotos() async throws {
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
    try await waitUntil { backgroundView?.isHidden == false }
    #expect(backgroundView?.isHidden == false)
  }

  @Test("rich photo discovers download completion without a new local-path snapshot")
  func richPhotoDiscoversCompletedDownload() {
    let info = PhotoInfo(
      photo: Photo(photoId: 46, format: .jpeg),
      sizes: [PhotoSize(
        photoId: 46, type: "f", width: 1_200, height: 900, size: 80_000,
        cdnUrl: "https://example.com/full.jpg"
      )]
    )
    var downloadedPaths = Set<String>()
    let expected = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
      .appendingPathComponent("IMG-server-46-f.jpg")

    #expect(FileCache.cachedLocalURL(photo: info, fileExists: downloadedPaths.contains) == nil)
    downloadedPaths.insert(expected.path)
    #expect(FileCache.cachedLocalURL(photo: info, fileExists: downloadedPaths.contains) == expected)
    #expect(info.bestPhotoSize()?.localPath == nil)

    downloadedPaths.remove(expected.path)
    #expect(FileCache.cachedLocalURL(photo: info, fileExists: downloadedPaths.contains) == nil)
  }

  @Test("explicit local photo wins and a missing local file falls back to the downloaded original")
  func localPhotoPathPrecedence() {
    let info = PhotoInfo(
      photo: Photo(photoId: 47, format: .png),
      sizes: [PhotoSize(
        photoId: 47, type: "f", width: 1_200, height: 900, size: 80_000,
        cdnUrl: "https://example.com/full.png", localPath: "uploaded.png"
      )]
    )
    let directory = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
    let explicit = directory.appendingPathComponent("uploaded.png")
    let downloaded = directory.appendingPathComponent("IMG-server-47-f.png")
    var paths = Set([explicit.path, downloaded.path])
    #expect(FileCache.cachedLocalURL(photo: info, fileExists: paths.contains) == explicit)

    paths.remove(explicit.path)
    #expect(FileCache.cachedLocalURL(photo: info, fileExists: paths.contains) == downloaded)
  }

  @Test("local photo candidates preserve quality fallbacks and reject unsafe or duplicate paths")
  func localPhotoCandidatesAreSafeAndStable() {
    let info = PhotoInfo(
      photo: Photo(id: 900, photoId: 51, format: .jpeg),
      sizes: [
        PhotoSize(photoId: 900, type: "f", width: 1_200, height: 900, size: 80_000,
                  cdnUrl: "https://example.com/full.jpg", localPath: "full.jpg"),
        PhotoSize(photoId: 900, type: "c", width: 320, height: 240, size: 15_000,
                  localPath: "medium.jpg"),
        PhotoSize(photoId: 900, type: "b", width: 120, height: 90, size: 5_000,
                  localPath: "medium.jpg"),
        PhotoSize(photoId: 900, type: "d", width: 800, height: 600, size: 30_000,
                  localPath: "../escape.jpg"),
      ]
    )
    let directory = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
    let expected = ["full.jpg", "IMG-server-51-f.jpg", "medium.jpg"]
      .map { directory.appendingPathComponent($0) }
    let unrelatedLegacy = ["IMGf51.jpg", "IMGf900.jpg"].map { directory.appendingPathComponent($0) }
    let existing = Set((expected + unrelatedLegacy + [directory.deletingLastPathComponent().appendingPathComponent("escape.jpg")]).map(\.path))

    let candidates = FileCache.cachedLocalURLCandidates(photo: info, fileExists: existing.contains)

    #expect(candidates == expected)
    #expect(Set(candidates).count == candidates.count)
    #expect(FileCache.cachedLocalURL(photo: info, fileExists: existing.contains) == expected[0])
    let failed = Set(expected.prefix(2))
    #expect(candidates.first(where: { !failed.contains($0) }) == expected[2])
  }

  @Test("download completion refreshes a rich photo without a parent message reload")
  func downloadCompletionRefreshesPhoto() async throws {
    let probe = DownloadProbe()
    defer { probe.finishAll() }
    let view = PlatformPhotoView(cachedPhotoURL: probe.cachedURL, downloadPhoto: probe.download)
    view.setPhoto(remotePhoto(id: 48))
    try await waitUntil { probe.pending[48] != nil }
    let initialChecks = probe.cacheChecks[48, default: 0]

    probe.finish(48)
    try await waitUntil { probe.cacheChecks[48, default: 0] > initialChecks }
    #expect(probe.started == [48])
  }

  @Test("a reused photo view ignores completion for the previous photo")
  func reusedPhotoIgnoresOldDownload() async throws {
    let probe = DownloadProbe()
    defer { probe.finishAll() }
    let view = PlatformPhotoView(cachedPhotoURL: probe.cachedURL, downloadPhoto: probe.download)
    view.setPhoto(remotePhoto(id: 49))
    try await waitUntil { probe.pending[49] != nil }
    view.setPhoto(remotePhoto(id: 50))
    try await waitUntil { probe.pending[50] != nil }
    let initialChecks = probe.cacheChecks[50, default: 0]

    probe.finish(49)
    try await waitUntil { probe.completed.contains(49) }
    #expect(probe.cacheChecks[50, default: 0] == initialChecks)

    probe.finish(50)
    try await waitUntil { probe.cacheChecks[50, default: 0] > initialChecks }
    #expect(probe.started == [49, 50])
  }

  @Test("changed metadata for the same photo can request its corrected CDN URL")
  func samePhotoMetadataCanRetryDownload() async throws {
    let probe = ImmediateDownloadProbe()
    let view = PlatformPhotoView(cachedPhotoURL: { _ in nil }, downloadPhoto: probe.download)
    view.setPhoto(remotePhoto(id: 52, cdnURL: "https://example.com/first.jpg"))
    try await waitUntil { probe.startedURLs.count == 1 }

    view.setPhoto(remotePhoto(id: 52, cdnURL: "https://example.com/second.jpg"))
    try await waitUntil { probe.startedURLs.count == 2 }

    #expect(probe.startedURLs == [
      "https://example.com/first.jpg",
      "https://example.com/second.jpg",
    ])
  }

  @Test("old URL completion cannot refresh a view already using a rotated source for the same ID")
  func ignoresOldSourceCompletion() async throws {
    let probe = SourceDownloadProbe()
    defer { probe.finishAll() }
    let first = "https://example.com/first.jpg", second = "https://example.com/second.jpg"
    let view = PlatformPhotoView(cachedPhotoURL: probe.cachedURL, downloadPhoto: probe.download)
    view.setPhoto(remotePhoto(id: 53, cdnURL: first))
    try await waitUntil { probe.pending[first] != nil }
    view.setPhoto(remotePhoto(id: 53, cdnURL: second))
    try await waitUntil { probe.pending[second] != nil }
    let checks = probe.cacheChecks
    probe.finish(first)
    try await waitUntil { probe.completed.contains(first) }
    #expect(probe.cacheChecks == checks)
    probe.finish(second)
    try await waitUntil { probe.cacheChecks > checks }
  }

  @Test("only explicit persisted paths may refer to legacy local-ID filenames")
  func acceptsExplicitLegacyPath() {
    let directory = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
    let legacy = directory.appendingPathComponent("IMGf9.jpg")
    let info = PhotoInfo(photo: Photo(id: 9, photoId: 53, format: .jpeg), sizes: [
      PhotoSize(photoId: 9, type: "f", width: 100, height: 100, localPath: "IMGf9.jpg"),
    ])
    #expect(FileCache.cachedLocalURL(photo: info, fileExists: { $0 == legacy.path }) == legacy)
  }

  private func remotePhoto(id: Int64, cdnURL: String = "https://example.com/photo.jpg") -> PhotoInfo {
    PhotoInfo(
      photo: Photo(photoId: id, format: .jpeg),
      sizes: [PhotoSize(photoId: id, type: "f", width: 100, height: 100, size: 200,
                        cdnUrl: cdnURL)]
    )
  }

  @MainActor
  private final class ImmediateDownloadProbe {
    var startedURLs: [String] = []

    func download(_ photo: PhotoInfo, _ message: Message?) async -> URL? {
      if let url = photo.bestPhotoSize()?.cdnUrl { startedURLs.append(url) }
      return nil
    }
  }

  @MainActor
  private final class SourceDownloadProbe {
    var cacheChecks = 0
    var pending: [String: CheckedContinuation<Void, Never>] = [:]
    var completed: [String] = []

    func cachedURL(_ photo: PhotoInfo) -> URL? { cacheChecks += 1; return nil }

    func download(_ photo: PhotoInfo, _ message: Message?) async -> URL? {
      guard let source = photo.downloadSourceKey()?.cdnURL else { return nil }
      await withCheckedContinuation { pending[source] = $0 }
      completed.append(source)
      return nil
    }

    func finish(_ source: String) { pending.removeValue(forKey: source)?.resume() }

    func finishAll() {
      let continuations = Array(pending.values)
      pending.removeAll()
      for continuation in continuations { continuation.resume() }
    }
  }

  @MainActor
  private final class DownloadProbe {
    var cacheChecks: [Int64: Int] = [:]
    var started: [Int64] = []
    var completed: [Int64] = []
    var pending: [Int64: CheckedContinuation<Void, Never>] = [:]

    func cachedURL(_ photo: PhotoInfo) -> URL? {
      cacheChecks[photo.id, default: 0] += 1
      return nil
    }

    func download(_ photo: PhotoInfo, _ message: Message?) async -> URL? {
      started.append(photo.id)
      await withCheckedContinuation { pending[photo.id] = $0 }
      completed.append(photo.id)
      return nil
    }

    func finish(_ id: Int64) {
      pending.removeValue(forKey: id)?.resume()
    }

    func finishAll() {
      let continuations = Array(pending.values)
      pending.removeAll()
      continuations.forEach { $0.resume() }
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let start = clock.now

    while clock.now - start < timeout {
      if condition() {
        return
      }
      try await Task.sleep(for: pollInterval)
    }
    throw PhotoTestTimeout()
  }

  private struct PhotoTestTimeout: Error {}

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
