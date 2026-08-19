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
  public var voiceId: Int64?
}

private struct UploadTaskInfo {
  let task: Task<UploadResult, any Error>
  let priority: TaskPriority
  let startTime: Date
  var progress: UploadProgressSnapshot
}

struct BoundedTerminalStateKeys: Sendable {
  private let limit: Int
  private(set) var keys: [String] = []

  init(limit: Int) {
    self.limit = max(0, limit)
  }

  mutating func record(_ key: String) -> [String] {
    keys.removeAll { $0 == key }
    keys.append(key)

    let overflow = max(0, keys.count - limit)
    guard overflow > 0 else { return [] }
    let evicted = Array(keys.prefix(overflow))
    keys.removeFirst(overflow)
    return evicted
  }

  mutating func remove(_ key: String) {
    keys.removeAll { $0 == key }
  }

  mutating func removeAll() {
    keys.removeAll(keepingCapacity: true)
  }
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

public enum DocumentPendingUploadDisplayState: Equatable, Sendable {
  case inactive
  case processing
  case uploading(bytesSent: Int64, totalBytes: Int64)

  public static func resolve(
    isPendingMessage: Bool,
    localDocumentId: Int64?,
    progress: UploadProgressSnapshot?
  ) -> DocumentPendingUploadDisplayState {
    guard isPendingMessage, localDocumentId != nil else {
      return .inactive
    }

    guard let progress else {
      return .processing
    }

    switch progress.stage {
    case .processing:
      return .processing
    case .uploading, .completed:
      let totalBytes = max(progress.totalBytes, progress.bytesSent)
      return .uploading(bytesSent: progress.bytesSent, totalBytes: totalBytes)
    case .failed:
      // A failed attempt does not make a pending outgoing attachment complete.
      // The transaction owner may retry it, and the user must retain a visible
      // pending/cancel state until that transaction itself becomes terminal.
      return .processing
    }
  }
}

public actor FileUploader {
  public static let shared = FileUploader()
  static let terminalStateRetentionLimit = 256
  static let inactivePublisherRetentionLimit = 256

  // Replace simple dictionaries with more structured storage
  private var uploadTasks: [String: UploadTaskInfo] = [:]
  private var finishedUploads: [String: UploadResult] = [:]
  private var progressHandlers: [String: @Sendable (UploadProgressSnapshot) -> Void] = [:]
  private var progressPublishers: [String: CurrentValueSubject<UploadProgressSnapshot, Never>] = [:]
  private var latestProgress: [String: UploadProgressSnapshot] = [:]
  private var cleanupTasks: [String: Task<Void, Never>] = [:]
  private var terminalStateKeys = BoundedTerminalStateKeys(limit: terminalStateRetentionLimit)
  private var inactivePublisherKeys = BoundedTerminalStateKeys(limit: inactivePublisherRetentionLimit)
  private var activeUploadTokens: [String: UUID] = [:]
  private var uploadResetTask: Task<Void, Never>?
  private var uploadSessionGeneration: UInt64 = 0

  private init() {}

  // MARK: - Task Management

  private func registerTask(
    uploadId: String,
    token: UUID,
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
        await self?.handleTaskCompletion(uploadId: uploadId, token: token)
      } catch {
        await self?.handleTaskFailure(uploadId: uploadId, token: token, error: error)
      }
    }
  }

  private func handleTaskCompletion(uploadId: String, token: UUID) {
    guard activeUploadTokens[uploadId] == token else { return }
    Log.shared.debug("[FileUploader] Upload task completed for \(uploadId)")
    if let latest = latestProgress[uploadId], latest.stage != .completed {
      let totalBytes = max(latest.totalBytes, latest.bytesSent)
      publishProgress(uploadId: uploadId, progress: .completed(id: uploadId, totalBytes: totalBytes))
    }
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
    activeUploadTokens.removeValue(forKey: uploadId)
  }

  private func handleTaskFailure(uploadId: String, token: UUID, error: Error) {
    guard activeUploadTokens[uploadId] == token else { return }
    if Self.isCancellation(error) {
      releaseCancelledUploadState(uploadId: uploadId)
      return
    }

    Log.shared.error(
      "[FileUploader] Upload task failed for \(uploadId)",
      error: error
    )
    publishProgress(uploadId: uploadId, progress: .failed(id: uploadId, error: error))
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
    activeUploadTokens.removeValue(forKey: uploadId)
  }

  // MARK: - Progress Tracking

  private func updateProgress(uploadId: String, token: UUID, progress: UploadProgressSnapshot) {
    guard uploadTasks[uploadId] != nil, activeUploadTokens[uploadId] == token else { return }
    publishProgress(uploadId: uploadId, progress: progress)
  }

  private func publishProgress(uploadId: String, progress: UploadProgressSnapshot) {
    inactivePublisherKeys.remove(uploadId)
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

    if progress.stage == .completed || progress.stage == .failed {
      finishProgressPublisher(uploadId: uploadId)
      let evicted = terminalStateKeys.record(uploadId)
      for evictedID in evicted {
        latestProgress.removeValue(forKey: evictedID)
        finishedUploads.removeValue(forKey: evictedID)
        finishProgressPublisher(uploadId: evictedID)
      }
    }
  }

  private func progressPublisher(for uploadId: String) -> AnyPublisher<UploadProgressSnapshot, Never> {
    if uploadResetTask != nil {
      return Just(.failed(id: uploadId, error: FileUploadError.uploadCancelled)).eraseToAnyPublisher()
    }

    if let latest = latestProgress[uploadId], latest.stage == .completed || latest.stage == .failed {
      return Just(latest).eraseToAnyPublisher()
    }

    let publisher: CurrentValueSubject<UploadProgressSnapshot, Never>
    if let existing = progressPublishers[uploadId] {
      publisher = existing
      if uploadTasks[uploadId] == nil {
        retainInactivePublisher(uploadId: uploadId)
      }
    } else {
      let initialProgress = latestProgress[uploadId] ?? .processing(id: uploadId)
      publisher = CurrentValueSubject<UploadProgressSnapshot, Never>(initialProgress)
      progressPublishers[uploadId] = publisher
      retainInactivePublisher(uploadId: uploadId)
    }

    return publisher.eraseToAnyPublisher()
  }

  private func retainInactivePublisher(uploadId: String) {
    let evicted = inactivePublisherKeys.record(uploadId)
    for evictedID in evicted {
      guard uploadTasks[evictedID] == nil else { continue }
      finishProgressPublisher(uploadId: evictedID)
    }
  }

  private func finishProgressPublisher(uploadId: String) {
    let publisher = progressPublishers.removeValue(forKey: uploadId)
    inactivePublisherKeys.remove(uploadId)
    publisher?.send(completion: .finished)
  }

  private func currentProgress(for uploadId: String) -> UploadProgressSnapshot? {
    latestProgress[uploadId] ?? uploadTasks[uploadId]?.progress ?? progressPublishers[uploadId]?.value
  }

  public func videoProgressPublisher(videoLocalId: Int64) -> AnyPublisher<UploadProgressSnapshot, Never> {
    progressPublisher(for: getUploadId(videoId: videoLocalId))
  }

  public func currentVideoProgress(videoLocalId: Int64) -> UploadProgressSnapshot? {
    currentProgress(for: getUploadId(videoId: videoLocalId))
  }

  public func documentProgressPublisher(documentLocalId: Int64) -> AnyPublisher<UploadProgressSnapshot, Never> {
    progressPublisher(for: getUploadId(documentId: documentLocalId))
  }

  public func currentDocumentProgress(documentLocalId: Int64) -> UploadProgressSnapshot? {
    currentProgress(for: getUploadId(documentId: documentLocalId))
  }

  public func photoProgressPublisher(photoLocalId: Int64) -> AnyPublisher<UploadProgressSnapshot, Never> {
    progressPublisher(for: getUploadId(photoId: photoLocalId))
  }

  public func voiceProgressPublisher(voiceLocalId: Int64) -> AnyPublisher<UploadProgressSnapshot, Never> {
    progressPublisher(for: getUploadId(voiceId: voiceLocalId))
  }

  public func setUploadProgressHandler(
    for uploadId: String,
    handler: @escaping @Sendable (UploadProgressSnapshot) -> Void
  ) {
    guard uploadResetTask == nil else { return }
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

  public func clearUploadProgressHandler(for uploadId: String) {
    progressHandlers.removeValue(forKey: uploadId)
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

  public func clearProgressHandler(for uploadId: String) {
    clearUploadProgressHandler(for: uploadId)
  }

  // MARK: - Upload Methods

  public func uploadPhoto(
    photoInfo: PhotoInfo
  ) throws -> Int64 {
    guard uploadResetTask == nil else { throw FileUploadError.uploadCancelled }
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
    guard uploadResetTask == nil else { throw FileUploadError.uploadCancelled }
    let startingSessionGeneration = uploadSessionGeneration

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
    guard uploadResetTask == nil, uploadSessionGeneration == startingSessionGeneration else {
      throw FileUploadError.uploadCancelled
    }

    let uploadId = getUploadId(videoId: localVideoId)
    publishProgress(uploadId: uploadId, progress: .processing(id: uploadId))

    let thumbnailPayload = try? thumbnailData(from: resolvedVideoInfo.thumbnail)
    let videoMetadata = ApiClient.VideoUploadMetadata(
      width: width,
      height: height,
      duration: duration,
      thumbnail: thumbnailPayload?.0,
      thumbnailMimeType: thumbnailPayload?.1,
      isAnimated: resolvedVideoInfo.video.isAnimated,
      hasAudio: resolvedVideoInfo.video.hasAudio
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
    guard uploadResetTask == nil else { throw FileUploadError.uploadCancelled }
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

  public func uploadVoice(
    voiceContent: Client_MessageVoiceContent
  ) async throws -> Int64 {
    guard uploadResetTask == nil else { throw FileUploadError.uploadCancelled }
    let localVoiceId = voiceContent.voiceID
    guard localVoiceId != 0 else {
      throw FileUploadError.invalidVoiceId
    }

    guard let localPath = voiceContent.localRelativePath.nilIfEmpty else {
      throw FileUploadError.invalidVoice
    }

    let localURL = FileHelpers.getLocalCacheDirectory(for: .voices).appendingPathComponent(localPath)
    let fileName = localURL.lastPathComponent
    guard let mimeType = voiceContent.mimeType.nilIfEmpty else {
      throw FileUploadError.invalidVoice
    }

    let metadata = ApiClient.VoiceUploadMetadata(
      duration: Int(voiceContent.duration),
      waveform: voiceContent.waveform
    )

    let uploadId = getUploadId(voiceId: localVoiceId)
    publishProgress(uploadId: uploadId, progress: .processing(id: uploadId))

    try startUpload(
      media: .voice(voiceContent),
      localUrl: localURL,
      mimeType: mimeType,
      fileName: fileName,
      voiceMetadata: metadata
    )

    return localVoiceId
  }

  public func startUpload(
    media: FileMediaItem,
    localUrl: URL,
    mimeType: String,
    fileName: String,
    priority: TaskPriority = .userInitiated,
    videoMetadata: ApiClient.VideoUploadMetadata? = nil,
    voiceMetadata: ApiClient.VoiceUploadMetadata? = nil
  ) throws {
    guard uploadResetTask == nil else { throw FileUploadError.uploadCancelled }

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
      case let .voice(voiceContent):
        uploadId = getUploadId(voiceId: voiceContent.voiceID)
        type = .voice
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

    prepareForActiveUpload(uploadId: uploadId)

    let metadata = videoMetadata
    let resolvedVoiceMetadata = voiceMetadata
    let token = UUID()
    activeUploadTokens[uploadId] = token
    let task = Task<UploadResult, any Error>(priority: priority) {
      try await FileUploader.shared.performUpload(
        uploadId: uploadId,
        token: token,
        media: media,
        localUrl: localUrl,
        mimeType: mimeType,
        fileName: fileName,
        type: type,
        videoMetadata: metadata,
        voiceMetadata: resolvedVoiceMetadata
      )
    }

    // Register the task
    registerTask(uploadId: uploadId, token: token, task: task, priority: priority)
  }

  private func performUpload(
    uploadId: String,
    token: UUID,
    media: FileMediaItem,
    localUrl: URL,
    mimeType: String,
    fileName: String,
    type: MessageFileType,
    videoMetadata: ApiClient.VideoUploadMetadata?,
    voiceMetadata: ApiClient.VoiceUploadMetadata?
  ) async throws -> UploadResult {
    try ensureActiveUpload(uploadId: uploadId, token: token)
    Log.shared.debug("[FileUploader] Starting upload for \(uploadId)")

    var uploadUrl = localUrl
    var uploadMimeType = mimeType
    var uploadFileName = fileName
    var resolvedVideoMetadata = videoMetadata
    var resolvedThumbnailMetadata: ApiClient.ThumbnailUploadMetadata?
    var resolvedVoiceMetadata = voiceMetadata
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
    case let .document(documentInfo):
      resolvedThumbnailMetadata = Self.thumbnailUploadMetadata(from: documentInfo.thumbnail)
    case let .voice(voiceContent):
      resolvedVoiceMetadata = ApiClient.VoiceUploadMetadata(
        duration: Int(voiceContent.duration),
        waveform: voiceContent.waveform
      )
    }

    defer {
      for url in temporaryArtifacts where FileManager.default.fileExists(atPath: url.path) {
        try? FileManager.default.removeItem(at: url)
      }
    }

    try Task.checkCancellation()
    try ensureActiveUpload(uploadId: uploadId, token: token)

    let uploadSizeBytes = Int64(FileHelpers.getFileSize(at: uploadUrl))
    publishProgress(
      uploadId: uploadId,
      progress: .uploading(id: uploadId, bytesSent: 0, totalBytes: uploadSizeBytes)
    )

    // upload file with progress tracking
    let progressHandler = FileUploader.progressHandler(
      for: uploadId,
      token: token,
      logicalTotalBytes: uploadSizeBytes
    )

    var thumbnailFileUniqueID: String?
    let thumbnailData = resolvedThumbnailMetadata?.data ?? resolvedVideoMetadata?.thumbnail
    let thumbnailMimeType = resolvedThumbnailMetadata?.mimeType.text ??
      resolvedVideoMetadata?.thumbnailMimeType?.text ?? "image/jpeg"
    if let thumbnailData {
      let thumbnailURL = FileHelpers.getTrueTemporaryDirectory()
        .appendingPathComponent("inline-upload-thumbnail-\(UUID().uuidString)")
      try thumbnailData.write(to: thumbnailURL, options: .atomic)
      temporaryArtifacts.append(thumbnailURL)
      let thumbnail = try await DurableUploadCoordinator.shared.upload(
        NativeMediaUploadRequest(
          logicalID: "\(uploadId):thumbnail",
          fileURL: thumbnailURL,
          fileName: "thumbnail.jpg",
          mimeType: thumbnailMimeType,
          kind: .photo
        ),
        progress: { _, _ in }
      )
      thumbnailFileUniqueID = thumbnail.fileUniqueID
    }

    let kind: InlineProtocol.UploadKind
    let nativeMetadata: CreateUploadInput.OneOf_Metadata?
    switch type {
    case .photo:
      kind = .photo
      nativeMetadata = nil
    case .document:
      kind = .document
      nativeMetadata = nil
    case .video:
      guard let metadata = resolvedVideoMetadata else {
        throw FileUploadError.invalidVideoMetadata
      }
      var video = UploadVideoMetadata()
      video.width = UInt32(metadata.width)
      video.height = UInt32(metadata.height)
      video.duration = UInt32(metadata.duration)
      video.isAnimated = metadata.isAnimated
      if let hasAudio = metadata.hasAudio { video.hasAudio_p = hasAudio }
      kind = .video
      nativeMetadata = .video(video)
    case .voice:
      guard let metadata = resolvedVoiceMetadata else { throw FileUploadError.invalidVoice }
      var voice = UploadVoiceMetadata()
      voice.duration = UInt32(max(0, metadata.duration))
      voice.waveform = metadata.waveform
      kind = .voice
      nativeMetadata = .voice(voice)
    }

    let transferTask = Task.detached(priority: .userInitiated) {
      try await DurableUploadCoordinator.shared.upload(
        NativeMediaUploadRequest(
          logicalID: uploadId,
          fileURL: uploadUrl,
          fileName: uploadFileName,
          mimeType: uploadMimeType,
          kind: kind,
          thumbnailFileUniqueID: thumbnailFileUniqueID,
          metadata: nativeMetadata
        ),
        progress: { sent, total in
          progressHandler(
            ApiClient.UploadTransferProgress(
              bytesSent: sent,
              totalBytes: total,
              fractionCompleted: total > 0 ? Double(sent) / Double(total) : 0
            )
          )
        }
      )
    }
    let complete = try await withTaskCancellationHandler {
      try await transferTask.value
    } onCancel: {
      transferTask.cancel()
    }
    try Task.checkCancellation()
    try ensureActiveUpload(uploadId: uploadId, token: token)

    let result: UploadFileResult
    switch complete.media {
    case let .photo(photo):
      result = UploadFileResult(
        fileUniqueId: complete.fileUniqueID,
        photoId: photo.id,
        videoId: nil,
        documentId: nil,
        voiceId: nil
      )
    case let .video(video):
      result = UploadFileResult(
        fileUniqueId: complete.fileUniqueID,
        photoId: nil,
        videoId: video.id,
        documentId: nil,
        voiceId: nil
      )
    case let .document(document):
      result = UploadFileResult(
        fileUniqueId: complete.fileUniqueID,
        photoId: nil,
        videoId: nil,
        documentId: document.id,
        voiceId: nil
      )
    case let .voice(voice):
      result = UploadFileResult(
        fileUniqueId: complete.fileUniqueID,
        photoId: nil,
        videoId: nil,
        documentId: nil,
        voiceId: voice.id
      )
    case nil:
      throw NativeMediaUploadError.unexpectedResponse
    }

    // TODO: Set compressed file in db if it was created

    // return IDs
    let result_ = UploadResult(
      photoId: result.photoId,
      videoId: result.videoId,
      documentId: result.documentId,
      voiceId: result.voiceId
    )

    // Update database with new ID
    do {
      try await updateDatabaseWithServerIds(media: media, result: result)
      try Task.checkCancellation()
      try ensureActiveUpload(uploadId: uploadId, token: token)
      Log.shared.debug("[FileUploader] Successfully updated database for \(uploadId)")

      // Store result after successful database update
      storeUploadResult(uploadId: uploadId, result: result_)
      publishProgress(uploadId: uploadId, progress: .completed(id: uploadId, totalBytes: uploadSizeBytes))
    } catch {
      if Self.isCancellation(error) {
        throw error
      }
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

  private func prepareForActiveUpload(uploadId: String) {
    terminalStateKeys.remove(uploadId)
    inactivePublisherKeys.remove(uploadId)
    latestProgress.removeValue(forKey: uploadId)
  }

  private func releaseCancelledUploadState(uploadId: String) {
    activeUploadTokens.removeValue(forKey: uploadId)
    uploadTasks.removeValue(forKey: uploadId)
    cleanupTasks.removeValue(forKey: uploadId)
    progressHandlers.removeValue(forKey: uploadId)
    finishedUploads.removeValue(forKey: uploadId)
    latestProgress.removeValue(forKey: uploadId)
    finishProgressPublisher(uploadId: uploadId)
    terminalStateKeys.remove(uploadId)
    inactivePublisherKeys.remove(uploadId)
  }

  private func ensureActiveUpload(uploadId: String, token: UUID) throws {
    guard activeUploadTokens[uploadId] == token else {
      throw CancellationError()
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let uploadError = error as? FileUploadError, case .uploadCancelled = uploadError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  // MARK: - Task Control

  public func cancel(uploadId: String) {
    Log.shared.debug("[FileUploader] Cancelling upload for \(uploadId)")

    if finishedUploads[uploadId] != nil || latestProgress[uploadId]?.stage == .completed {
      return
    }

    if let taskInfo = uploadTasks[uploadId] {
      taskInfo.task.cancel()
      releaseCancelledUploadState(uploadId: uploadId)
    }
  }

  public func cancelVideoUpload(videoLocalId: Int64) {
    cancel(uploadId: getUploadId(videoId: videoLocalId))
  }

  public func cancelDocumentUpload(documentLocalId: Int64) {
    cancel(uploadId: getUploadId(documentId: documentLocalId))
  }

  public func cancelVoiceUpload(voiceLocalId: Int64) {
    cancel(uploadId: getUploadId(voiceId: voiceLocalId))
  }

  public func cancelAll() async {
    if let uploadResetTask {
      await uploadResetTask.value
      return
    }
    uploadSessionGeneration &+= 1

    Log.shared.debug("[FileUploader] Cancelling all uploads")

    let tasks = uploadTasks.values.map(\.task)
    let cleanupMonitors = Array(cleanupTasks.values)
    for (uploadId, taskInfo) in uploadTasks {
      taskInfo.task.cancel()
      finishProgressPublisher(uploadId: uploadId)
    }

    activeUploadTokens.removeAll()
    uploadTasks.removeAll()
    cleanupTasks.removeAll()
    progressHandlers.removeAll()
    finishedUploads.removeAll()
    latestProgress.removeAll()
    for uploadId in Array(progressPublishers.keys) {
      finishProgressPublisher(uploadId: uploadId)
    }
    progressPublishers.removeAll()
    terminalStateKeys.removeAll()
    inactivePublisherKeys.removeAll()

    let reset = Task {
      for task in tasks {
        _ = try? await task.value
      }
      for monitor in cleanupMonitors {
        await monitor.value
      }
    }
    uploadResetTask = reset
    await reset.value
    uploadResetTask = nil
  }

  func retainedProgressPublisherCount() -> Int {
    progressPublishers.count
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
        if let serverThumbId = result.photoId, let localThumb = documentInfo.thumbnail?.photo {
          try await AppDatabase.shared.dbWriter.write { db in
            try AppDatabase.updatePhotoWithServerId(db, localPhoto: localThumb, serverId: serverThumbId)
          }
        }
      case .voice:
        break
    }
  }

  // MARK: - Helpers

  private static func thumbnailUploadMetadata(from thumbnail: PhotoInfo?) -> ApiClient.ThumbnailUploadMetadata? {
    guard let thumbnail,
          let size = thumbnail.bestPhotoSize(),
          let localPath = size.localPath
    else {
      return nil
    }

    let url = FileCache.getUrl(for: .photos, localPath: localPath)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let mimeType = thumbnail.photo.format == .png ? "image/png" : "image/jpeg"
    return ApiClient.ThumbnailUploadMetadata(data: data, mimeType: MIMEType(text: mimeType))
  }

  private func getUploadId(photoId: Int64) -> String {
    "photo_\(photoId)"
  }

  private func getUploadId(videoId: Int64) -> String {
    "video_\(videoId)"
  }

  private func getUploadId(documentId: Int64) -> String {
    "document_\(documentId)"
  }

  private func getUploadId(voiceId: Int64) -> String {
    "voice_\(voiceId)"
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
    let requiresMp4Output = inputMimeType.lowercased() != "video/mp4"

    let resolvedMetadata = try await resolveVideoUploadMetadata(
      localUrl: localUrl,
      fallback: metadata
    )

    do {
      let result = try await VideoCompressor.shared.compressVideo(
        at: localUrl,
        options: VideoCompressionOptions.uploadDefault(forceTranscode: requiresMp4Output)
      )
      let compressedMetadata = ApiClient.VideoUploadMetadata(
        width: result.width,
        height: result.height,
        duration: result.duration,
        thumbnail: resolvedMetadata.thumbnail,
        thumbnailMimeType: resolvedMetadata.thumbnailMimeType,
        isAnimated: resolvedMetadata.isAnimated,
        hasAudio: resolvedMetadata.hasAudio
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
      thumbnailMimeType: fallback?.thumbnailMimeType,
      isAnimated: fallback?.isAnimated ?? false,
      hasAudio: fallback?.hasAudio
    )
  }

  func resolveLocalVideoId(
    for video: Video,
    database: AppDatabase? = nil
  ) throws -> Int64 {
    if let id = video.id { return id }

    let database = database ?? AppDatabase.shared

    // Try to fetch the video row by temporary/server videoId
    let fetched: Video? = try database.dbWriter.read { db in
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
    token: UUID,
    logicalTotalBytes: Int64
  ) -> @Sendable (ApiClient.UploadTransferProgress) -> Void {
    return { transferProgress in
      let snapshot = mapTransferProgress(
        uploadId: uploadId,
        transferProgress: transferProgress,
        logicalTotalBytes: logicalTotalBytes
      )
      Task {
        await FileUploader.shared.updateProgress(uploadId: uploadId, token: token, progress: snapshot)
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

  public func waitForUpload(voiceLocalId id: Int64) async throws -> UploadResult? {
    try await waitForUpload(uploadId: getUploadId(voiceId: id))
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

public enum FileUploadError: Error, LocalizedError {
  case failedToUpload
  case failedToSave
  case invalidPhoto
  case invalidVideo
  case invalidDocument
  case invalidVoice
  case invalidPhotoId
  case invalidDocumentId
  case invalidVideoId
  case invalidVoiceId
  case invalidVideoMetadata
  case uploadAlreadyInProgress
  case uploadAlreadyCompleted
  case uploadCancelled
  case uploadTimeout

  public var errorDescription: String? {
    switch self {
      case .failedToUpload:
        "Couldn't upload the file."
      case .failedToSave:
        "The uploaded file couldn't be saved locally."
      case .invalidPhoto:
        "The selected photo couldn't be prepared for upload."
      case .invalidVideo:
        "The selected video couldn't be prepared for upload."
      case .invalidDocument:
        "The selected file couldn't be prepared for upload."
      case .invalidVoice:
        "The selected voice message couldn't be prepared for upload."
      case .invalidPhotoId, .invalidDocumentId, .invalidVideoId, .invalidVoiceId:
        "The local file reference is invalid."
      case .invalidVideoMetadata:
        "The video metadata is invalid."
      case .uploadAlreadyInProgress:
        "This upload is already in progress."
      case .uploadAlreadyCompleted:
        "This upload already finished."
      case .uploadCancelled:
        "The upload was cancelled."
      case .uploadTimeout:
        "The upload timed out."
    }
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
