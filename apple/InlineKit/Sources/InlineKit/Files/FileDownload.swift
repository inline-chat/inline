import Combine
import Foundation
import Logger
import Nuke

#if os(iOS)
import UIKit
#else
import AppKit
#endif

final class DownloadProgressThrottler: @unchecked Sendable {
  private let minimumInterval: TimeInterval
  private let lock = NSLock()
  private var lastEmission: [String: TimeInterval] = [:]

  init(maxUpdatesPerSecond: Double = 10) {
    minimumInterval = maxUpdatesPerSecond > 0 ? 1 / maxUpdatesPerSecond : .infinity
  }

  func shouldPublish(id: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    lock.lock()
    defer { lock.unlock() }

    if let last = lastEmission[id], now - last < minimumInterval {
      return false
    }
    lastEmission[id] = now
    return true
  }

  func remove(_ id: String) {
    lock.lock()
    lastEmission[id] = nil
    lock.unlock()
  }

  func removeAll() {
    lock.lock()
    lastEmission.removeAll(keepingCapacity: true)
    lock.unlock()
  }
}

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

  static func transferring(id: String, bytesReceived: Int64, totalBytes: Int64) -> DownloadProgress {
    DownloadProgress(
      id: id,
      bytesReceived: bytesReceived,
      totalBytes: totalBytes,
      isComplete: false
    )
  }

  public static func failed(id: String, error: Error) -> DownloadProgress {
    DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0, error: error)
  }

  public var isCancellation: Bool {
    guard let error else { return false }
    return FileDownloader.isCancellation(error)
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
  static let terminalStateRetentionLimit = 256
  static let inactivePublisherRetentionLimit = 256

  private struct FinalizationTask {
    let token: UUID
    let task: Task<Void, Never>
  }

  private struct DownloadCompletion {
    let token: UUID
    let handler: (Result<URL, Error>) -> Void
  }

  private var progressPublishers: [String: CurrentValueSubject<DownloadProgress, Never>] = [:]
  private var latestProgress: [String: DownloadProgress] = [:]
  private var activeTasks: [String: URLSessionDownloadTask] = [:]
  // Keep canceled native work owned until it settles, including during logout.
  private var nativeTasks: [UUID: Task<Void, Never>] = [:]
  private var activeDownloadTokens: [String: UUID] = [:]
  private var finalizationTasks: [String: FinalizationTask] = [:]
  private var session: URLSession!
  private let log = Log.scoped("FileDownloader")
  private let progressThrottler = DownloadProgressThrottler()
  private var terminalStateKeys = BoundedTerminalStateKeys(limit: terminalStateRetentionLimit)
  private var inactivePublisherKeys = BoundedTerminalStateKeys(limit: inactivePublisherRetentionLimit)
  private var sessionResetTask: Task<Void, Never>?

  override private init() {
    super.init()
    makeSession()
  }

  private func makeSession() {
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

  public func currentVoiceProgress(voiceId: Int64) -> DownloadProgress? {
    currentProgress(for: "voice_\(voiceId)")
  }

  public func downloadDocument(
    document: DocumentInfo,
    for message: Message? = nil,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    let nativeDownload: NativeDownloadOperation?
    do {
      if ExperimentalFeatureFlags.nativeFileDownloadsEnabled, let message {
        let source = try NativeDocumentDownload()
        nativeDownload = { destination, progress in
          try await source.download(
            documentID: document.document.documentId, message: message, to: destination, progress: progress
          )
        }
      } else {
        nativeDownload = nil
      }
    } catch {
      completion(.failure(error))
      return
    }
    let url = document.document.cdnUrl.flatMap(URL.init(string:))
    guard url != nil || nativeDownload != nil else {
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
    log.debug("Starting document download \(document.id) transport=\(nativeDownload == nil ? "cdn" : "native-v3")")

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: Int64(document.document.size ?? 0),
      nativeDownload: nativeDownload,
      completion: { [weak self] token, result in
        guard let self else { return }

        switch result {
          case let .success(fileUrl):
            self.finalizeDocumentDownload(id: downloadId, token: token, fileURL: fileUrl, persist: {
              try await FileCache.shared.saveDocumentDownload(
                  document: document,
                  localPath: localPath,
                  message: message
              )
            }, completion: completion)

          case let .failure(error):
            if !Self.isCancellation(error) {
              log.error("Document download failed", error: error)
            }
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
      completion: { [weak self] token, result in
        guard let self else { return }

        switch result {
          case let .success(fileUrl):
            // Notify FileCache to update database
            self.startFinalization(id: downloadId, token: token) { [weak self] in
              guard let self else { return }
              do {
                try Task.checkCancellation()
                try self.ensureActiveDownload(id: downloadId, token: token)
                try await FileCache.shared.saveVideoDownload(video: video, localPath: localPath, message: message)
                guard self.isActiveDownload(id: downloadId, token: token) else {
                  completion(.failure(URLError(.cancelled)))
                  return
                }
                self.succeedDownload(id: downloadId, token: token)
                completion(.success(fileUrl))
              } catch {
                try? FileManager.default.removeItem(at: fileUrl)
                if self.isActiveDownload(id: downloadId, token: token), !Self.isCancellation(error) {
                  self.log.error("Error saving video download", error: error)
                }
                self.failDownload(id: downloadId, token: token, error: error)
                completion(.failure(error))
              }
            }

          case let .failure(error):
            if !Self.isCancellation(error) {
              log.error("Video download failed", error: error)
            }
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
    guard let fileExtension = Self.voiceFileExtension(mimeType: voice.mimeType) else {
      let error = NSError(
        domain: "FileDownloader",
        code: 415,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported voice MIME type"]
      )
      log.warning("Unsupported voice MIME type \(voice.mimeType) for voice \(voice.voiceID)")
      completion(.failure(error))
      return
    }

    let localPath = "\(UUID().uuidString).\(fileExtension)"
    let localUrl = FileCache.getUrl(for: .voices, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: voice.size,
      completion: { [weak self] token, result in
        guard let self else { return }

        switch result {
        case let .success(fileURL):
          self.startFinalization(id: downloadId, token: token) { [weak self] in
            guard let self else { return }
            do {
              try Task.checkCancellation()
              try self.ensureActiveDownload(id: downloadId, token: token)
              try await FileCache.shared.saveVoiceDownload(message: message, localPath: localPath)
              guard self.isActiveDownload(id: downloadId, token: token) else {
                completion(.failure(URLError(.cancelled)))
                return
              }
              self.succeedDownload(id: downloadId, token: token)
              completion(.success(fileURL))
            } catch {
              try? FileManager.default.removeItem(at: fileURL)
              if self.isActiveDownload(id: downloadId, token: token), !Self.isCancellation(error) {
                self.log.error("Error saving voice download", error: error)
              }
              self.failDownload(id: downloadId, token: token, error: error)
              completion(.failure(error))
            }
          }

        case let .failure(error):
          if !Self.isCancellation(error) {
            self.log.error("Voice download failed", error: error)
          }
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

  public func isDownloadActive(for id: String) -> Bool {
    activeDownloadTokens[id] != nil
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

  /// Ends the current account's transfer session without removing downloaded files.
  public func resetSession() async {
    if let sessionResetTask {
      await sessionResetTask.value
      return
    }

    let cancellation = URLError(.cancelled)
    let completions = Array(downloadCompletions.values)
    let finalizations = finalizationTasks.values.map(\.task)
    let nativeTransfers = Array(nativeTasks.values)
    let reset = Task {
      for task in nativeTransfers {
        await task.value
      }
      for task in finalizations {
        await task.value
      }
    }
    // Publisher completion and request completion handlers are externally
    // observable and may synchronously reenter. Publish the admission barrier first.
    sessionResetTask = reset

    for task in activeTasks.values {
      task.cancel()
    }
    for task in nativeTransfers {
      task.cancel()
    }
    activeTasks.removeAll()
    activeDownloadTokens.removeAll()
    downloadCompletions.removeAll()
    for task in finalizations {
      task.cancel()
    }
    finalizationTasks.removeAll()

    for id in Array(progressPublishers.keys) {
      finishProgressPublisher(id: id)
    }
    progressPublishers.removeAll()
    latestProgress.removeAll()
    terminalStateKeys.removeAll()
    inactivePublisherKeys.removeAll()
    progressThrottler.removeAll()

    let oldSession = session
    makeSession()
    oldSession?.invalidateAndCancel()

    for completion in completions {
      completion.handler(.failure(cancellation))
    }

    await reset.value
    sessionResetTask = nil
  }

  private static func voiceFileExtension(mimeType: String) -> String? {
    switch mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "audio/mp4", "audio/x-m4a":
        return "m4a"
      case "audio/ogg":
        return "ogg"
      default:
        return nil
    }
  }

  // MARK: - Private Methods

  private func progressPublisher(for id: String) -> AnyPublisher<DownloadProgress, Never> {
    if sessionResetTask != nil {
      return Just(.failed(id: id, error: URLError(.cancelled))).eraseToAnyPublisher()
    }

    if let latest = latestProgress[id], latest.isComplete || latest.error != nil {
      return Just(latest).eraseToAnyPublisher()
    }

    let publisher: CurrentValueSubject<DownloadProgress, Never>
    if let existing = progressPublishers[id] {
      publisher = existing
      if !isDownloadActive(for: id) {
        retainInactivePublisher(id: id)
      }
    } else {
      // Views intentionally subscribe before a transfer begins. Keep that subject
      // connected when the transfer starts, and bound inactive subjects with the LRU.
      let initialProgress = latestProgress[id] ?? DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0)
      publisher = CurrentValueSubject<DownloadProgress, Never>(initialProgress)
      progressPublishers[id] = publisher
      retainInactivePublisher(id: id)
      log.debug("Created new progress publisher for \(id)")
    }

    return publisher.eraseToAnyPublisher()
  }

  private func retainInactivePublisher(id: String) {
    let evicted = inactivePublisherKeys.record(id)
    for evictedID in evicted {
      guard !isDownloadActive(for: evictedID) else { continue }
      finishProgressPublisher(id: evictedID)
    }
  }

  private func finishProgressPublisher(id: String) {
    let publisher = progressPublishers.removeValue(forKey: id)
    inactivePublisherKeys.remove(id)
    publisher?.send(completion: .finished)
  }

  private func currentProgress(for id: String) -> DownloadProgress? {
    latestProgress[id] ?? progressPublishers[id]?.value
  }

  private func publishProgress(_ progress: DownloadProgress) {
    inactivePublisherKeys.remove(progress.id)
    latestProgress[progress.id] = progress

    if let publisher = progressPublishers[progress.id] {
      publisher.send(progress)
    } else if !progress.isComplete, progress.error == nil {
      progressPublishers[progress.id] = CurrentValueSubject<DownloadProgress, Never>(progress)
    }

    if progress.isComplete || progress.error != nil {
      finishProgressPublisher(id: progress.id)
      let evicted = terminalStateKeys.record(progress.id)
      for evictedID in evicted {
        latestProgress.removeValue(forKey: evictedID)
        finishProgressPublisher(id: evictedID)
      }
      progressThrottler.remove(progress.id)
    }
  }

  private func cancelDownload(id: String) {
    // Once all bytes have arrived, let cache publication choose the outcome.
    // Canceling that commit could report cancellation for an already-saved file.
    // Account reset remains a separate barrier and drains finalization below.
    guard finalizationTasks[id] == nil else { return }
    if let token = activeDownloadTokens[id] { nativeTasks[token]?.cancel() }
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
    activeDownloadTokens[id] = nil
    clearRetainedProgress(id: id)
    if let completion = downloadCompletions.removeValue(forKey: id) {
      completion.handler(.failure(URLError(.cancelled)))
    }
  }

  typealias NativeDownloadOperation = @Sendable (
    URL, @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> URL

  func downloadFile(
    id: String,
    url: URL?,
    localUrl: URL,
    expectedBytes: Int64 = 0,
    nativeDownload: NativeDownloadOperation? = nil,
    completion: @escaping (UUID, Result<URL, Error>) -> Void
  ) {
    let token = UUID()
    guard sessionResetTask == nil else {
      completion(token, .failure(URLError(.cancelled)))
      return
    }
    guard activeDownloadTokens[id] == nil else {
      let error = NSError(
        domain: "FileDownloader",
        code: 409,
        userInfo: [NSLocalizedDescriptionKey: "A download is already active for this file"]
      )
      completion(token, .failure(error))
      return
    }

    prepareForActiveDownload(id: id)
    activeDownloadTokens[id] = token

    if let nativeDownload {
      startNativeDownload(
        id: id, token: token, localUrl: localUrl, expectedBytes: expectedBytes,
        operation: nativeDownload, completion: completion
      )
      return
    }
    guard let url else {
      activeDownloadTokens[id] = nil
      completion(token, .failure(URLError(.badURL)))
      return
    }

    // Create download task
    let task = session.downloadTask(with: url)
    task.taskDescription = id

    // Store task and completion handler
    activeTasks[id] = task

    publishProgress(DownloadProgress(id: id, bytesReceived: 0, totalBytes: expectedBytes))

    // Store completion handler
    downloadCompletions[id] = DownloadCompletion(token: token) { [weak self] result in
      guard let self else { return }

      // Move to final URL
      if case let .success(fileUrl) = result {
        guard self.isActiveDownload(id: id, token: token) else {
          try? FileManager.default.removeItem(at: fileUrl)
          return
        }
        do {
          try FileManager.default.moveItem(at: fileUrl, to: localUrl)
          completion(token, .success(localUrl))
        } catch {
          try? FileManager.default.removeItem(at: fileUrl)
          log.error("Error moving downloaded file", error: error)
          self.failDownload(id: id, token: token, error: error)
          completion(token, .failure(error))
        }
      } else {
        completion(token, result)
      }

      // Clean up
      guard self.activeDownloadTokens[id] == token else { return }
      self.activeTasks[id] = nil
      if self.finalizationTasks[id]?.token != token {
        self.activeDownloadTokens[id] = nil
      }
    }

    // Start the download
    task.resume()
  }

  private func startNativeDownload(
    id: String, token: UUID, localUrl: URL, expectedBytes: Int64,
    operation: @escaping NativeDownloadOperation,
    completion: @escaping (UUID, Result<URL, Error>) -> Void
  ) {
    downloadCompletions[id] = DownloadCompletion(token: token) { result in completion(token, result) }
    let throttler = progressThrottler
    nativeTasks[token] = Task { [weak self] in
      guard let self else { return }
      defer {
        self.nativeTasks[token] = nil
        if self.isActiveDownload(id: id, token: token), self.finalizationTasks[id]?.token != token {
          self.activeDownloadTokens[id] = nil
        }
      }
      do {
        try Task.checkCancellation()
        let file = try await operation(localUrl) { [weak self] received, total in
          guard throttler.shouldPublish(id: id) else { return }
          Task { @MainActor [weak self] in
            guard let self, self.isActiveDownload(id: id, token: token), self.nativeTasks[token] != nil else { return }
            self.publishProgress(.transferring(id: id, bytesReceived: received, totalBytes: total))
          }
        }
        guard !Task.isCancelled, self.isActiveDownload(id: id, token: token) else {
          try? FileManager.default.removeItem(at: file)
          return
        }
        self.nativeTasks[token] = nil
        self.downloadCompletions.removeValue(forKey: id)?.handler(.success(file))
      } catch {
        guard self.isActiveDownload(id: id, token: token) else { return }
        self.nativeTasks[token] = nil
        self.failDownload(id: id, token: token, error: error)
        self.downloadCompletions.removeValue(forKey: id)?.handler(.failure(error))
      }
    }
    // Install ownership/completion before an observer can synchronously cancel.
    publishProgress(DownloadProgress(id: id, bytesReceived: 0, totalBytes: expectedBytes))
  }

  private var downloadCompletions: [String: DownloadCompletion] = [:]

  private func updateProgress(
    id: String,
    task: URLSessionTask,
    bytesReceived: Int64,
    totalBytes: Int64
  ) {
    guard let activeTask = activeTasks[id], activeTask === task else { return }
    let progress = DownloadProgress.transferring(id: id, bytesReceived: bytesReceived, totalBytes: totalBytes)
    publishProgress(progress)
  }

  private func completeDownload(
    id: String,
    task: URLSessionTask,
    location: URL?,
    error: Error?,
    sourceSession: URLSession
  ) {
    guard sourceSession === session else {
      if let location { try? FileManager.default.removeItem(at: location) }
      return
    }
    guard let activeTask = activeTasks[id], activeTask === task else {
      if let location { try? FileManager.default.removeItem(at: location) }
      return
    }

    if let error {
      if Self.isCancellation(error) {
        clearRetainedProgress(id: id)
      } else {
        publishProgress(DownloadProgress.failed(id: id, error: error))
      }
      if let completion = downloadCompletions.removeValue(forKey: id) {
        completion.handler(.failure(error))
      }
    } else if let location {
      if let completion = downloadCompletions.removeValue(forKey: id) {
        completion.handler(.success(location))
      }
    }
  }

  private func failDownload(id: String, token: UUID, error: Error) {
    guard isActiveDownload(id: id, token: token) else { return }
    guard !Self.isCancellation(error) else {
      clearRetainedProgress(id: id)
      return
    }
    publishProgress(DownloadProgress.failed(id: id, error: error))
  }

  private func succeedDownload(id: String, token: UUID) {
    guard isActiveDownload(id: id, token: token) else { return }
    let lastProgress = currentProgress(for: id) ?? DownloadProgress(id: id, bytesReceived: 0, totalBytes: 0)
    let totalBytes = max(lastProgress.totalBytes, lastProgress.bytesReceived)
    publishProgress(DownloadProgress.completed(id: id, totalBytes: totalBytes))
  }

  func finalizeDocumentDownload(
    id: String, token: UUID, fileURL: URL,
    persist: @escaping @MainActor () async throws -> Void,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    startFinalization(id: id, token: token) { [weak self] in
      guard let self else { return }
      do {
        try Task.checkCancellation()
        try self.ensureActiveDownload(id: id, token: token)
        try await persist()
        // Reset may fence this account while the cache commit is in flight.
        // Keep a successfully committed file, but don't deliver it to a new session.
        guard self.isActiveDownload(id: id, token: token) else {
          completion(.failure(URLError(.cancelled)))
          return
        }
        self.succeedDownload(id: id, token: token)
        completion(.success(fileURL))
      } catch {
        try? FileManager.default.removeItem(at: fileURL)
        if self.isActiveDownload(id: id, token: token), !Self.isCancellation(error) {
          self.log.error("Error saving document download", error: error)
        }
        self.failDownload(id: id, token: token, error: error)
        completion(.failure(error))
      }
    }
  }

  private func startFinalization(
    id: String,
    token: UUID,
    operation: @escaping @MainActor () async -> Void
  ) {
    guard isActiveDownload(id: id, token: token) else { return }
    let task = Task { @MainActor [weak self] in
      await operation()
      self?.finishFinalization(id: id, token: token)
    }
    finalizationTasks[id] = FinalizationTask(token: token, task: task)
  }

  private func finishFinalization(id: String, token: UUID) {
    guard finalizationTasks[id]?.token == token else { return }
    finalizationTasks[id] = nil
    if activeDownloadTokens[id] == token {
      activeDownloadTokens[id] = nil
    }
  }

  private func isActiveDownload(id: String, token: UUID) -> Bool {
    activeDownloadTokens[id] == token
  }

  private func ensureActiveDownload(id: String, token: UUID) throws {
    guard isActiveDownload(id: id, token: token) else {
      throw CancellationError()
    }
  }

  private func clearRetainedProgress(id: String) {
    latestProgress.removeValue(forKey: id)
    finishProgressPublisher(id: id)
    terminalStateKeys.remove(id)
    inactivePublisherKeys.remove(id)
    progressThrottler.remove(id)
  }

  private func prepareForActiveDownload(id: String) {
    latestProgress.removeValue(forKey: id)
    terminalStateKeys.remove(id)
    inactivePublisherKeys.remove(id)
    progressThrottler.remove(id)
  }

  func retainedProgressPublisherCount() -> Int {
    progressPublishers.count
  }

  nonisolated static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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

    log.debug("Download finished for task \(taskId)")

    // Important: We need to move the file immediately, before this method returns
    // Create a copy of the file in a more persistent temporary location
    do {
      let tempDirectory = FileManager.default.temporaryDirectory
      let tempFilename = UUID().uuidString
      let persistentTempURL = tempDirectory.appendingPathComponent(tempFilename)

      try FileManager.default.copyItem(at: location, to: persistentTempURL)

      DispatchQueue.main.async {
        self.completeDownload(
          id: taskId,
          task: downloadTask,
          location: persistentTempURL,
          error: nil,
          sourceSession: session
        )
      }
    } catch {
      let downloadError = error
      DispatchQueue.main.async {
        self.log.error("Error copying temporary file", error: downloadError)
        self.completeDownload(
          id: taskId,
          task: downloadTask,
          location: nil,
          error: downloadError,
          sourceSession: session
        )
      }
    }
  }

  public nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let taskId = task.taskDescription else { return }

    Task { @MainActor in
      completeDownload(id: taskId, task: task, location: nil, error: error, sourceSession: session)
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

    guard progressThrottler.shouldPublish(id: taskId) else { return }

    Task { @MainActor in
      updateProgress(
        id: taskId,
        task: downloadTask,
        bytesReceived: totalBytesWritten,
        totalBytes: totalBytesExpectedToWrite
      )
    }
  }
}
