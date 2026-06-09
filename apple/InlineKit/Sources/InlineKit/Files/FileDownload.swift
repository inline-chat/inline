import Combine
import Foundation
import Logger
import Nuke

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Download Progress Model

public struct DownloadProgress: Equatable {
  public let id: String
  public let bytesReceived: Int64
  public let totalBytes: Int64
  public let progress: Double
  public let isComplete: Bool
  public let error: Error?

  public init(id: String, bytesReceived: Int64, totalBytes: Int64, error: Error? = nil) {
    self.init(
      id: id,
      bytesReceived: bytesReceived,
      totalBytes: totalBytes,
      isComplete: nil,
      error: error
    )
  }

  private init(
    id: String,
    bytesReceived: Int64,
    totalBytes: Int64,
    isComplete: Bool?,
    error: Error? = nil
  ) {
    let clampedTotalBytes = max(0, totalBytes)
    let clampedBytesReceived = if clampedTotalBytes > 0 {
      min(max(0, bytesReceived), clampedTotalBytes)
    } else {
      max(0, bytesReceived)
    }

    self.id = id
    self.bytesReceived = clampedBytesReceived
    self.totalBytes = clampedTotalBytes
    self.error = error
    self.isComplete = error == nil && (isComplete ?? (
      clampedTotalBytes > 0 && clampedBytesReceived >= clampedTotalBytes
    ))
    progress = if self.isComplete {
      1
    } else if clampedTotalBytes > 0 {
      Double(clampedBytesReceived) / Double(clampedTotalBytes)
    } else {
      0
    }
  }

  public static func completed(id: String, totalBytes: Int64) -> DownloadProgress {
    let clampedTotalBytes = max(0, totalBytes)
    return DownloadProgress(
      id: id,
      bytesReceived: clampedTotalBytes,
      totalBytes: clampedTotalBytes,
      isComplete: true
    )
  }

  public static func failed(id: String, error: Error) -> DownloadProgress {
    DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0, error: error)
  }

  // Implement Equatable manually since Error doesn't conform to Equatable
  public static func == (lhs: DownloadProgress, rhs: DownloadProgress) -> Bool {
    lhs.id == rhs.id &&
      lhs.bytesReceived == rhs.bytesReceived &&
      lhs.totalBytes == rhs.totalBytes &&
      lhs.isComplete == rhs.isComplete &&
      (lhs.error == nil) == (rhs.error == nil)
  }
}

// MARK: - File Downloader

@MainActor
public final class FileDownloader: NSObject, Sendable {
  public static let shared = FileDownloader()

  private var progressPublishers: [String: CurrentValueSubject<DownloadProgress, Never>] = [:]
  private var latestProgress: [String: DownloadProgress] = [:]
  private var activeTasks: [String: URLSessionDownloadTask] = [:]
  private var session: URLSession!
  private let log = Log.scoped("FileDownloader")

  override private init() {
    super.init()
    let config = URLSessionConfiguration.default
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  // MARK: - Public API

  /// Get a publisher for tracking download progress of a document
  public func documentProgressPublisher(documentId: Int64) -> AnyPublisher<DownloadProgress, Never> {
    progressPublisher(for: "doc_\(documentId)")
  }

  public func currentDocumentProgress(documentId: Int64) -> DownloadProgress? {
    currentProgress(for: "doc_\(documentId)")
  }

  /// Get a publisher for tracking download progress of a video
  public func videoProgressPublisher(videoId: Int64) -> AnyPublisher<DownloadProgress, Never> {
    progressPublisher(for: "video_\(videoId)")
  }

  public func currentVideoProgress(videoId: Int64) -> DownloadProgress? {
    currentProgress(for: "video_\(videoId)")
  }

  /// Get a publisher for tracking download progress of a photo
  public func photoProgressPublisher(photoId: Int64) -> AnyPublisher<DownloadProgress, Never> {
    progressPublisher(for: "photo_\(photoId)")
  }

  /// Get a publisher for tracking download progress of a voice message.
  public func voiceProgressPublisher(voiceId: Int64) -> AnyPublisher<DownloadProgress, Never> {
    progressPublisher(for: "voice_\(voiceId)")
  }

  public func downloadDocument(
    document: DocumentInfo,
    for message: Message? = nil,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    Log.shared.debug("Downloading document \(document)")
    guard let urlString = document.document.cdnUrl, let url = URL(string: urlString) else {
      let error = NSError(
        domain: "FileDownloader",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "No remote URL found"]
      )
      log.warning("No remote URL found for document \(document.id)")
      completion(.failure(error))
      return
    }

    let downloadId = "doc_\(document.id)"
    let localPath = "\(UUID().uuidString)_\(document.document.fileName ?? "Unknown")"
    let localUrl = FileCache.getUrl(for: .documents, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: Int64(document.document.size ?? 0),
      completion: { [weak self] result in
        guard let self else { return }

        switch result {
          case let .success(fileUrl):
            // Notify FileCache to update database
            Task {
              do {
                try await FileCache.shared.saveDocumentDownload(
                  document: document,
                  localPath: localPath,
                  message: message
                )
                completion(.success(fileUrl))
              } catch {
                self.log.error("Error saving document download: \(error)")
                self.failDownload(id: downloadId, error: error)
                completion(.failure(error))
              }
            }

          case let .failure(error):
            log.error("Document download failed: \(error)")
            completion(.failure(error))
        }
      }
    )
  }

