import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit

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
  }

  private func handleTaskFailure(uploadId: String, error: Error) {
    Log.shared.error(
      "[FileUploader] Upload task failed for \(uploadId)",
      error: error
    )
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
  }

  // MARK: - Progress Tracking

  private func updateProgress(uploadId: String, progress: Double) {
    if var taskInfo = uploadTasks[uploadId] {
      taskInfo.progress = progress
      uploadTasks[uploadId] = taskInfo
      // Create a local copy of the handler to avoid actor isolation issues
      if let handler = progressHandlers[uploadId] {
        Task { @MainActor in
          await MainActor.run {
            handler(progress)
          }
        }
      }
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
    let format = photoInfo.photo.format ?? .jpeg
    let size = FileHelpers.getFileSize(at: localUrl)
    let ext = format.toExt()
    let fileName = localPath.components(separatedBy: "/").last ?? "" + ext
    let mimeType = format.toMimeType()

    let uploadId = getUploadId(photoId: photoInfo.photo.id!)

    // Update status to processing
    if let handler = progressHandlers[uploadId] {
      Task { @MainActor in
        await MainActor.run {
          handler(-1) // Special value to indicate processing
        }
      }
    }

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
    // todo
    0
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
    priority: TaskPriority = .userInitiated
  ) throws {
    let type: MessageFileType
    let uploadId: String

    switch media {
      case let .photo(photoInfo):
        uploadId = getUploadId(photoId: photoInfo.photo.id!)
        type = .photo
      case let .video(videoInfo):
        uploadId = getUploadId(videoId: videoInfo.video.id!)
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
      throw FileUploadError.uploadAlreadyCompleted
    }

    let task = Task<UploadResult, any Error>(priority: priority) { [weak self] in
      guard let self else { throw FileUploadError.uploadCancelled }

      Log.shared.debug("[FileUploader] Starting upload for \(uploadId)")

      // Compress image if it's a photo
      let uploadUrl: URL
      if case .photo = media {
        do {
          let options = mimeType.lowercased().contains("png") ?
            ImageCompressionOptions.defaultPNG :
            ImageCompressionOptions.defaultPhoto
          uploadUrl = try await ImageCompressor.shared.compressImage(at: localUrl, options: options)

        } catch {
          // Fallback to original URL if compression fails
          uploadUrl = localUrl
        }
      } else {
        uploadUrl = localUrl
      }

      // get data from file
      let data = try Data(contentsOf: uploadUrl)

      // upload file with progress tracking
      let result = try await ApiClient.shared.uploadFile(
        type: type,
        data: data,
        filename: fileName,
        mimeType: MIMEType(text: mimeType)
      ) { [weak self] progress in
        Task { [weak self] in
          await self?.updateProgress(uploadId: uploadId, progress: progress)
        }
      }

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
        await storeUploadResult(uploadId: uploadId, result: result_)
      } catch {
        Log.shared.error(
          "[FileUploader] Failed to update database with new server ID for \(uploadId)",
          error: error
        )
        throw FileUploadError.failedToSave
      }

      return result_
    }

    // Register the task
    registerTask(uploadId: uploadId, task: task, priority: priority)
  }

  private func storeUploadResult(uploadId: String, result: UploadResult) {
    finishedUploads[uploadId] = result
  }

  // MARK: - Task Control

  public func cancel(uploadId: String) {
    Log.shared.debug("[FileUploader] Cancelling upload for \(uploadId)")

    if let taskInfo = uploadTasks[uploadId] {
      taskInfo.task.cancel()
      uploadTasks.removeValue(forKey: uploadId)
      cleanupTasks.removeValue(forKey: uploadId)
      progressHandlers.removeValue(forKey: uploadId)
    }
  }

  public func cancelAll() {
    Log.shared.debug("[FileUploader] Cancelling all uploads")

    for (uploadId, taskInfo) in uploadTasks {
      taskInfo.task.cancel()
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
  case uploadAlreadyInProgress
  case uploadAlreadyCompleted
  case uploadCancelled
  case uploadTimeout
}
