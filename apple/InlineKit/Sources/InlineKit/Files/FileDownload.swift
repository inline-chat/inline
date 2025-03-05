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
    self.id = id
    self.bytesReceived = bytesReceived
    self.totalBytes = totalBytes
    progress = totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0

    // Fix: Only consider complete if we have received bytes and they match total bytes
    isComplete = totalBytes > 0 && bytesReceived == totalBytes && error == nil

    self.error = error
  }

  public static func completed(id: String, totalBytes: Int64) -> DownloadProgress {
    DownloadProgress(id: id, bytesReceived: totalBytes, totalBytes: totalBytes)
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

  /// Get a publisher for tracking download progress of a video
  public func videoProgressPublisher(videoId: Int64) -> AnyPublisher<DownloadProgress, Never> {
    progressPublisher(for: "video_\(videoId)")
  }

  /// Get a publisher for tracking download progress of a photo
  public func photoProgressPublisher(photoId: Int64) -> AnyPublisher<DownloadProgress, Never> {
    progressPublisher(for: "photo_\(photoId)")
  }

  /// Download a document file
  public func downloadDocument(
    document: DocumentInfo,
    for message: Message,
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
    let fileExtension = URL(fileURLWithPath: document.document.fileName ?? "Unknown").pathExtension
    let localPath = "\(UUID().uuidString)_\(document.document.fileName ?? "Unknown")"
    let localUrl = FileCache.getUrl(for: .documents, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
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
    let fileName = "VIDEO_\(video.id)"
    let fileExtension = "mp4"
    let localPath = "\(UUID().uuidString).\(fileExtension)"
    let localUrl = FileCache.getUrl(for: .videos, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
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

  // MARK: - Private Methods

  private func progressPublisher(for id: String) -> AnyPublisher<DownloadProgress, Never> {
    if let publisher = progressPublishers[id] {
      return publisher.eraseToAnyPublisher()
    }

    // Create a new publisher with initial state (not complete)
    let initialProgress = DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0)
    let publisher = CurrentValueSubject<DownloadProgress, Never>(initialProgress)

    log.debug("Created new progress publisher for \(id): \(initialProgress)")

    progressPublishers[id] = publisher
    return publisher.eraseToAnyPublisher()
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

    if let publisher = progressPublishers[id] {
      let lastProgress = publisher.value
      publisher.send(
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

  private func downloadFile(id: String, url: URL, localUrl: URL, completion: @escaping (Result<URL, Error>) -> Void) {
    // Create download task
    let task = session.downloadTask(with: url)
    task.taskDescription = id

    // Store task and completion handler
    activeTasks[id] = task

    // Initialize progress publisher if it doesn't exist
    if progressPublishers[id] == nil {
      progressPublishers[id] = CurrentValueSubject<DownloadProgress, Never>(
        DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0)
      )
    }

    // Store completion handler
    downloadCompletions[id] = { [weak self] result in
      guard let self else { return }

      // Move to final URL
      if case let .success(fileUrl) = result {
        do {
          try FileManager.default.moveItem(at: fileUrl, to: localUrl)
        } catch {
          log.error("Error moving downloaded file: \(error)")
          completion(.failure(error))
          return
        }
      }

      // Clean up
      activeTasks[id] = nil

      // Execute completion handler
      completion(result)

      // Clean up publisher after a delay
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
        self?.downloadCompletions[id] = nil
      }
    }

    // Start the download
    task.resume()
  }

  private var downloadCompletions: [String: (Result<URL, Error>) -> Void] = [:]

  private func updateProgress(id: String, bytesReceived: Int64, totalBytes: Int64) {
    log.debug("Progress update for \(id): \(bytesReceived)/\(totalBytes)")
    let progress = DownloadProgress(id: id, bytesReceived: bytesReceived, totalBytes: totalBytes)
    progressPublishers[id]?.send(progress)
  }

  private func completeDownload(id: String, location: URL?, error: Error?) {
    if let error {
      progressPublishers[id]?.send(DownloadProgress.failed(id: id, error: error))
      downloadCompletions[id]?(.failure(error))
    } else if let location, let publisher = progressPublishers[id] {
      let lastProgress = publisher.value
      progressPublishers[id]?.send(DownloadProgress.completed(id: id, totalBytes: lastProgress.totalBytes))
      downloadCompletions[id]?(.success(location))
    }
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
        if let completion = self.downloadCompletions[taskId] {
          completion(.success(persistentTempURL))
        }
      }
    } catch {
      let downloadError = error
      DispatchQueue.main.async {
        self.log.error("Error copying temporary file: \(downloadError)")
        if let completion = self.downloadCompletions[taskId] {
          completion(.failure(downloadError))
        }
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
