import Foundation
import Logger
import Nuke
import AVFoundation

#if os(iOS)
import UIKit
#else
import AppKit
#endif

public actor FileCache: Sendable {
  public static let shared = FileCache()

  private let database = AppDatabase.shared
  private let log = Log.scoped("FileCache")

  var downloadingPhotos: [Int64: Task<Void, Never>] = [:]
  // TODO: Create a message asset downloader middleware over the file cache which tracks messages and downloads, but for now we do it in this file directly
  var messagesToReload: [Int64: Set<Message>] = [:]

  private init() {}

  deinit {
    // Cancel all ongoing downloads
    for (photoId, task) in downloadingPhotos {
      task.cancel()
      log.debug("Cancelled download for photo \(photoId) during deinit")
    }
  }

  private func removeFromDownloadingPhotos(_ id: Int64) {
    downloadingPhotos[id] = nil
    // Note(@mo): do not clear messagesToReload here, it is used to reload messages when the photo is downloaded
    log.debug("Removed photo \(id) from downloadingPhotos")
  }

  /// Cancel download for a specific photo
  public func cancelDownload(photoId: Int64) {
    if let task = downloadingPhotos[photoId] {
      task.cancel()
      downloadingPhotos[photoId] = nil
      log.debug("Cancelled download for photo \(photoId)")
    }
  }

  /// Cancel all ongoing downloads
  public func cancelAllDownloads() {
    for (photoId, task) in downloadingPhotos {
      task.cancel()
      messagesToReload[photoId] = nil
      log.debug("Cancelled download for photo \(photoId)")
    }
    downloadingPhotos.removeAll()
  }

  /// Wait for a specific photo download to finish
  public func waitForDownload(photoId: Int64) async {
    await downloadingPhotos[photoId]?.value
  }

  // MARK: -  Fetches

  public static func getUrl(for dir: FileLocalCacheDirectory, localPath: String) -> URL {
    let directory = FileHelpers.getLocalCacheDirectory(for: dir)
    return directory.appendingPathComponent(localPath)
  }

  // MARK: -  Remote downloads

  public func download(photo: PhotoInfo, reloadMessageOnFinish: Message? = nil) async {
    // Register the message for reloading if provided
    if let message = reloadMessageOnFinish {
      if messagesToReload[photo.id] == nil {
        messagesToReload[photo.id] = Set<Message>()
      }
      messagesToReload[photo.id]?.insert(message)
      log.debug("Registered message \(message.id) for reload when photo \(photo.id) downloads")
    }

    guard downloadingPhotos[photo.id] == nil else {
      log.debug("Photo \(photo.id) is already being downloaded")
      return
    }

    log.debug("downloading photo \(photo.id) for message \(reloadMessageOnFinish?.id ?? 0)")

    // For now we get thumbnail for size "f"
    guard let remoteUrl = photo.bestPhotoSize()?.cdnUrl else {
      log.warning("No remote URL found for photo")
      return
    }

    downloadingPhotos[photo.id] = Task {
      // TODO: make it smarter about max retries
      await downloadWithRetries(
        photo: photo,
        remoteUrl: remoteUrl,
        maxRetries: 20
      )
    }
  }

  private func downloadWithRetries(
    photo: PhotoInfo,
    remoteUrl: String,
    maxRetries: Int
  ) async {
    var attempt = 0

    while attempt < maxRetries {
      attempt += 1

      // Check for cancellation before each attempt
      guard !Task.isCancelled else {
        log.debug("Downloading photo \(photo.id) was cancelled before attempt \(attempt)")
        break
      }

      do {
        log.debug("Downloading photo \(photo.id), attempt \(attempt)")

        guard let url = URL(string: remoteUrl) else {
          log.error("Invalid URL for photo \(photo.id): \(remoteUrl)")
          break
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        // Validate response
        if let httpResponse = response as? HTTPURLResponse {
          guard 200 ... 299 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 404 {
              log.error("Photo \(photo.id) not found (404) - will not retry")
              break
            }
            throw URLError(.badServerResponse)
          }
        }

        // Validate data
        guard !data.isEmpty else {
          log.error("Empty data received for photo \(photo.id)")
          if attempt < maxRetries {
            try? await Task.sleep(for: .seconds(Double(attempt)))
            continue
          }
          break
        }

        // Success - same logic as original
        log.debug("Successfully downloaded photo \(photo.id) (\(data.count) bytes)")

        // Generate a new file name (same as original)
        let localPath = "IMG" + (photo.bestPhotoSize()?.type ?? "") + String(photo.id) + photo.photo.format.toExt()
        let localUrl = FileCache.getUrl(for: .photos, localPath: localPath)

        // Ensure directory exists
        let directory = localUrl.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
          try data.write(to: localUrl, options: .atomic)
        } catch {
          if Task.isCancelled {
            log.debug("Downloading photo \(photo.id) was cancelled")
          }
          log.error("error saving image locally \(error)")
          throw error
        }

        // Update database (same as original)
        Task { [weak self] in
          guard let self else { return }
          // Update database
          try? await database.dbWriter.write { db in
            guard var matchingSize = photo.bestPhotoSize() else { return }
            matchingSize.localPath = localPath
            try matchingSize.save(db)
            self.log.debug("saved photo size \(matchingSize)")
          }

          // Reload all messages associated with this photo
          await reloadAllMessagesForPhoto(photo.id)
        }

        removeFromDownloadingPhotos(photo.id)
        return

      } catch {
        if Task.isCancelled {
          log.debug("Downloading photo \(photo.id) was cancelled during attempt \(attempt)")
          break
        }

        log.error("Failed to download photo \(photo.id), attempt \(attempt): \(error)")

        // Check if we should retry based on error type
        if attempt < maxRetries, shouldRetryError(error) {
          let delay = Double(attempt) // 1s, 2s, 3s
          log.debug("Retrying photo \(photo.id) in \(delay) seconds")
          try? await Task.sleep(for: .seconds(delay))
        } else if attempt >= maxRetries {
          log.error("Failed to download photo \(photo.id) after \(maxRetries) attempts")
          break
        } else {
          log.error("Photo \(photo.id) download failed with non-recoverable error: \(error)")
          break
        }
      }
    }

    removeFromDownloadingPhotos(photo.id)
  }

  private func shouldRetryError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
      switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
          return true
        case .badServerResponse, .cannotFindHost, .dnsLookupFailed:
          return true
        default:
          return false
      }
    }
    return false
  }

  private func triggerMessageReload(message: Message) {
    Task { @MainActor in
      await MessagesPublisher.shared
        .messageUpdated(message: message, peer: message.peerId, animated: true)
    }
  }

  private func reloadAllMessagesForPhoto(_ photoId: Int64) {
    guard let messages = messagesToReload[photoId] else { return }

    log.debug("Triggering message reload for photo \(photoId) for \(messages.count) messages")

    for message in messages {
      Task { @MainActor in
        await MessagesPublisher.shared
          .messageUpdated(message: message, peer: message.peerId, animated: true)
      }
    }

    // clear
    messagesToReload[photoId] = nil
  }

  // MARK: - Download Helpers

  /// Save a downloaded document to the cache and update the database
  public func saveDocumentDownload(document: DocumentInfo, localPath: String, message: Message? = nil) async throws {
    try await database.dbWriter.write { db in
      try Document.filter(id: document.id).updateAll(db, [Document.Columns.localPath.set(to: localPath)])
      self.log.debug("Updated document \(document.id) with local path \(localPath)")
    }

    if let message {
      triggerMessageReload(message: message)
    }
  }

  /// Save a downloaded video to the cache and update the database
  public func saveVideoDownload(video: VideoInfo, localPath: String, message: Message) async throws {
    try await database.dbWriter.write { db in
      try Video.filter(id: video.id).updateAll(db, [Video.Columns.localPath.set(to: localPath)])
      self.log.debug("Updated video \(video.id) with local path \(localPath)")
    }

    triggerMessageReload(message: message)
  }

  // MARK: - Helpers

  #if os(macOS)
  /// Gets the actual pixel dimensions of an NSImage, not just the logical size
  private static func getActualPixelSize(from image: NSImage) -> CGSize {
    // Try to get the best representation first
    if let bitmapRep = image.representations.first(where: { $0 is NSBitmapImageRep }) as? NSBitmapImageRep {
      return CGSize(width: bitmapRep.pixelsWide, height: bitmapRep.pixelsHigh)
    }

    // Fallback: Create a CGImage and get its dimensions
    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      return CGSize(width: cgImage.width, height: cgImage.height)
    }

    // Last resort: use logical size
    return image.size
  }
  #endif

  // MARK: - Local Saves

  public static func savePhoto(
    image: PlatformImage,
    preferredFormat: ImageFormat? = nil,
    optimize: Bool = false
  ) throws -> InlineKit.PhotoInfo {
    // Info - get actual pixel dimensions, not just logical size
    let actualSize: CGSize
    #if os(macOS)
    actualSize = getActualPixelSize(from: image)
    #else
    // On iOS, image.size already gives pixel dimensions
    actualSize = image.size
    #endif

    let w = Int(actualSize.width)
    let h = Int(actualSize.height)
    let format: ImageFormat = preferredFormat ?? (hasAlphaChannel(image: image) ? .png : .jpeg)
    let protoFormat = format.toProtocol()
    let ext = protoFormat.toExtension()
    let mimeType = protoFormat.toMimeType()
    let fileName = UUID().uuidString + ext

    Log.shared
      .debug(
        "Saving photo \(fileName) with format \(format) and mimeType \(mimeType), w: \(w), h: \(h), optimize: \(optimize)"
      )

    // Save in files
    let directory = FileHelpers.getLocalCacheDirectory(for: .photos)
    guard let (localPath, _) = try? image.save(to: directory, withName: fileName, format: format, optimize: optimize)
    else { throw FileCacheError.failedToSave }
    let fileURL = directory.appendingPathComponent(
      localPath
    )
    let fileSize = FileHelpers.getFileSize(at: fileURL)

    // Save in DB
    let photoInfo = try AppDatabase.shared.dbWriter.write { db in
      try Photo.createLocalPhoto(
        db,
        format: format,
        localPath: localPath,
        fileSize: fileSize,
        width: w,
        height: h
      )
    }

    return photoInfo
  }

  // Note: this does synchronous disk/thumbnail/DB work; avoid calling on MainActor for large assets.
  public static func saveVideo(url: URL, thumbnail: PlatformImage? = nil) async throws -> InlineKit.VideoInfo {
    // Handle security scoped URL before any reads
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

    let asset = AVURLAsset(url: url)

    // Dimensions
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = tracks.first
    let naturalSize = try await track?.load(.naturalSize)
    let preferredTransform = try await track?.load(.preferredTransform) ?? .identity
    let transformedSize = naturalSize?.applying(preferredTransform) ?? .zero
    let width = Int(abs(transformedSize.width.rounded()))
    let height = Int(abs(transformedSize.height.rounded()))

    // Duration in seconds
    let durationTime = try await asset.load(.duration)
    guard durationTime.isValid else { throw FileCacheError.failedToSave }
    let durationSeconds = Int(CMTimeGetSeconds(durationTime).rounded())

    // Persist the video to app cache (compress or transcode to mp4 when needed)
    let directory = FileHelpers.getLocalCacheDirectory(for: .videos)
    let fileManager = FileManager.default
    let sourceExtension = url.pathExtension.lowercased()
    let needsMp4Transcode = sourceExtension != "mp4"
    let localPath = UUID().uuidString + ".mp4"
    let localUrl = directory.appendingPathComponent(localPath)

    var finalWidth = width
    var finalHeight = height
    var finalDuration = durationSeconds
    var fileSize = 0

    do {
      let options = VideoCompressionOptions.uploadDefault(forceTranscode: needsMp4Transcode)
      let result = try await VideoCompressor.shared.compressVideo(at: url, options: options)
      defer {
        if fileManager.fileExists(atPath: result.url.path) {
          try? fileManager.removeItem(at: result.url)
        }
      }
      if fileManager.fileExists(atPath: localUrl.path) {
        try fileManager.removeItem(at: localUrl)
      }
      try fileManager.moveItem(at: result.url, to: localUrl)
      finalWidth = result.width
      finalHeight = result.height
      finalDuration = result.duration
      fileSize = Int(result.fileSize)
    } catch {
      if needsMp4Transcode {
        throw error
      }
      if fileManager.fileExists(atPath: localUrl.path) {
        try fileManager.removeItem(at: localUrl)
      }
      try fileManager.copyItem(at: url, to: localUrl)
      fileSize = FileHelpers.getFileSize(at: localUrl)
    }

    // Generate or reuse thumbnail
    let thumbImage: PlatformImage? = if let thumbnail {
      thumbnail
    } else {
      try? await generateThumbnailImage(from: asset)
    }

    let thumbnailInfo: PhotoInfo? = if let image = thumbImage {
      try? savePhoto(image: image, preferredFormat: .jpeg)
    } else { nil }

    let video = try MediaHelpers.shared.createLocalVideo(
      width: finalWidth,
      height: finalHeight,
      duration: finalDuration,
      size: fileSize,
      thumbnail: thumbnailInfo?.photo,
      localPath: localPath
    )

    return VideoInfo(video: video, photoInfo: thumbnailInfo)
  }

  public static func saveDocument(url: URL) throws -> InlineKit.DocumentInfo {
    // Info
    let fileName = url.lastPathComponent

    // Save in files
    let fileManager = FileManager.default
    let directory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let localPath = UUID().uuidString + "-" + fileName
    let localUrl = directory.appendingPathComponent(localPath)

    // Start accessing the security-scoped resource
    let hasAccess = url.startAccessingSecurityScopedResource()

    // Ensure we stop accessing the resource when we're done
    defer {
      if hasAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    try fileManager.copyItem(at: url, to: localUrl)

    let fileSize = FileHelpers.getFileSize(at: url)
    let mimeType = FileHelpers.getMimeType(for: url)

    // Save in DB
    let documentInfo = try AppDatabase.shared.dbWriter.write { db in
      try Document.createLocalDocument(db, fileName: fileName, mimeType: mimeType, size: fileSize, localPath: localPath)
    }

    return documentInfo
  }
}

