import Foundation
import InlineKit
import Kingfisher

/// One photo source for circular avatars and full-size previews.
public struct UserAvatarImageSource: Sendable {
  public let url: URL
  public let cacheKey: String

  public init?(user: User, scale: CGFloat = 1) {
    self.init(
      userID: user.id,
      identity: user.stableAvatarIdentity,
      remoteURL: user.getRemoteURL(),
      localURL: user.getLocalURL(),
      scale: scale
    )
  }

  init?(
    userID: Int64,
    identity: String?,
    remoteURL: URL?,
    localURL: URL?,
    scale: CGFloat,
    prefersExplicitLocalSource: Bool = false
  ) {
    // Legacy local files may contain a previous photo or a processed thumbnail.
    // The server's photo reference is authoritative; Kingfisher retains its original for offline use.
    let localURL = localURL.flatMap { url in
      FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    let hasVerifiedLocalOriginal = localURL?.lastPathComponent.hasPrefix(User.remoteProfilePhotoCacheFilePrefix) == true
    let preferredLocal = prefersExplicitLocalSource || hasVerifiedLocalOriginal ? localURL : nil
    guard let url = preferredLocal ?? remoteURL ?? localURL else { return nil }
    self.url = url
    let photoIdentity: String
    if let identity, !identity.hasPrefix("local:") {
      photoIdentity = identity
    } else {
      photoIdentity = url.absoluteString
    }
    let sourceKey = remoteURL == nil || prefersExplicitLocalSource ? url.absoluteString : "remote"
    let scaleKey = Int((max(scale, 1) * 100).rounded())
    cacheKey = "user-avatar:v3:\(userID):scale\(scaleKey):\(photoIdentity):\(sourceKey)"
  }

  @MainActor
  public func originalImageData() async throws -> Data {
    try await originalImageData(using: .shared)
  }

  /// Returns the photo's original bytes without re-encoding a cached image, which took hundreds of
  /// milliseconds on the main thread for large photos.
  @MainActor
  func originalImageData(using manager: KingfisherManager, onlyFromCache: Bool = false) async throws -> Data {
    let cache = manager.cache
    // Avatar views use `.cacheOriginalImage()`, which stores the downloaded bytes under the bare key.
    await Self.waitForPendingDiskWrites(in: cache)
    if let data = await Self.readFile(at: URL(fileURLWithPath: cache.cachePath(forKey: cacheKey))) {
      return data
    }
    if url.isFileURL, let data = await Self.readFile(at: url) {
      return data
    }
    if onlyFromCache {
      throw CocoaError(.fileReadNoSuchFile)
    }

    let data = try await Self.download(url, using: manager)
    cache.storeToDisk(data, forKey: cacheKey)
    return data
  }

  /// Kingfisher writes to disk on one serial queue, after the request that stored the file has finished.
  /// Queuing a lookup behind those writes means a just-downloaded original is complete before it is read.
  @MainActor
  private static func waitForPendingDiskWrites(in cache: ImageCache) async {
    await withCheckedContinuation { continuation in
      cache.retrieveImageInDiskCache(forKey: "user-avatar:pending-writes", callbackQueue: .mainAsync) { _ in
        continuation.resume()
      }
    }
  }

  @concurrent
  private static func readFile(at url: URL) async -> Data? {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
    return data
  }

  @MainActor
  private static func download(_ url: URL, using manager: KingfisherManager) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let options = manager.defaultOptions + [.callbackQueue(.mainAsync)]
      manager.downloader.downloadImage(with: url, options: options) { result in
        switch result {
        case let .success(value) where !value.originalData.isEmpty:
          continuation.resume(returning: value.originalData)
        case .success:
          continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
        case let .failure(error):
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
