import AnimatedMedia
import Foundation
import GRDB
import InlineProtocol
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
  private var downloadGenerations: [Int64: UUID] = [:]
  private var resetTask: Task<Void, Never>?
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

  private func finishDownload(_ id: Int64, generation: UUID) {
    guard downloadGenerations[id] == generation else { return }
    downloadingPhotos[id] = nil
    downloadGenerations[id] = nil
    messagesToReload[id] = nil
    log.debug("Released terminal photo download state for \(id)")
  }

  /// Cancel download for a specific photo
  public func cancelDownload(photoId: Int64) {
    if let task = downloadingPhotos[photoId] {
      task.cancel()
      downloadingPhotos[photoId] = nil
    }
    downloadGenerations[photoId] = nil
    messagesToReload[photoId] = nil
    log.debug("Cancelled download for photo \(photoId)")
  }

  /// Cancel all ongoing downloads
  public func cancelAllDownloads() async {
    if let resetTask {
      await resetTask.value
      return
    }

    let tasks = Array(downloadingPhotos.values)
    for (photoId, task) in downloadingPhotos {
      task.cancel()
      log.debug("Cancelled download for photo \(photoId)")
    }
    downloadingPhotos.removeAll()
    downloadGenerations.removeAll()
    messagesToReload.removeAll()

    let reset = Task {
      for task in tasks {
        await task.value
      }
    }
    resetTask = reset
    await reset.value
    resetTask = nil
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
    guard resetTask == nil else { return }

    // Validate the remote location before retaining a message for a future reload.
    guard let remoteURLString = photo.bestPhotoSize()?.cdnUrl,
          let remoteURL = URL(string: remoteURLString)
    else {
      log.warning("No valid remote URL found for photo")
      messagesToReload[photo.id] = nil
      return
    }

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

    let generation = UUID()
    downloadGenerations[photo.id] = generation
    downloadingPhotos[photo.id] = Task {
      // TODO: make it smarter about max retries
      await downloadWithRetries(
        photo: photo,
        remoteURL: remoteURL,
        maxRetries: 20,
        generation: generation
      )
    }
  }

  private func downloadWithRetries(
    photo: PhotoInfo,
    remoteURL: URL,
    maxRetries: Int,
    generation: UUID
  ) async {
    defer { finishDownload(photo.id, generation: generation) }
    var attempt = 0

    while attempt < maxRetries {
      attempt += 1

      // Check for cancellation before each attempt
      guard !Task.isCancelled else {
        log.debug("Downloading photo \(photo.id) was cancelled before attempt \(attempt)")
        break
      }
      guard downloadGenerations[photo.id] == generation else { return }

      do {
        log.debug("Downloading photo \(photo.id), attempt \(attempt)")

        let (data, response) = try await URLSession.shared.data(from: remoteURL)

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
        let createdLocalFile = !FileManager.default.fileExists(atPath: localUrl.path)
        var shouldRemoveLocalFile = createdLocalFile
        defer {
          if shouldRemoveLocalFile {
            try? FileManager.default.removeItem(at: localUrl)
          }
        }

        // Ensure directory exists
        let directory = localUrl.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
          try data.write(to: localUrl, options: .atomic)
        } catch {
          if Self.isCancellation(error) || Task.isCancelled {
            log.debug("Downloading photo \(photo.id) was cancelled")
            break
          }
          log.error("Error saving downloaded image locally", error: error)
          throw error
        }

        try Task.checkCancellation()
        guard downloadGenerations[photo.id] == generation else { return }
        try await database.dbWriter.write { db in
          guard var matchingSize = photo.bestPhotoSize() else { return }
          matchingSize.localPath = localPath
          try matchingSize.save(db)
        }
        // Once persistence commits, the cache file is referenced state even if
        // cancellation wins before the UI reload notification.
        shouldRemoveLocalFile = false
        guard downloadGenerations[photo.id] == generation else { return }
        log.debug("Saved downloaded photo size for \(photo.id)")

        await reloadAllMessagesForPhoto(photo.id, generation: generation)
        return

      } catch {
        if Self.isCancellation(error) || Task.isCancelled {
          log.debug("Downloading photo \(photo.id) was cancelled during attempt \(attempt)")
          break
        }

        log.error("Failed to download photo \(photo.id), attempt \(attempt)", error: error)

        // Check if we should retry based on error type
        if attempt < maxRetries, shouldRetryError(error) {
          let delay = Double(attempt) // 1s, 2s, 3s
          log.debug("Retrying photo \(photo.id) in \(delay) seconds")
          try? await Task.sleep(for: .seconds(delay))
        } else if attempt >= maxRetries {
          log.error("Failed to download photo \(photo.id) after \(maxRetries) attempts")
          break
        } else {
          log.error("Photo \(photo.id) download failed with non-recoverable error", error: error)
          break
        }
      }
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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

  private func triggerMessageReload(message: Message) async {
    await MessagesPublisher.shared
      .messageUpdated(message: message, peer: message.peerId, animated: true)
  }

  private func reloadAllMessagesForPhoto(_ photoId: Int64, generation: UUID) async {
    guard let messages = messagesToReload[photoId] else { return }

    log.debug("Triggering message reload for photo \(photoId) for \(messages.count) messages")
    messagesToReload[photoId] = nil

    for message in messages {
      guard !Task.isCancelled, downloadGenerations[photoId] == generation else { return }
      await MessagesPublisher.shared
        .messageUpdated(message: message, peer: message.peerId, animated: true)
    }
  }

  func retainedReloadMessageCount(photoId: Int64) -> Int {
    messagesToReload[photoId]?.count ?? 0
  }

  // MARK: - Download Helpers

  /// Save a downloaded document to the cache and update the database
  public func saveDocumentDownload(document: DocumentInfo, localPath: String, message: Message? = nil) async throws {
    try await database.dbWriter.write { db in
      let updated = try Document.filter(id: document.id)
        .updateAll(db, [Document.Columns.localPath.set(to: localPath)])
      guard updated == 1 else { throw FileCacheError.failedToSave }
      self.log.debug("Updated document \(document.id) with local path \(localPath)")
    }

    if let message {
      await triggerMessageReload(message: message)
    }
  }

  /// Save a downloaded video to the cache and update the database
  public func saveVideoDownload(video: VideoInfo, localPath: String, message: Message) async throws {
    try await database.dbWriter.write { db in
      let updated = try Video.filter(id: video.id)
        .updateAll(db, [Video.Columns.localPath.set(to: localPath)])
      guard updated == 1 else { throw FileCacheError.failedToSave }
      self.log.debug("Updated video \(video.id) with local path \(localPath)")
    }

    await triggerMessageReload(message: message)
  }

  /// Save a downloaded voice message to the cache and update the message payload.
  public func saveVoiceDownload(message: Message, localPath: String) async throws {
    try await database.dbWriter.write { db in
      guard var storedMessage = try Message.fetchOne(
        db,
        key: ["messageId": message.messageId, "chatId": message.chatId]
      ) else {
        throw FileCacheError.failedToSave
      }

      storedMessage.setVoiceLocalRelativePath(localPath)
      try storedMessage.saveMessage(db)
      self.log.debug("Updated voice message \(message.messageId) with local path \(localPath)")
    }

    await triggerMessageReload(message: message)
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
    let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
    let hasAudio = audioTracks?.isEmpty == false

    // Persist the video to app cache.
    // Keep cache-time work minimal for a faster compose/send path.
    // Upload preprocessing is responsible for any required normalization/transcode.
    let directory = FileHelpers.getLocalCacheDirectory(for: .videos)
    let fileManager = FileManager.default
    let sourceExtension = url.pathExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    let finalExtension = sourceExtension.isEmpty ? "mp4" : sourceExtension
    let localPath = "\(UUID().uuidString).\(finalExtension)"
    let localUrl = directory.appendingPathComponent(localPath)
    if fileManager.fileExists(atPath: localUrl.path) {
      try fileManager.removeItem(at: localUrl)
    }
    try fileManager.copyItem(at: url, to: localUrl)
    let fileSize = FileHelpers.getFileSize(at: localUrl)

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
      width: width,
      height: height,
      duration: durationSeconds,
      size: fileSize,
      thumbnail: thumbnailInfo?.photo,
      localPath: localPath,
      isAnimated: false,
      hasAudio: hasAudio
    )

    return VideoInfo(video: video, photoInfo: thumbnailInfo)
  }

  public static func saveAnimatedImageAsVideo(
    url: URL,
    options: AnimatedImageVideoConversionOptions = .uploadDefault
  ) async throws -> InlineKit.VideoInfo {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

    let conversion = try await AnimatedImageVideoConverter.convertGIF(at: url, options: options)
    let directory = FileHelpers.getLocalCacheDirectory(for: .videos)
    let localPath = "\(UUID().uuidString).mp4"
    let localUrl = directory.appendingPathComponent(localPath)

    if FileManager.default.fileExists(atPath: localUrl.path) {
      try FileManager.default.removeItem(at: localUrl)
    }
    try FileManager.default.moveItem(at: conversion.url, to: localUrl)

    let thumbnailInfo: PhotoInfo? = if let thumbnail = conversion.thumbnail {
      try? savePhoto(image: thumbnail, preferredFormat: .jpeg)
    } else {
      nil
    }

    let video = try MediaHelpers.shared.createLocalVideo(
      width: conversion.width,
      height: conversion.height,
      duration: conversion.duration,
      size: Int(conversion.fileSize),
      thumbnail: thumbnailInfo?.photo,
      localPath: localPath,
      isAnimated: true,
      hasAudio: false
    )

    return VideoInfo(video: video, photoInfo: thumbnailInfo)
  }

  public static func exportAnimatedVideoAsGIF(
    url: URL,
    options: AnimatedVideoGIFExportOptions = .saveDefault
  ) async throws -> URL {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

    return try await AnimatedVideoGIFExporter.exportGIF(fromVideoAt: url, options: options).url
  }

  public static func saveVoice(
    data: Data,
    duration: Int,
    waveform: Data,
    mimeType: String,
    fileExtension: String
  ) throws -> Client_MessageVoiceContent {
    let normalizedExtension = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let finalExtension = normalizedExtension.hasPrefix(".") ? normalizedExtension : ".\(normalizedExtension)"
    let localPath = "\(UUID().uuidString)\(finalExtension)"
    let fileURL = FileHelpers.getLocalCacheDirectory(for: .voices).appendingPathComponent(localPath)

    try data.write(to: fileURL, options: .atomic)

    return Client_MessageVoiceContent.with {
      $0.voiceID = temporaryLocalMediaID()
      $0.duration = Int32(max(duration, 0))
      $0.waveform = waveform
      $0.mimeType = mimeType
      $0.localRelativePath = localPath
      $0.size = Int64(data.count)
    }
  }

  private static func temporaryLocalMediaID() -> Int64 {
    makeTemporaryLocalMediaID()
  }

  public static func saveDocument(url: URL) throws -> InlineKit.DocumentInfo {
    let staged = try stageDocument(url: url)
    do {
      return try persistDocument(staged, thumbnail: nil)
    } catch {
      try? removeLocalCacheFile(staged.localURL)
      throw error
    }
  }

  public static func saveDocumentWithImmediateThumbnail(url: URL) throws -> InlineKit.DocumentInfo {
    let staged = try stageDocument(url: url)
    let thumbnail = DocumentThumbnailIntegration.generateImmediately(at: staged.localURL)
      .flatMap { try? saveDocumentThumbnail($0) }
    do {
      return try persistDocument(staged, thumbnail: thumbnail)
    } catch {
      if let thumbnail {
        try? discardLocalThumbnail(
          thumbnail,
          database: AppDatabase.shared,
          photoDirectory: FileHelpers.getLocalCacheDirectory(for: .photos)
        )
      }
      try? removeLocalCacheFile(staged.localURL)
      throw error
    }
  }

  /// Copies the document first, then performs optional thumbnail enrichment away from UI actors.
  /// Thumbnail failure is intentionally swallowed; only staging/persistence can fail the attachment.
  public static func saveDocumentWithThumbnail(url: URL) async throws -> InlineKit.DocumentInfo {
    let stagingTask = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try stageDocument(url: url)
    }
    let staged = try await withTaskCancellationHandler {
      try await stagingTask.value
    } onCancel: {
      stagingTask.cancel()
    }

    var persistedDocument: DocumentInfo?
    do {
      try Task.checkCancellation()
      let artifact = await DocumentThumbnailIntegration.generate(at: staged.localURL)
      try Task.checkCancellation()

      let persistenceTask = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        var thumbnail: PhotoInfo?
        var document: DocumentInfo?
        do {
          thumbnail = artifact.flatMap { try? saveDocumentThumbnail($0) }
          try Task.checkCancellation()
          let persisted = try persistDocument(staged, thumbnail: thumbnail)
          document = persisted
          try Task.checkCancellation()
          return persisted
        } catch {
          if let document {
            try? discardLocalDocument(
              document,
              database: AppDatabase.shared,
              documentDirectory: FileHelpers.getLocalCacheDirectory(for: .documents),
              photoDirectory: FileHelpers.getLocalCacheDirectory(for: .photos)
            )
          } else if let thumbnail {
            try? discardLocalThumbnail(
              thumbnail,
              database: AppDatabase.shared,
              photoDirectory: FileHelpers.getLocalCacheDirectory(for: .photos)
            )
          }
          throw error
        }
      }
      let document = try await withTaskCancellationHandler {
        try await persistenceTask.value
      } onCancel: {
        persistenceTask.cancel()
      }
      persistedDocument = document
      try Task.checkCancellation()
      return document
    } catch {
      if let persistedDocument {
        await discardLocalDocument(persistedDocument)
      } else {
        try? removeLocalCacheFile(staged.localURL)
      }
      throw error
    }
  }

  private struct StagedDocument: Sendable {
    let fileName: String
    let localPath: String
    let localURL: URL
    let fileSize: Int
    let mimeType: String?
  }

  private static func stageDocument(url: URL) throws -> StagedDocument {
    let fileName = url.lastPathComponent

    let fileManager = FileManager.default
    let directory = FileHelpers.getLocalCacheDirectory(for: .documents)
    let localPath = UUID().uuidString + "-" + fileName
    let localURL = directory.appendingPathComponent(localPath)

    let hasAccess = url.startAccessingSecurityScopedResource()
    defer {
      if hasAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    try Task.checkCancellation()
    try fileManager.copyItem(at: url, to: localURL)
    do {
      try Task.checkCancellation()
    } catch {
      try? removeLocalCacheFile(localURL)
      throw error
    }

    return StagedDocument(
      fileName: fileName,
      localPath: localPath,
      localURL: localURL,
      fileSize: FileHelpers.getFileSize(at: localURL),
      mimeType: FileHelpers.getMimeType(for: localURL)
    )
  }

  private static func persistDocument(
    _ staged: StagedDocument,
    thumbnail: PhotoInfo?
  ) throws -> InlineKit.DocumentInfo {
    try AppDatabase.shared.dbWriter.write { db in
      try Document.createLocalDocument(
        db,
        fileName: staged.fileName,
        mimeType: staged.mimeType,
        size: staged.fileSize,
        localPath: staged.localPath,
        thumbnail: thumbnail
      )
    }
  }

  private static func saveDocumentThumbnail(
    _ artifact: DocumentThumbnailArtifact
  ) throws -> PhotoInfo {
    let localPath = "\(UUID().uuidString).jpg"
    let directory = FileHelpers.getLocalCacheDirectory(for: .photos)
    let url = directory.appendingPathComponent(localPath)
    try artifact.jpegData.write(to: url, options: .atomic)

    do {
      return try AppDatabase.shared.dbWriter.write { db in
        try Photo.createLocalPhoto(
          db,
          format: .jpeg,
          localPath: localPath,
          fileSize: artifact.jpegData.count,
          width: artifact.pixelWidth,
          height: artifact.pixelHeight
        )
      }
    } catch {
      try? removeLocalCacheFile(url)
      throw error
    }
  }

  static func discardLocalDocument(_ documentInfo: DocumentInfo) async {
    await discardLocalDocument(
      documentInfo,
      database: AppDatabase.shared,
      documentDirectory: FileHelpers.getLocalCacheDirectory(for: .documents),
      photoDirectory: FileHelpers.getLocalCacheDirectory(for: .photos)
    )
  }

  static func discardLocalDocument(
    _ documentInfo: DocumentInfo,
    database: AppDatabase,
    documentDirectory: URL,
    photoDirectory: URL
  ) async {
    do {
      try await Task.detached(priority: .utility) {
        try discardLocalDocument(
          documentInfo,
          database: database,
          documentDirectory: documentDirectory,
          photoDirectory: photoDirectory
        )
      }.value
    } catch {
      Log.shared.error("Failed to discard cancelled local document", error: error)
    }
  }

  private static func discardLocalDocument(
    _ documentInfo: DocumentInfo,
    database: AppDatabase,
    documentDirectory: URL,
    photoDirectory: URL
  ) throws {
    guard documentInfo.document.documentId < 0 else { return }

    try database.dbWriter.write { db in
      _ = try Document
        .filter(Document.Columns.documentId == documentInfo.document.documentId)
        .deleteAll(db)
      if let thumbnail = documentInfo.thumbnail, thumbnail.photo.photoId < 0,
         let photoID = thumbnail.photo.id {
        _ = try PhotoSize.filter(PhotoSize.Columns.photoId == photoID).deleteAll(db)
        _ = try Photo.filter(Photo.Columns.id == photoID).deleteAll(db)
      }
    }

    if let localPath = documentInfo.document.localPath,
       let fileURL = localCacheURL(localPath: localPath, directory: documentDirectory) {
      try removeLocalCacheFile(fileURL)
    }
    for size in documentInfo.thumbnail?.sizes ?? [] {
      if let localPath = size.localPath,
         let fileURL = localCacheURL(localPath: localPath, directory: photoDirectory) {
        try removeLocalCacheFile(fileURL)
      }
    }
  }

  private static func discardLocalThumbnail(
    _ thumbnail: PhotoInfo,
    database: AppDatabase,
    photoDirectory: URL
  ) throws {
    guard thumbnail.photo.photoId < 0, let photoID = thumbnail.photo.id else { return }
    try database.dbWriter.write { db in
      _ = try PhotoSize.filter(PhotoSize.Columns.photoId == photoID).deleteAll(db)
      _ = try Photo.filter(Photo.Columns.id == photoID).deleteAll(db)
    }
    for size in thumbnail.sizes {
      if let localPath = size.localPath,
         let fileURL = localCacheURL(localPath: localPath, directory: photoDirectory) {
        try removeLocalCacheFile(fileURL)
      }
    }
  }

  private static func localCacheURL(localPath: String, directory: URL) -> URL? {
    let directory = directory.standardizedFileURL
    let candidate = directory.appendingPathComponent(localPath).standardizedFileURL
    guard candidate.deletingLastPathComponent() == directory else { return nil }
    return candidate
  }

  private static func removeLocalCacheFile(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
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

    // Clear voices
    try await clearVoiceCache()
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

  private func clearVoiceCache() async throws {
    let voiceCacheEntries = try await database.dbWriter.read { db in
      var entries: [(messageId: Int64, chatId: Int64, localPath: String)] = []
      let cursor = try Message
        .filter(sql: "contentPayload IS NOT NULL")
        .fetchCursor(db)

      while let message = try cursor.next() {
        guard let localPath = message.voiceLocalRelativePath else { continue }
        entries.append((message.messageId, message.chatId, localPath))
      }

      return entries
    }

    log.debug("Found \(voiceCacheEntries.count) cached voices to clear")

    var deletedCount = 0
    var failedDeletions = 0

    for entry in voiceCacheEntries {
      let localPath = entry.localPath
      let fileURL = FileCache.getUrl(for: .voices, localPath: localPath)

      do {
        if FileManager.default.fileExists(atPath: fileURL.path) {
          try FileManager.default.removeItem(at: fileURL)
          deletedCount += 1
        }
      } catch {
        failedDeletions += 1
        log.error("Failed to delete cached voice at \(fileURL): \(error)")
      }
    }

    _ = try await database.dbWriter.write { db in
      for entry in voiceCacheEntries {
        guard var message = try Message.fetchOne(
          db,
          key: ["messageId": entry.messageId, "chatId": entry.chatId]
        ) else {
          continue
        }

        message.setVoiceLocalRelativePath(nil)
        try message.saveMessage(db)
      }
    }

    log.info("Voice cache cleared: \(deletedCount) files deleted, \(failedDeletions) deletions failed")

    try clearOrphanedFiles(in: .voices)
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