enum FileCacheError: Error {
  case failedToSave
  case failedToFetch
  case failedToRemove
}

// MARK: - Video helpers

private func generateThumbnailImage(from asset: AVAsset) async throws -> PlatformImage {
  let imageGenerator = AVAssetImageGenerator(asset: asset)
  imageGenerator.appliesPreferredTrackTransform = true
  let duration = try await asset.load(.duration)
  let time = CMTime(seconds: min(1.0, CMTimeGetSeconds(duration)), preferredTimescale: 600)
  let cgImage = try imageGenerator.copyCGImage(at: time, actualTime: nil)

  #if os(iOS)
  return UIImage(cgImage: cgImage)
  #else
  return NSImage(cgImage: cgImage, size: .zero)
  #endif
}

private func exportVideoToMp4(asset: AVAsset, destinationURL: URL) async throws {
  if FileManager.default.fileExists(atPath: destinationURL.path) {
    try FileManager.default.removeItem(at: destinationURL)
  }

  guard let exportSession = AVAssetExportSession(
    asset: asset,
    presetName: AVAssetExportPresetHighestQuality
  ) else {
    throw FileCacheError.failedToSave
  }

  exportSession.outputURL = destinationURL
  exportSession.outputFileType = .mp4
  exportSession.shouldOptimizeForNetworkUse = true

  let sessionBox = ExportSessionBox(exportSession)
  try await withCheckedThrowingContinuation { continuation in
    sessionBox.session.exportAsynchronously {
      switch sessionBox.session.status {
      case .completed:
        continuation.resume()
      case .failed, .cancelled:
        continuation.resume(throwing: sessionBox.session.error ?? FileCacheError.failedToSave)
      default:
        continuation.resume(throwing: FileCacheError.failedToSave)
      }
    }
  }
}