  /// Download a video file
  public func downloadVideo(
    video: VideoInfo,
    for message: Message,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard let urlString = video.video.cdnUrl, let url = URL(string: urlString) else {
      let error = NSError(
        domain: "FileDownloader",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "No remote URL found"]
      )
      log.warning("No remote URL found for video \(video.id)")
      completion(.failure(error))
      return
    }

    let downloadId = "video_\(video.id)"
    let fileExtension = "mp4"
    let localPath = "\(UUID().uuidString).\(fileExtension)"
    let localUrl = FileCache.getUrl(for: .videos, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: Int64(video.video.size ?? 0),
      completion: { [weak self] result in
        guard let self else { return }

        switch result {
          case let .success(fileUrl):
            // Notify FileCache to update database
            Task {
              do {
                try await FileCache.shared.saveVideoDownload(video: video, localPath: localPath, message: message)
                completion(.success(fileUrl))
              } catch {
                self.log.error("Error saving video download: \(error)")
                self.failDownload(id: downloadId, error: error)
                completion(.failure(error))
              }
            }

          case let .failure(error):
            log.error("Video download failed: \(error)")
            completion(.failure(error))
        }
      }
    )
  }

  public func downloadVoice(
    message: Message,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    guard let voice = message.voiceContent else {
      completion(.failure(FileCacheError.failedToSave))
      return
    }

    guard let url = URL(string: voice.cdnURL) else {
      let error = NSError(
        domain: "FileDownloader",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "No remote URL found"]
      )
      log.warning("No remote URL found for voice \(voice.voiceID)")
      completion(.failure(error))
      return
    }

    let downloadId = "voice_\(voice.voiceID)"
    let fileExtension = Self.voiceFileExtension(mimeType: voice.mimeType)
    let localPath = "\(UUID().uuidString).\(fileExtension)"
    let localUrl = FileCache.getUrl(for: .voices, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: voice.size,
      completion: { [weak self] result in
        guard let self else { return }

        switch result {
        case let .success(fileURL):
          Task {
            do {
              try await FileCache.shared.saveVoiceDownload(message: message, localPath: localPath)
              completion(.success(fileURL))
            } catch {
              self.log.error("Error saving voice download: \(error)")
              self.failDownload(id: downloadId, error: error)
              completion(.failure(error))
            }
          }

        case let .failure(error):
          self.log.error("Voice download failed: \(error)")
          completion(.failure(error))
        }
      }
    )
  }

  /// Cancel a download by document ID
  public func cancelDocumentDownload(documentId: Int64) {
    cancelDownload(id: "doc_\(documentId)")
  }

  /// Cancel a download by video ID
  public func cancelVideoDownload(videoId: Int64) {
    cancelDownload(id: "video_\(videoId)")
  }

  /// Cancel a download by photo ID
  public func cancelPhotoDownload(photoId: Int64) {
    cancelDownload(id: "photo_\(photoId)")
  }

  /// Cancel a download by voice ID
  public func cancelVoiceDownload(voiceId: Int64) {
    cancelDownload(id: "voice_\(voiceId)")
  }

  // Add this to FileDownloader class
  public func isDownloadActive(for id: String) -> Bool {
    activeTasks[id] != nil
  }

  public func isDocumentDownloadActive(documentId: Int64) -> Bool {
    isDownloadActive(for: "doc_\(documentId)")
  }

  public func isVideoDownloadActive(videoId: Int64) -> Bool {
    isDownloadActive(for: "video_\(videoId)")
  }

  public func isPhotoDownloadActive(photoId: Int64) -> Bool {
    isDownloadActive(for: "photo_\(photoId)")
  }

  public func isVoiceDownloadActive(voiceId: Int64) -> Bool {
    isDownloadActive(for: "voice_\(voiceId)")
  }

  private static func voiceFileExtension(mimeType: String) -> String {
    switch mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "audio/mp4", "audio/x-m4a":
        return "m4a"
      case "audio/ogg":
        return "ogg"
      default:
        return "ogg"
    }
  }

  // MARK: - Private Methods

  private func progressPublisher(for id: String) -> AnyPublisher<DownloadProgress, Never> {
    if let publisher = progressPublishers[id] {
      return publisher.eraseToAnyPublisher()
    }

    // Create a new publisher with initial state (not complete)
    let initialProgress = latestProgress[id] ?? DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0)
    let publisher = CurrentValueSubject<DownloadProgress, Never>(initialProgress)

    log.debug("Created new progress publisher for \(id): \(initialProgress)")

    progressPublishers[id] = publisher
    return publisher.eraseToAnyPublisher()
  }

  private func currentProgress(for id: String) -> DownloadProgress? {
    latestProgress[id] ?? progressPublishers[id]?.value
  }

  private func publishProgress(_ progress: DownloadProgress) {
    latestProgress[progress.id] = progress

    if let publisher = progressPublishers[progress.id] {
      publisher.send(progress)
    } else {
      progressPublishers[progress.id] = CurrentValueSubject<DownloadProgress, Never>(progress)
    }
  }

  private func cancelDownload(id: String) {
    // Cancel the task and wait for it to complete
    if let task = activeTasks[id] {
      // Cancel with resume data to properly clean up
      task.cancel { [weak self] resumeData in
        guard let self else { return }

        // Log cancellation
        if let resumeData {
          log.debug("Download canceled with \(resumeData.count) bytes of resume data")
        } else {
          log.debug("Download canceled with no resume data")
        }
      }
    }

    activeTasks[id] = nil

    if let lastProgress = currentProgress(for: id) {
      publishProgress(
        DownloadProgress(
          id: id,
          bytesReceived: lastProgress.bytesReceived,
          totalBytes: lastProgress.totalBytes,
          error: NSError(
            domain: "FileDownloader",
            code: -999,
            userInfo: [NSLocalizedDescriptionKey: "Download cancelled"]
          )
        )
      )
    }
  }

  private func downloadFile(
    id: String,
    url: URL,
    localUrl: URL,
    expectedBytes: Int64 = 0,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    // Create download task
    let task = session.downloadTask(with: url)
    task.taskDescription = id

    // Store task and completion handler
    activeTasks[id] = task

    publishProgress(DownloadProgress(id: id, bytesReceived: 0, totalBytes: expectedBytes))

    // Store completion handler
    downloadCompletions[id] = { [weak self] result in
      guard let self else { return }

      // Move to final URL
      if case let .success(fileUrl) = result {
        do {
          try FileManager.default.moveItem(at: fileUrl, to: localUrl)
          completion(.success(localUrl))
        } catch {
          log.error("Error moving downloaded file: \(error)")
          self.failDownload(id: id, error: error)
          completion(.failure(error))
        }
      } else {
        completion(result)
      }

      // Clean up
      activeTasks[id] = nil
    }

    // Start the download
    task.resume()
  }

  private var downloadCompletions: [String: (Result<URL, Error>) -> Void] = [:]

  private func updateProgress(id: String, bytesReceived: Int64, totalBytes: Int64) {
    log.debug("Progress update for \(id): \(bytesReceived)/\(totalBytes)")
    let progress = DownloadProgress(id: id, bytesReceived: bytesReceived, totalBytes: totalBytes)
    publishProgress(progress)
  }

  private func completeDownload(id: String, location: URL?, error: Error?) {
    if let error {
      publishProgress(DownloadProgress.failed(id: id, error: error))
      if let completion = downloadCompletions[id] {
        downloadCompletions[id] = nil
        completion(.failure(error))
      }
    } else if let location {
      let lastProgress = currentProgress(for: id) ?? DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0)
      let totalBytes = max(lastProgress.totalBytes, lastProgress.bytesReceived)
      publishProgress(DownloadProgress.completed(id: id, totalBytes: totalBytes))
      if let completion = downloadCompletions[id] {
        downloadCompletions[id] = nil
        completion(.success(location))
      }
    }
  }

  private func failDownload(id: String, error: Error) {
    publishProgress(DownloadProgress.failed(id: id, error: error))
  }
}

