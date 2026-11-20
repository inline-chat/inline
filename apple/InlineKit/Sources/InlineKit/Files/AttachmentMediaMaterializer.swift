import Foundation
import Logger

/// Turns a selected attachment into its preferred rich representation without
/// ever making that representation a requirement for retaining the source.
public enum AttachmentMediaMaterializer {
  /// Prepares a picked photo for sending (see `MediaSendPreparation`) and keeps its untouched
  /// source for the composer's Original toggle. Images too thin or too small to show as a photo
  /// go as a file, as before.
  public static func photo(
    _ source: MediaSendPreparation.PhotoSource,
    originalFileName: String? = nil,
    content: MediaSendPreparation.PhotoContent? = nil
  ) async throws -> FileMediaItem {
    try await withBareFileFallback {
      try await detached {
        OriginalMediaStore.sweep()
        if let size = MediaSendPreparation.pixelSize(of: source),
           MediaSendPreparation.shouldSendAsDocument(width: size.width, height: size.height)
        {
          return try await document(from: source, fileName: originalFileName)
        }
        let photo = FileMediaItem.photo(try FileCache.savePreparedPhoto(source, content: content))
        retainOriginal(source, fileName: originalFileName, content: content, for: photo)
        return photo
      }
    } fallback: {
      try await document(from: source, fileName: originalFileName)
    }
  }

  /// A decoded image, prepared from `sourceURL` when the encoded file behind it is known.
  public static func image(_ image: PlatformImage, sourceURL: URL? = nil) async throws -> FileMediaItem {
    if let sourceURL {
      return try await photo(.file(sourceURL), originalFileName: sourceURL.lastPathComponent)
    }
    return try await photo(.platformImage(image))
  }

  static func retainOriginal(
    _ source: MediaSendPreparation.PhotoSource,
    fileName: String?,
    content: MediaSendPreparation.PhotoContent? = nil,
    for media: FileMediaItem
  ) {
    do {
      switch source {
      case let .file(url):
        try OriginalMediaStore.retain(copyOf: url, fileName: fileName ?? url.lastPathComponent, for: media)
      case let .data(data):
        let name = fileName ?? "Photo." + (MediaSendPreparation.fileExtension(of: data) ?? "jpg")
        try OriginalMediaStore.retain(data: data, fileName: name, for: media)
      case .cgImage, .platformImage:
        // A camera capture handed over as pixels has no file behind it: keep a full-resolution
        // copy so Original still sends every pixel. Other pixel-only images (pastes, stickers)
        // send the prepared photo even with Original on.
        guard content == .camera else { break }
        let full = try MediaSendPreparation.preparePhoto(
          source,
          content: .camera,
          target: .init(maxPixelSize: 100_000, jpegQuality: 0.95)
        )
        try OriginalMediaStore.retain(data: full.data, fileName: fileName ?? "Photo" + full.format.toExt(), for: media)
      }
    } catch {
      Log.shared.warning("Couldn't keep the original photo for sending as a file: \(error.localizedDescription)")
    }
  }

  /// The source as a file and sent as a document, untouched where an encoded source exists.
  private static func document(
    from source: MediaSendPreparation.PhotoSource,
    fileName: String?
  ) async throws -> FileMediaItem {
    switch source {
    case let .file(url):
      return .document(try await FileCache.saveDocumentWithThumbnail(url: url))
    case let .data(data):
      let name = fileName ?? "image-\(UUID().uuidString)." + (MediaSendPreparation.fileExtension(of: data) ?? "png")
      return try await documentFromTemporaryFile(named: name) { try data.write(to: $0, options: .atomic) }
    case .cgImage, .platformImage:
      // Full resolution: a long screenshot sent as a file must stay readable.
      let full = try MediaSendPreparation.preparePhoto(
        source,
        target: .init(maxPixelSize: 100_000, jpegQuality: 0.92)
      )
      let name = (fileName.map { ($0 as NSString).deletingPathExtension } ?? "image-\(UUID().uuidString)")
        + full.format.toExt()
      return try await documentFromTemporaryFile(named: name) { try full.data.write(to: $0, options: .atomic) }
    }
  }

  private static func documentFromTemporaryFile(
    named name: String,
    write: (URL) throws -> Void
  ) async throws -> FileMediaItem {
    let folder = FileHelpers.getTrueTemporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(OriginalMediaStore.safeFileName(name))
    try write(url)
    return .document(try await FileCache.saveDocumentWithThumbnail(url: url))
  }

  /// Runs decode and disk work off the caller's thread, cancelling with the caller.
  private static func detached<Value: Sendable>(
    _ work: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try await work()
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  public static func video(
    _ url: URL,
    thumbnail: PlatformImage? = nil
  ) async throws -> FileMediaItem {
    try await withBareFileFallback {
      let video = FileMediaItem.video(try await FileCache.saveVideo(url: url, thumbnail: thumbnail))
      do {
        try OriginalMediaStore.retain(copyOf: url, for: video)
      } catch {
        Log.shared.warning("Couldn't keep the original video for sending as a file: \(error.localizedDescription)")
      }
      return video
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
    let worker = Task.detached(priority: .userInitiated) { try FolderArchive.createIfDirectory(at: url) }
    let archive = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: { worker.cancel() }
    if let archive {
      defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
      return .document(try await FileCache.saveDocumentWithThumbnail(url: archive))
    }
    return .document(try await FileCache.saveDocumentWithThumbnail(url: url))
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