private final class ExportSessionBox: @unchecked Sendable {
  let session: AVAssetExportSession

  init(_ session: AVAssetExportSession) {
    self.session = session
  }
}

// MARK: - Clear Cache

extension FileCache {
  public func clearCache() async throws {
    log.debug("Clearing cache")

    // Clear photos
    try await clearPhotoCache()

    // Clear documents
    try await clearDocumentCache()

    // Clear videos
    try await clearVideoCache()
  }

  private func clearPhotoCache() async throws {
    // Step 1: Get all photo sizes with local paths from database
    let photoSizesWithLocalPaths = try await database.dbWriter.read { db in
      // Use the proper GRDB query syntax to filter non-null localPath values
      try PhotoSize.filter(sql: "localPath IS NOT NULL").fetchAll(db)
    }

    log.debug("Found \(photoSizesWithLocalPaths.count) cached photos to clear")

    // Step 2: Delete the actual files
    var deletedCount = 0
    var failedDeletions = 0

    for photoSize in photoSizesWithLocalPaths {
      guard let localPath = photoSize.localPath else { continue }

      let fileURL = FileCache.getUrl(for: .photos, localPath: localPath)

      do {
        // Check if file exists before attempting to delete
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try FileManager.default.removeItem(at: fileURL)
          deletedCount += 1
        }
      } catch {
        failedDeletions += 1
        log.error("Failed to delete cached file at \(fileURL): \(error)")
      }
    }