// MARK: - URLSessionDownloadDelegate

extension FileDownloader: URLSessionDownloadDelegate {
  public nonisolated func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let taskId = downloadTask.taskDescription else { return }

    log.debug("Download finished for task \(taskId): \(location)")

    // Important: We need to move the file immediately, before this method returns
    // Create a copy of the file in a more persistent temporary location
    do {
      let tempDirectory = FileManager.default.temporaryDirectory
      let tempFilename = UUID().uuidString
      let persistentTempURL = tempDirectory.appendingPathComponent(tempFilename)

      try FileManager.default.copyItem(at: location, to: persistentTempURL)

      DispatchQueue.main.async {
        self.completeDownload(id: taskId, location: persistentTempURL, error: nil)
      }
    } catch {
      let downloadError = error
      DispatchQueue.main.async {
        self.log.error("Error copying temporary file: \(downloadError)")
        self.completeDownload(id: taskId, location: nil, error: downloadError)
      }
    }
  }

  public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let taskId = task.taskDescription else { return }

    Task { @MainActor in
      completeDownload(id: taskId, location: nil, error: error)
    }
  }

  public nonisolated func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard let taskId = downloadTask.taskDescription else { return }

    // Log progress
    log.debug("Download progress for \(taskId): \(totalBytesWritten)/\(totalBytesExpectedToWrite)")

    Task { @MainActor in
      updateProgress(id: taskId, bytesReceived: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
    }
  }
}
