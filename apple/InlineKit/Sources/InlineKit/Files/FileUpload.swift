import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import AVFoundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public struct UploadResult: Sendable {
  public var photoId: Int64?
  public var videoId: Int64?
  public var documentId: Int64?
}

private struct UploadTaskInfo {
  let task: Task<UploadResult, any Error>
  let priority: TaskPriority
  let startTime: Date
  var progress: Double = 0
}

public enum UploadStatus {
  case notFound
  case processing
  case inProgress(progress: Double)
  case completed
}

public actor FileUploader {
  public static let shared = FileUploader()

  // Replace simple dictionaries with more structured storage
  private var uploadTasks: [String: UploadTaskInfo] = [:]
  private var finishedUploads: [String: UploadResult] = [:]
  private var progressHandlers: [String: @Sendable (Double) -> Void] = [:]
  private var cleanupTasks: [String: Task<Void, Never>] = [:]

  private init() {}

  // MARK: - Upload ID Helpers

  public static func uploadIdForPhotoLocalId(_ id: Int64) -> String {
    "photo_\(id)"
  }

  public static func uploadIdForVideoLocalId(_ id: Int64) -> String {
    "video_\(id)"
  }

  public static func uploadIdForDocumentLocalId(_ id: Int64) -> String {
    "document_\(id)"
  }

  @MainActor
  public static func videoUploadProgressPublisher(
    videoLocalId: Int64
  ) -> AnyPublisher<UploadProgressEvent, Never> {
    UploadProgressCenter.shared.publisher(for: uploadIdForVideoLocalId(videoLocalId))
  }

  @MainActor
  public static func documentUploadProgressPublisher(
    documentLocalId: Int64
  ) -> AnyPublisher<UploadProgressEvent, Never> {
    UploadProgressCenter.shared.publisher(for: uploadIdForDocumentLocalId(documentLocalId))
  }

  @MainActor
  public static func photoUploadProgressPublisher(
    photoLocalId: Int64
  ) -> AnyPublisher<UploadProgressEvent, Never> {
    UploadProgressCenter.shared.publisher(for: uploadIdForPhotoLocalId(photoLocalId))
  }

  // MARK: - Task Management

  private func registerTask(
    uploadId: String,
    task: Task<UploadResult, any Error>,
    priority: TaskPriority = .userInitiated
  ) {
    uploadTasks[uploadId] = UploadTaskInfo(
      task: task,
      priority: priority,
      startTime: Date()
    )

    // Setup cleanup task
    cleanupTasks[uploadId] = Task { [weak self] in
      do {
        _ = try await task.value
        await self?.handleTaskCompletion(uploadId: uploadId)
      } catch {
        await self?.handleTaskFailure(uploadId: uploadId, error: error)
      }
    }
  }

  private func handleTaskCompletion(uploadId: String) {
    Log.shared.debug("[FileUploader] Upload task completed for \(uploadId)")
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
    Task { @MainActor in
      UploadProgressCenter.shared.clear(id: uploadId)
    }
  }

  private func handleTaskFailure(uploadId: String, error: Error) {
    Log.shared.error(
      "[FileUploader] Upload task failed for \(uploadId)",
      error: error
    )
    let phase: UploadPhase = error is CancellationError ? .cancelled : .failed
    publishProgressEvent(uploadId: uploadId, phase: phase)
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
    Task { @MainActor in
      UploadProgressCenter.shared.clear(id: uploadId)
    }
  }

  // MARK: - Progress Tracking

  private func updateProgress(uploadId: String, progress: ApiClient.UploadTransferProgress) {
    if var taskInfo = uploadTasks[uploadId] {
      taskInfo.progress = progress.fraction
      uploadTasks[uploadId] = taskInfo
      // Create a local copy of the handler to avoid actor isolation issues
      if let handler = progressHandlers[uploadId] {
        Task { @MainActor in
          await MainActor.run {
            handler(progress.fraction)
          }
        }
      }

      publishProgressEvent(
        uploadId: uploadId,
        phase: .uploading,
        bytesSent: progress.bytesSent,
        totalBytes: progress.totalBytes
      )
    }
  }

  public func setProgressHandler(for uploadId: String, handler: @escaping @Sendable (Double) -> Void) {
    progressHandlers[uploadId] = handler
    // Immediately report current progress if available
    if let taskInfo = uploadTasks[uploadId] {
      Task { @MainActor in
        await MainActor.run {
          handler(taskInfo.progress)
        }
      }
    }
  }

  private func publishProgressEvent(
    uploadId: String,
    phase: UploadPhase,
    bytesSent: Int64 = 0,
    totalBytes: Int64 = 0
  ) {
    let event = UploadProgressEvent(
      id: uploadId,
      phase: phase,
      bytesSent: bytesSent,
      totalBytes: totalBytes
    )
    Task { @MainActor in
      UploadProgressCenter.shared.publish(event)
    }
  }

  // MARK: - Upload Methods

  public func uploadPhoto(
    photoInfo: PhotoInfo
  ) throws -> Int64 {
    let photoSize = photoInfo.bestPhotoSize()
    guard let photoSize,
          let localPath = photoSize.localPath
    else {
      throw FileUploadError.invalidPhoto
    }
    let localUrl = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(
      localPath
    )
    let format = photoInfo.photo.format
    let ext = format.toExt()
    let fileName = localPath.components(separatedBy: "/").last ?? "" + ext
    let mimeType = format.toMimeType()

    let uploadId = getUploadId(photoId: photoInfo.photo.id!)
    publishProgressEvent(uploadId: uploadId, phase: .uploading, bytesSent: 0, totalBytes: 0)

    try startUpload(
      media: .photo(photoInfo),
      localUrl: localUrl,
      mimeType: mimeType,
      fileName: fileName
    )

    guard let localPhotoId = photoInfo.photo.id else { throw FileUploadError.invalidPhotoId }

    return localPhotoId
  }

  public func uploadVideo(
    videoInfo: VideoInfo
  ) async throws -> Int64 {
    // Ensure we have a persisted local video row and id
    var resolvedVideoInfo = videoInfo
    var video = resolvedVideoInfo.video
    let localVideoId = try resolveLocalVideoId(for: video)
    video.id = localVideoId
    resolvedVideoInfo.video = video

    guard let localPath = resolvedVideoInfo.video.localPath else {
      throw FileUploadError.invalidVideo
    }

    let localUrl = FileHelpers.getLocalCacheDirectory(for: .videos).appendingPathComponent(localPath)
    let uploadId = getUploadId(videoId: localVideoId)
    let fileName = localUrl.lastPathComponent
    let mimeType = MIMEType(text: FileHelpers.getMimeType(for: localUrl))
    publishProgressEvent(uploadId: uploadId, phase: .processing)

    try startUpload(
      media: .video(resolvedVideoInfo),
      localUrl: localUrl,
      mimeType: mimeType.text,
      fileName: fileName
    )

    return localVideoId
  }

  public func uploadDocument(
    documentInfo: DocumentInfo
  ) async throws -> Int64 {
    guard let localPath = documentInfo.document.localPath else {
      Log.shared.error("Document did not have a local path")
      throw FileUploadError.invalidDocument
    }
    let localUrl = FileHelpers.getLocalCacheDirectory(for: .documents).appendingPathComponent(
      localPath
    )
    let fileName = documentInfo.document.fileName ?? "document"
    let mimeType = documentInfo.document.mimeType ?? "application/octet-stream"
    if let localId = documentInfo.document.id {
      publishProgressEvent(uploadId: getUploadId(documentId: localId), phase: .uploading)
    }
    try startUpload(
      media: .document(documentInfo),
      localUrl: localUrl,
      mimeType: mimeType,
      fileName: fileName
    )

    guard let localId = documentInfo.document.id else { throw FileUploadError.invalidDocumentId }
    return localId
  }

  public func startUpload(
    media: FileMediaItem,
    localUrl: URL,
    mimeType: String,
    fileName: String,
    priority: TaskPriority = .userInitiated
  ) throws {
    let type: MessageFileType
    let uploadId: String

    switch media {
      case let .photo(photoInfo):
        uploadId = getUploadId(photoId: photoInfo.photo.id!)
        type = .photo
      case let .video(videoInfo):
        guard let localVideoId = videoInfo.video.id else {
          throw FileUploadError.invalidVideoId
        }

        uploadId = getUploadId(videoId: localVideoId)
        type = .video
      case let .document(documentInfo):
        uploadId = getUploadId(documentId: documentInfo.document.id!)
        type = .document
    }

    // Check if upload already exists
    if uploadTasks[uploadId] != nil {
      Log.shared.warning("[FileUploader] Upload already in progress for \(uploadId)")
      throw FileUploadError.uploadAlreadyInProgress
    }

    if finishedUploads[uploadId] != nil {
      Log.shared.warning("[FileUploader] Upload already completed for \(uploadId)")
      //throw FileUploadError.uploadAlreadyCompleted
      return 
    }

    let task = Task<UploadResult, any Error>(priority: priority) {
      try await FileUploader.shared.performUpload(
        uploadId: uploadId,
        media: media,
        localUrl: localUrl,
        mimeType: mimeType,
        fileName: fileName,
        type: type
      )
    }

    // Register the task
    registerTask(uploadId: uploadId, task: task, priority: priority)
  }

  private func performUpload(
    uploadId: String,
    media: FileMediaItem,
    localUrl: URL,
    mimeType: String,
    fileName: String,
    type: MessageFileType
  ) async throws -> UploadResult {
    Log.shared.debug("[FileUploader] Starting upload for \(uploadId)")

    var uploadUrl = localUrl
    var effectiveMimeType = mimeType
    var effectiveFileName = fileName
    var effectiveVideoMetadata: ApiClient.VideoUploadMetadata?
    var cleanupURL: URL?

    if case .photo = media {
      do {
        let options = mimeType.lowercased().contains("png") ?
          ImageCompressionOptions.defaultPNG :
          ImageCompressionOptions.defaultPhoto
        uploadUrl = try await ImageCompressor.shared.compressImage(at: localUrl, options: options)
      } catch {
        uploadUrl = localUrl
      }
    } else if case let .video(videoInfo) = media {
      publishProgressEvent(uploadId: uploadId, phase: .processing)
      let preparedVideo = try await prepareVideoUpload(localUrl: localUrl, videoInfo: videoInfo)
      uploadUrl = preparedVideo.url
      effectiveMimeType = preparedVideo.mimeType
      effectiveFileName = preparedVideo.fileName
      effectiveVideoMetadata = preparedVideo.metadata
      cleanupURL = preparedVideo.cleanupURL
    }

    defer {
      if let cleanupURL, FileManager.default.fileExists(atPath: cleanupURL.path) {
        try? FileManager.default.removeItem(at: cleanupURL)
      }
    }

    // get data from file
    let data = try Data(contentsOf: uploadUrl)

    // upload file with progress tracking
    let progressHandler = FileUploader.progressHandler(for: uploadId)

    let result = try await ApiClient.shared.uploadFile(
      type: type,
      data: data,
      filename: effectiveFileName,
      mimeType: MIMEType(text: effectiveMimeType),
      videoMetadata: effectiveVideoMetadata,
      progress: progressHandler
    )

    publishProgressEvent(
      uploadId: uploadId,
      phase: .completed,
      bytesSent: Int64(data.count),
      totalBytes: Int64(data.count)
    )

    // TODO: Set compressed file in db if it was created

    // return IDs
    let result_ = UploadResult(
      photoId: result.photoId,
      videoId: result.videoId,
      documentId: result.documentId
    )

    // Update database with new ID
    do {
      try await updateDatabaseWithServerIds(media: media, result: result)
      Log.shared.debug("[FileUploader] Successfully updated database for \(uploadId)")

      // Store result after successful database update
      storeUploadResult(uploadId: uploadId, result: result_)
    } catch {
      Log.shared.error(
        "[FileUploader] Failed to update database with new server ID for \(uploadId)",
        error: error
      )
      throw FileUploadError.failedToSave
    }

    return result_
  }

  private func storeUploadResult(uploadId: String, result: UploadResult) {
    finishedUploads[uploadId] = result
  }

  // MARK: - Task Control

  public func cancel(uploadId: String) {
    Log.shared.debug("[FileUploader] Cancelling upload for \(uploadId)")

    if let taskInfo = uploadTasks[uploadId] {
      taskInfo.task.cancel()
      publishProgressEvent(uploadId: uploadId, phase: .cancelled)
      uploadTasks.removeValue(forKey: uploadId)
      cleanupTasks.removeValue(forKey: uploadId)
      progressHandlers.removeValue(forKey: uploadId)
      Task { @MainActor in
        UploadProgressCenter.shared.clear(id: uploadId)
      }
    }
  }

  public func cancelVideoUpload(videoLocalId: Int64) {
    cancel(uploadId: getUploadId(videoId: videoLocalId))
  }

  public func cancelAll() {
    Log.shared.debug("[FileUploader] Cancelling all uploads")

    for (uploadId, taskInfo) in uploadTasks {
      taskInfo.task.cancel()
      publishProgressEvent(uploadId: uploadId, phase: .cancelled)
      Task { @MainActor in
        UploadProgressCenter.shared.clear(id: uploadId)
      }
    }

    uploadTasks.removeAll()
    cleanupTasks.removeAll()
    progressHandlers.removeAll()
  }

  // MARK: - Status Queries

  public func getUploadStatus(for uploadId: String) -> UploadStatus {
    if let taskInfo = uploadTasks[uploadId] {
      .inProgress(progress: taskInfo.progress)
    } else if finishedUploads[uploadId] != nil {
      .completed
    } else {
      .notFound
    }
  }

  // MARK: - Database Updates

  private func updateDatabaseWithServerIds(media: FileMediaItem, result: UploadFileResult) async throws {
    switch media {
      case let .photo(photoInfo):
        if let serverId = result.photoId {
          try await AppDatabase.shared.dbWriter.write { db in
            try AppDatabase.updatePhotoWithServerId(db, localPhoto: photoInfo.photo, serverId: serverId)
          }
        }
      case let .video(videoInfo):
        if let serverId = result.videoId {
          try await AppDatabase.shared.dbWriter.write { db in
            try AppDatabase.updateVideoWithServerId(db, localVideo: videoInfo.video, serverId: serverId)
          }
        }

        if let serverThumbId = result.photoId, let localThumb = videoInfo.thumbnail?.photo {
          try await AppDatabase.shared.dbWriter.write { db in
            try AppDatabase.updatePhotoWithServerId(db, localPhoto: localThumb, serverId: serverThumbId)
          }
        }
      case let .document(documentInfo):
        if let serverId = result.documentId {
          try await AppDatabase.shared.dbWriter.write { db in
            try AppDatabase.updateDocumentWithServerId(
              db,
              localDocument: documentInfo.document,
              serverId: serverId
            )
          }
        }
    }
  }

  // MARK: - Helpers

  private func getUploadId(photoId: Int64) -> String {
    Self.uploadIdForPhotoLocalId(photoId)
  }

  private func getUploadId(videoId: Int64) -> String {
    Self.uploadIdForVideoLocalId(videoId)
  }

  private func getUploadId(documentId: Int64) -> String {
    Self.uploadIdForDocumentLocalId(documentId)
  }

  private func resolveLocalVideoId(for video: Video) throws -> Int64 {
    if let id = video.id { return id }

    // Try to fetch the video row by temporary/server videoId
    let fetched: Video? = try AppDatabase.shared.dbWriter.read { db in
      try Video
        .filter(Video.Columns.videoId == video.videoId)
        .fetchOne(db)
    }

    guard let fetched, let id = fetched.id else {
      throw FileUploadError.invalidVideoId
    }

    return id
  }

  // Nonisolated helper so progress closures don't capture actor-isolated state
  static func progressHandler(
    for uploadId: String
  ) -> @Sendable (ApiClient.UploadTransferProgress) -> Void {
    return { progress in
      Task {
        await FileUploader.shared.updateProgress(uploadId: uploadId, progress: progress)
      }
    }
  }

  private func thumbnailData(from photoInfo: PhotoInfo?) throws -> (Data, MIMEType)? {
    guard
      let photoInfo,
      let localPath = photoInfo.sizes.first?.localPath
    else { return nil }

    let url = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(localPath)
    let data = try Data(contentsOf: url)
    let mimeType = MIMEType(text: FileHelpers.getMimeType(for: url))
    return (data, mimeType)
  }

  private struct PreparedVideoUpload {
    let url: URL
    let fileName: String
    let mimeType: String
    let metadata: ApiClient.VideoUploadMetadata
    let cleanupURL: URL?
  }

  private func prepareVideoUpload(
    localUrl: URL,
    videoInfo: VideoInfo
  ) async throws -> PreparedVideoUpload {
    let sourceExtension = localUrl.pathExtension.lowercased()
    let needsMp4Transcode = sourceExtension != "mp4"
    let options = VideoCompressionOptions.uploadDefault(forceTranscode: needsMp4Transcode)
    let thumbnailPayload = try? thumbnailData(from: videoInfo.thumbnail)
    let thumbnailData_ = thumbnailPayload?.0
    let thumbnailMimeType = thumbnailPayload?.1

    func makeMetadata(width: Int, height: Int, duration: Int) -> ApiClient.VideoUploadMetadata {
      ApiClient.VideoUploadMetadata(
        width: width,
        height: height,
        duration: duration,
        thumbnail: thumbnailData_,
        thumbnailMimeType: thumbnailMimeType
      )
    }

    func sourceMetadata() async throws -> ApiClient.VideoUploadMetadata {
      let (width, height, duration) = try await self.getValidatedVideoMetadata(from: videoInfo, localUrl: localUrl)
      return makeMetadata(width: width, height: height, duration: duration)
    }

    if needsMp4Transcode {
      let result = try await VideoCompressor.shared.compressVideo(at: localUrl, options: options)
      return PreparedVideoUpload(
        url: result.url,
        fileName: result.url.lastPathComponent,
        mimeType: "video/mp4",
        metadata: makeMetadata(width: result.width, height: result.height, duration: result.duration),
        cleanupURL: result.url
      )
    }

    do {
      let result = try await VideoCompressor.shared.compressVideo(at: localUrl, options: options)
      return PreparedVideoUpload(
        url: result.url,
        fileName: result.url.lastPathComponent,
        mimeType: "video/mp4",
        metadata: makeMetadata(width: result.width, height: result.height, duration: result.duration),
        cleanupURL: result.url
      )
    } catch VideoCompressionError.compressionNotNeeded {
      return PreparedVideoUpload(
        url: localUrl,
        fileName: localUrl.lastPathComponent,
        mimeType: "video/mp4",
        metadata: try await sourceMetadata(),
        cleanupURL: nil
      )
    } catch VideoCompressionError.compressionNotEffective {
      return PreparedVideoUpload(
        url: localUrl,
        fileName: localUrl.lastPathComponent,
        mimeType: "video/mp4",
        metadata: try await sourceMetadata(),
        cleanupURL: nil
      )
    } catch {
      Log.shared.warning("[FileUploader] Video compression failed, falling back to original MP4 for \(localUrl.lastPathComponent)")
      return PreparedVideoUpload(
        url: localUrl,
        fileName: localUrl.lastPathComponent,
        mimeType: "video/mp4",
        metadata: try await sourceMetadata(),
        cleanupURL: nil
      )
    }
  }

  // MARK: - Video Metadata Helpers

  private func getValidatedVideoMetadata(
    from videoInfo: VideoInfo,
    localUrl: URL
  ) async throws -> (Int, Int, Int) {
    var width = videoInfo.video.width ?? 0
    var height = videoInfo.video.height ?? 0
    var duration = videoInfo.video.duration ?? 0

    // Fallback to reading from the file if any value is missing/zero
    if width == 0 || height == 0 || duration == 0 {
      let asset = AVURLAsset(url: localUrl)
      let tracks = try await asset.loadTracks(withMediaType: .video)
      if let track = tracks.first {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformedSize = naturalSize.applying(transform)
        width = Int(abs(transformedSize.width.rounded()))
        height = Int(abs(transformedSize.height.rounded()))
      }

      let durationTime = try await asset.load(.duration)
      let seconds = CMTimeGetSeconds(durationTime)
      if seconds.isFinite {
        duration = Int(seconds.rounded())
      }
    }

    // Guard against missing metadata because the server requires them
    guard width > 0, height > 0, duration > 0 else {
      throw FileUploadError.invalidVideoMetadata
    }

    return (width, height, duration)
  }

  // MARK: - Wait for Upload

  public func waitForUpload(photoLocalId id: Int64) async throws -> UploadResult? {
    try await waitForUpload(uploadId: getUploadId(photoId: id))
  }

  public func waitForUpload(videoLocalId id: Int64) async throws -> UploadResult? {
    try await waitForUpload(uploadId: getUploadId(videoId: id))
  }

  public func waitForUpload(documentLocalId id: Int64) async throws -> UploadResult? {
    try await waitForUpload(uploadId: getUploadId(documentId: id))
  }

  private func waitForUpload(uploadId: String) async throws -> UploadResult? {
    if let taskInfo = uploadTasks[uploadId] {
      // still in progress
      return try await taskInfo.task.value
    } else if let result = finishedUploads[uploadId] {
      // finished
      return result
    } else {
      // not found
      Log.shared.warning("[FileUploader] Upload not found for \(uploadId)")
      throw FileUploadError.failedToUpload
      // return UploadResult(photoId: nil, videoId: nil, documentId: nil)
    }
  }
}

public enum FileUploadError: Error {
  case failedToUpload
  case failedToSave
  case invalidPhoto
  case invalidVideo
  case invalidDocument
  case invalidPhotoId
  case invalidDocumentId
  case invalidVideoId
  case invalidVideoMetadata
  case uploadAlreadyInProgress
  case uploadAlreadyCompleted
  case uploadCancelled
  case uploadTimeout
}
