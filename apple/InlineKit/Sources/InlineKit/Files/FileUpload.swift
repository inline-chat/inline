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
  var progress: UploadProgressSnapshot
}

public enum UploadProgressStage: String, Sendable, Equatable {
  case processing
  case uploading
  case completed
  case failed
}

public struct UploadProgressSnapshot: Sendable, Equatable {
  public let id: String
  public let stage: UploadProgressStage
  public let bytesSent: Int64
  public let totalBytes: Int64
  public let fractionCompleted: Double
  public let errorDescription: String?

  private init(
    id: String,
    stage: UploadProgressStage,
    bytesSent: Int64,
    totalBytes: Int64,
    fractionCompleted: Double,
    errorDescription: String? = nil
  ) {
    self.id = id
    self.stage = stage
    self.bytesSent = max(0, bytesSent)
    self.totalBytes = max(0, totalBytes)
    self.fractionCompleted = min(max(fractionCompleted, 0), 1)
    self.errorDescription = errorDescription
  }

  public static func processing(id: String) -> UploadProgressSnapshot {
    UploadProgressSnapshot(
      id: id,
      stage: .processing,
      bytesSent: 0,
      totalBytes: 0,
      fractionCompleted: 0
    )
  }

  public static func uploading(id: String, bytesSent: Int64, totalBytes: Int64) -> UploadProgressSnapshot {
    let clampedTotal = max(0, totalBytes)
    let clampedBytes = min(max(0, bytesSent), clampedTotal)
    let fraction = clampedTotal > 0 ? Double(clampedBytes) / Double(clampedTotal) : 0
    return UploadProgressSnapshot(
      id: id,
      stage: .uploading,
      bytesSent: clampedBytes,
      totalBytes: clampedTotal,
      fractionCompleted: fraction
    )
  }

  public static func completed(id: String, totalBytes: Int64) -> UploadProgressSnapshot {
    let clampedTotal = max(0, totalBytes)
    return UploadProgressSnapshot(
      id: id,
      stage: .completed,
      bytesSent: clampedTotal,
      totalBytes: clampedTotal,
      fractionCompleted: 1
    )
  }

  public static func failed(id: String, error: Error?) -> UploadProgressSnapshot {
    UploadProgressSnapshot(
      id: id,
      stage: .failed,
      bytesSent: 0,
      totalBytes: 0,
      fractionCompleted: 0,
      errorDescription: error?.localizedDescription
    )
  }
}

public enum UploadStatus {
  case notFound
  case inProgress(UploadProgressSnapshot)
  case completed
  case failed
}

