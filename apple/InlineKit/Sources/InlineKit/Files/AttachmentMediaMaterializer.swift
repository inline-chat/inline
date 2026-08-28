import Foundation

/// Turns a selected attachment into its preferred rich representation without
/// ever making that representation a requirement for retaining the source.
public enum AttachmentMediaMaterializer {
  public static func image(
    _ image: PlatformImage,
    preferredFormat: ImageFormat? = nil,
    sourceURL: URL? = nil
  ) async throws -> FileMediaItem {
    try await withBareFileFallback {
      .photo(try FileCache.savePhoto(image: image, preferredFormat: preferredFormat))
    } fallback: {
      if let sourceURL {
        return .document(try await FileCache.saveDocumentWithThumbnail(url: sourceURL))
      }

      let format = preferredFormat ?? .png
      let fileName = "image-" + UUID().uuidString + format.toExt()
      let (_, temporaryURL) = try image.save(
        to: FileHelpers.getTrueTemporaryDirectory(),
        withName: fileName,
        format: format
      )
      defer { try? FileManager.default.removeItem(at: temporaryURL) }
      return .document(try await FileCache.saveDocumentWithThumbnail(url: temporaryURL))
    }
  }

  public static func video(
    _ url: URL,
    thumbnail: PlatformImage? = nil
  ) async throws -> FileMediaItem {
    try await withBareFileFallback {
      .video(try await FileCache.saveVideo(url: url, thumbnail: thumbnail))
    } fallback: {
      .document(try await FileCache.saveDocumentWithThumbnail(url: url))
    }
  }

  public static func animatedImage(_ url: URL) async throws -> FileMediaItem {
    try await withBareFileFallback {
      .video(try await FileCache.saveAnimatedImageAsVideo(url: url))
    } fallback: {
      .document(try await FileCache.saveDocumentWithThumbnail(url: url))
    }
  }

  public static func file(_ url: URL) async throws -> FileMediaItem {
    .document(try await FileCache.saveDocumentWithThumbnail(url: url))
  }

  static func withBareFileFallback<Value: Sendable>(
    _ preferred: @Sendable () async throws -> Value,
    fallback: @Sendable () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    do {
      return try await preferred()
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else {
        throw CancellationError()
      }
      try Task.checkCancellation()
      return try await fallback()
    }
  }
}