    // Step 3: Clear local paths in database
    _ = try await database.dbWriter.write { db in
      try PhotoSize.updateAll(db, [PhotoSize.Columns.localPath.set(to: nil)])
    }

    log.info("Photo cache cleared: \(deletedCount) files deleted, \(failedDeletions) deletions failed")

    // Step 4: Clear the photos directory to catch any orphaned files
    try clearOrphanedFiles(in: .photos)
  }

  private func clearDocumentCache() async throws {
    // Step 1: Get all documents with local paths from database
    let documentsWithLocalPaths = try await database.dbWriter.read { db in
      try Document.filter(sql: "localPath IS NOT NULL").fetchAll(db)
    }

    log.debug("Found \(documentsWithLocalPaths.count) cached documents to clear")

    // Step 2: Delete the actual files
    var deletedCount = 0
    var failedDeletions = 0

    for document in documentsWithLocalPaths {
      guard let localPath = document.localPath else { continue }

      let fileURL = FileCache.getUrl(for: .documents, localPath: localPath)

      do {
        // Check if file exists before attempting to delete
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try FileManager.default.removeItem(at: fileURL)
          deletedCount += 1
        }
      } catch {
        failedDeletions += 1
        log.error("Failed to delete cached document at \(fileURL): \(error)")
      }
    }

    // Step 3: Clear local paths in database
    _ = try await database.dbWriter.write { db in
      try Document.updateAll(db, [Document.Columns.localPath.set(to: nil)])
    }

    log.info("Document cache cleared: \(deletedCount) files deleted, \(failedDeletions) deletions failed")

    // Step 4: Clear the documents directory to catch any orphaned files
    try clearOrphanedFiles(in: .documents)
  }

  private func clearVideoCache() async throws {
    // Step 1: Get all videos with local paths from database
    let videosWithLocalPaths = try await database.dbWriter.read { db in
      try Video.filter(sql: "localPath IS NOT NULL").fetchAll(db)
    }

    log.debug("Found \(videosWithLocalPaths.count) cached videos to clear")

    // Step 2: Delete the actual files
    var deletedCount = 0
    var failedDeletions = 0

    for video in videosWithLocalPaths {
      guard let localPath = video.localPath else { continue }

      let fileURL = FileCache.getUrl(for: .videos, localPath: localPath)

      do {
        // Check if file exists before attempting to delete
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try FileManager.default.removeItem(at: fileURL)
          deletedCount += 1
        }
      } catch {
        failedDeletions += 1
        log.error("Failed to delete cached video at \(fileURL): \(error)")
      }
    }

    // Step 3: Clear local paths in database
    _ = try await database.dbWriter.write { db in
      try Video.updateAll(db, [Video.Columns.localPath.set(to: nil)])
    }

    log.info("Video cache cleared: \(deletedCount) files deleted, \(failedDeletions) deletions failed")

    // Step 4: Clear the videos directory to catch any orphaned files
    try clearOrphanedFiles(in: .videos)
  }

  private func clearOrphanedFiles(in directory: FileLocalCacheDirectory) throws {
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: directory)
    let fileManager = FileManager.default

    do {
      let fileURLs = try fileManager.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: nil
      )

      var deletedCount = 0
      var failedCount = 0

      for fileURL in fileURLs {
        do {
          try fileManager.removeItem(at: fileURL)
          deletedCount += 1
        } catch {
          failedCount += 1
          log.error("Failed to delete orphaned file at \(fileURL): \(error)")
        }
      }

      log.debug("Cleared orphaned files in \(directory) directory: \(deletedCount) deleted, \(failedCount) failed")
    } catch {
      log.error("Failed to enumerate files in \(directory) directory: \(error)")
      throw FileCacheError.failedToRemove
    }
  }
}
