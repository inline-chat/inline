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

  @MainActor
  func originalImageData(using manager: KingfisherManager, onlyFromCache: Bool = false) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      // No downsampling processor: a .none result from a processed request can still be thumbnail data.
      manager.retrieveImage(
        with: KF.ImageResource(downloadURL: url, cacheKey: cacheKey),
        options: onlyFromCache ? [.onlyFromCache] : [],
        completionHandler: { result in
          switch result {
          case let .success(image):
            if let data = image.data(), !data.isEmpty {
              continuation.resume(returning: data)
            } else {
              continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
            }
          case let .failure(error):
            continuation.resume(throwing: error)
          }
        }
      )
    }
  }
}