public actor FileUploader {
  public static let shared = FileUploader()

  // Replace simple dictionaries with more structured storage
  private var uploadTasks: [String: UploadTaskInfo] = [:]
  private var finishedUploads: [String: UploadResult] = [:]
  private var progressHandlers: [String: @Sendable (UploadProgressSnapshot) -> Void] = [:]
  private var progressPublishers: [String: CurrentValueSubject<UploadProgressSnapshot, Never>] = [:]
  private var latestProgress: [String: UploadProgressSnapshot] = [:]
  private var cleanupTasks: [String: Task<Void, Never>] = [:]

  private init() {}

  // MARK: - Task Management

  private func registerTask(
    uploadId: String,
    task: Task<UploadResult, any Error>,
    priority: TaskPriority = .userInitiated
  ) {
    let initialProgress = latestProgress[uploadId] ?? .processing(id: uploadId)
    uploadTasks[uploadId] = UploadTaskInfo(
      task: task,
      priority: priority,
      startTime: Date(),
      progress: initialProgress
    )
    publishProgress(uploadId: uploadId, progress: initialProgress)

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
    if let latest = latestProgress[uploadId], latest.stage != .completed {
      let totalBytes = max(latest.totalBytes, latest.bytesSent)
      publishProgress(uploadId: uploadId, progress: .completed(id: uploadId, totalBytes: totalBytes))
    }
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
  }

  private func handleTaskFailure(uploadId: String, error: Error) {
    Log.shared.error(
      "[FileUploader] Upload task failed for \(uploadId)",
      error: error
    )
    publishProgress(uploadId: uploadId, progress: .failed(id: uploadId, error: error))
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
  }

  // MARK: - Progress Tracking

  private func updateProgress(uploadId: String, progress: UploadProgressSnapshot) {
    publishProgress(uploadId: uploadId, progress: progress)
  }

  private func publishProgress(uploadId: String, progress: UploadProgressSnapshot) {
    latestProgress[uploadId] = progress
    if var taskInfo = uploadTasks[uploadId] {
      taskInfo.progress = progress
      uploadTasks[uploadId] = taskInfo
    }

    if let handler = progressHandlers[uploadId] {
      Task { @MainActor in
        await MainActor.run {
          handler(progress)
        }
      }
    }

    if let publisher = progressPublishers[uploadId] {
      publisher.send(progress)
    }
  }

  private func progressPublisher(for uploadId: String) -> CurrentValueSubject<UploadProgressSnapshot, Never> {
    if let existing = progressPublishers[uploadId] {
      return existing
    }

    let initialProgress = latestProgress[uploadId] ?? .processing(id: uploadId)
    let publisher = CurrentValueSubject<UploadProgressSnapshot, Never>(initialProgress)
    progressPublishers[uploadId] = publisher
    return publisher
  }

  public func videoProgressPublisher(videoLocalId: Int64) -> AnyPublisher<UploadProgressSnapshot, Never> {
    progressPublisher(for: getUploadId(videoId: videoLocalId)).eraseToAnyPublisher()
  }

  public func documentProgressPublisher(documentLocalId: Int64) -> AnyPublisher<UploadProgressSnapshot, Never> {
    progressPublisher(for: getUploadId(documentId: documentLocalId)).eraseToAnyPublisher()
  }

  public func photoProgressPublisher(photoLocalId: Int64) -> AnyPublisher<UploadProgressSnapshot, Never> {
    progressPublisher(for: getUploadId(photoId: photoLocalId)).eraseToAnyPublisher()
  }

  public func setUploadProgressHandler(
    for uploadId: String,
    handler: @escaping @Sendable (UploadProgressSnapshot) -> Void
  ) {
    progressHandlers[uploadId] = handler

    let currentProgress = latestProgress[uploadId] ?? uploadTasks[uploadId]?.progress
    if let currentProgress {
      Task { @MainActor in
        await MainActor.run {
          handler(currentProgress)
        }
      }
    }
  }

  // Legacy API preserved for existing call sites that only understand fraction and -1 processing sentinel.
  public func setProgressHandler(for uploadId: String, handler: @escaping @Sendable (Double) -> Void) {
    setUploadProgressHandler(for: uploadId) { progress in
      switch progress.stage {
      case .processing:
        handler(-1)
      case .uploading, .completed:
        handler(progress.fractionCompleted)
      case .failed:
        handler(0)
      }
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

    publishProgress(uploadId: uploadId, progress: .processing(id: uploadId))

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
    let fileName = localUrl.lastPathComponent
    let mimeType = MIMEType(text: FileHelpers.getMimeType(for: localUrl))

    // Ensure we have required metadata before hitting the API
    let (width, height, duration) = try await getValidatedVideoMetadata(
      from: resolvedVideoInfo,
      localUrl: localUrl
    )

    let uploadId = getUploadId(videoId: localVideoId)
    publishProgress(uploadId: uploadId, progress: .processing(id: uploadId))

    let thumbnailPayload = try? thumbnailData(from: resolvedVideoInfo.thumbnail)
    let videoMetadata = ApiClient.VideoUploadMetadata(
      width: width,
      height: height,
      duration: duration,
      thumbnail: thumbnailPayload?.0,
      thumbnailMimeType: thumbnailPayload?.1
    )

    try startUpload(
      media: .video(resolvedVideoInfo),
      localUrl: localUrl,
      mimeType: mimeType.text,
      fileName: fileName,
      videoMetadata: videoMetadata
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
    priority: TaskPriority = .userInitiated,
    videoMetadata: ApiClient.VideoUploadMetadata? = nil
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
      let latest = latestProgress[uploadId]
      let totalBytes = max(latest?.totalBytes ?? 0, latest?.bytesSent ?? 0)
      publishProgress(uploadId: uploadId, progress: .completed(id: uploadId, totalBytes: totalBytes))
      return
    }

    let metadata = videoMetadata
    let task = Task<UploadResult, any Error>(priority: priority) {
      try await FileUploader.shared.performUpload(
        uploadId: uploadId,
        media: media,
        localUrl: localUrl,
        mimeType: mimeType,
        fileName: fileName,
        type: type,
        videoMetadata: metadata
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
    type: MessageFileType,
    videoMetadata: ApiClient.VideoUploadMetadata?
  ) async throws -> UploadResult {
    Log.shared.debug("[FileUploader] Starting upload for \(uploadId)")

    var uploadUrl = localUrl
    var uploadMimeType = mimeType
    var uploadFileName = fileName
    var resolvedVideoMetadata = videoMetadata
    var temporaryArtifacts: [URL] = []

    switch media {
    case .photo:
      publishProgress(uploadId: uploadId, progress: .processing(id: uploadId))
      do {
        let options = mimeType.lowercased().contains("png")
          ? ImageCompressionOptions.defaultPNG
          : ImageCompressionOptions.defaultPhoto
        uploadUrl = try await ImageCompressor.shared.compressImage(at: localUrl, options: options)
        if uploadUrl != localUrl {
          temporaryArtifacts.append(uploadUrl)
        }
      } catch {
        // Fallback to original URL if compression fails
        uploadUrl = localUrl
      }
    case .video:
      let prepared = try await prepareVideoForUpload(
        uploadId: uploadId,
        localUrl: localUrl,
        inputMimeType: mimeType,
        metadata: videoMetadata
      )
      uploadUrl = prepared.url
      uploadMimeType = prepared.mimeType
      uploadFileName = prepared.fileName
      resolvedVideoMetadata = prepared.metadata
      if prepared.cleanupAfterUpload {
        temporaryArtifacts.append(prepared.url)
      }
    case .document:
      break
    }

    defer {
      for url in temporaryArtifacts where FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.removeItem(at: url)
      }
    }

    try Task.checkCancellation()

    // get data from file
    let data = try Data(contentsOf: uploadUrl)
    let uploadSizeBytes = Int64(data.count)
    publishProgress(
      uploadId: uploadId,
      progress: .uploading(id: uploadId, bytesSent: 0, totalBytes: uploadSizeBytes)
    )

    // upload file with progress tracking
    let progressHandler = FileUploader.progressHandler(
      for: uploadId,
      logicalTotalBytes: uploadSizeBytes
    )

    let result = try await ApiClient.shared.uploadFile(
      type: type,
      data: data,
      filename: uploadFileName,
      mimeType: MIMEType(text: uploadMimeType),
      videoMetadata: resolvedVideoMetadata,
      progress: progressHandler
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
      publishProgress(uploadId: uploadId, progress: .completed(id: uploadId, totalBytes: uploadSizeBytes))
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
      publishProgress(uploadId: uploadId, progress: .failed(id: uploadId, error: FileUploadError.uploadCancelled))
      uploadTasks.removeValue(forKey: uploadId)
      cleanupTasks.removeValue(forKey: uploadId)
      progressHandlers.removeValue(forKey: uploadId)
    }
  }

  public func cancelVideoUpload(videoLocalId: Int64) {
    cancel(uploadId: getUploadId(videoId: videoLocalId))
  }

  public func cancelAll() {
    Log.shared.debug("[FileUploader] Cancelling all uploads")

    for (uploadId, taskInfo) in uploadTasks {
      taskInfo.task.cancel()
      publishProgress(uploadId: uploadId, progress: .failed(id: uploadId, error: FileUploadError.uploadCancelled))
    }

    uploadTasks.removeAll()
    cleanupTasks.removeAll()
    progressHandlers.removeAll()
  }

  // MARK: - Status Queries

  public func getUploadStatus(for uploadId: String) -> UploadStatus {
    if let latest = latestProgress[uploadId] {
      switch latest.stage {
      case .processing, .uploading:
        return .inProgress(latest)
      case .completed:
        return .completed
      case .failed:
        return .failed
      }
    }

    if finishedUploads[uploadId] != nil {
      return .completed
    }

    return .notFound
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
    "photo_\(photoId)"
  }

  private func getUploadId(videoId: Int64) -> String {
    "video_\(videoId)"
  }

  private func getUploadId(documentId: Int64) -> String {
    "document_\(documentId)"
  }

  private struct PreparedVideoUploadPayload {
    let url: URL
    let fileName: String
    let mimeType: String
    let metadata: ApiClient.VideoUploadMetadata
    let cleanupAfterUpload: Bool
  }

  private func prepareVideoForUpload(
    uploadId: String,
    localUrl: URL,
    inputMimeType: String,
    metadata: ApiClient.VideoUploadMetadata?
  ) async throws -> PreparedVideoUploadPayload {
    publishProgress(uploadId: uploadId, progress: .processing(id: uploadId))

    let resolvedMetadata = try await resolveVideoUploadMetadata(
      localUrl: localUrl,
      fallback: metadata
    )

    do {
      let result = try await VideoCompressor.shared.compressVideo(
        at: localUrl,
        options: VideoCompressionOptions.uploadDefault()
      )
      let compressedMetadata = ApiClient.VideoUploadMetadata(
        width: result.width,
        height: result.height,
        duration: result.duration,
        thumbnail: resolvedMetadata.thumbnail,
        thumbnailMimeType: resolvedMetadata.thumbnailMimeType
      )
      return PreparedVideoUploadPayload(
        url: result.url,
        fileName: "\(UUID().uuidString).mp4",
        mimeType: "video/mp4",
        metadata: compressedMetadata,
        cleanupAfterUpload: true
      )
    } catch is CancellationError {
      throw FileUploadError.uploadCancelled
    } catch VideoCompressionError.compressionNotNeeded {
      return PreparedVideoUploadPayload(
        url: localUrl,
        fileName: localUrl.lastPathComponent,
        mimeType: inputMimeType,
        metadata: resolvedMetadata,
        cleanupAfterUpload: false
      )
    } catch VideoCompressionError.compressionNotEffective {
      return PreparedVideoUploadPayload(
        url: localUrl,
        fileName: localUrl.lastPathComponent,
        mimeType: inputMimeType,
        metadata: resolvedMetadata,
        cleanupAfterUpload: false
      )
    } catch {
      Log.shared.warning(
        "[FileUploader] Video preprocessing failed for \(uploadId); uploading original (\(error.localizedDescription))"
      )
      return PreparedVideoUploadPayload(
        url: localUrl,
        fileName: localUrl.lastPathComponent,
        mimeType: inputMimeType,
        metadata: resolvedMetadata,
        cleanupAfterUpload: false
      )
    }
  }

  private func resolveVideoUploadMetadata(
    localUrl: URL,
    fallback: ApiClient.VideoUploadMetadata?
  ) async throws -> ApiClient.VideoUploadMetadata {
    if let fallback, fallback.width > 0, fallback.height > 0, fallback.duration > 0 {
      return fallback
    }

    let (width, height, duration) = try await readVideoMetadata(from: localUrl)
    return ApiClient.VideoUploadMetadata(
      width: width,
      height: height,
      duration: duration,
      thumbnail: fallback?.thumbnail,
      thumbnailMimeType: fallback?.thumbnailMimeType
    )
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
  nonisolated static func progressHandler(
    for uploadId: String,
    logicalTotalBytes: Int64
  ) -> @Sendable (ApiClient.UploadTransferProgress) -> Void {
    return { transferProgress in
      let snapshot = mapTransferProgress(
        uploadId: uploadId,
        transferProgress: transferProgress,
        logicalTotalBytes: logicalTotalBytes
      )
      Task {
        await FileUploader.shared.updateProgress(uploadId: uploadId, progress: snapshot)
      }
    }
  }

  nonisolated static func mapTransferProgress(
    uploadId: String,
    transferProgress: ApiClient.UploadTransferProgress,
    logicalTotalBytes: Int64
  ) -> UploadProgressSnapshot {
    let clampedTotal = max(logicalTotalBytes, 0)
    let clampedFraction = min(max(transferProgress.fractionCompleted, 0), 1)

    if clampedTotal > 0 {
      let bytesSent = Int64((Double(clampedTotal) * clampedFraction).rounded(.down))
      return .uploading(id: uploadId, bytesSent: bytesSent, totalBytes: clampedTotal)
    }

    let transferTotal = max(transferProgress.totalBytes, transferProgress.bytesSent)
    let clampedBytes = min(max(0, transferProgress.bytesSent), transferTotal)
    return .uploading(id: uploadId, bytesSent: clampedBytes, totalBytes: transferTotal)
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
      let fileMetadata = try await readVideoMetadata(from: localUrl)
      width = fileMetadata.0
      height = fileMetadata.1
      duration = fileMetadata.2
    }

    // Guard against missing metadata because the server requires them
    guard width > 0, height > 0, duration > 0 else {
      throw FileUploadError.invalidVideoMetadata
    }

    return (width, height, duration)
  }

  private func readVideoMetadata(from localUrl: URL) async throws -> (Int, Int, Int) {
    let asset = AVURLAsset(url: localUrl)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
      throw FileUploadError.invalidVideoMetadata
    }

    let naturalSize = try await track.load(.naturalSize)
    let transform = try await track.load(.preferredTransform)
    let transformedSize = naturalSize.applying(transform)
    let width = Int(abs(transformedSize.width.rounded()))
    let height = Int(abs(transformedSize.height.rounded()))

    let durationTime = try await asset.load(.duration)
    let seconds = CMTimeGetSeconds(durationTime)
    let duration = Int(seconds.rounded())

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
