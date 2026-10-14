import Auth
import Combine
import Foundation
import InlineProtocol
import Logger
import Nuke
import RealtimeV2

#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum FileDownloadValidationError: Error, LocalizedError, Equatable, Sendable {
  case invalidHTTPResponse
  case httpStatus(Int)
  case byteCountMismatch(expected: Int64, actual: Int64)

  var errorDescription: String? {
    switch self {
    case .invalidHTTPResponse:
      "The server returned an invalid file response."
    case let .httpStatus(status):
      "The file download failed (HTTP \(status))."
    case .byteCountMismatch:
      "The downloaded file has an unexpected size. Please retry the download."
    }
  }
}

enum DownloadedFileValidation {
  static func validateHTTPResponse(_ response: URLResponse?) throws {
    guard let response = response as? HTTPURLResponse else {
      throw FileDownloadValidationError.invalidHTTPResponse
    }
    guard (200 ... 299).contains(response.statusCode) else {
      throw FileDownloadValidationError.httpStatus(response.statusCode)
    }
  }

  static func validateDocumentFile(at url: URL, expectedByteCount: Int64) throws {
    guard expectedByteCount > 0 else { return }
    // Check the materialized file, not HTTP Content-Length: Foundation may
    // decode compressed bodies or assemble a resumed 206 response.
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
      throw FileDownloadValidationError.byteCountMismatch(expected: expectedByteCount, actual: -1)
    }
    guard byteCount == expectedByteCount else {
      throw FileDownloadValidationError.byteCountMismatch(expected: expectedByteCount, actual: byteCount)
    }
  }

  /// Legacy metadata may describe a different object size. Return its mismatch
  /// for diagnostics while retaining a successfully materialized CDN object.
  static func validateCDNFile(at url: URL, expectedByteCount: Int64) throws -> FileDownloadValidationError? {
    do {
      try validateDocumentFile(at: url, expectedByteCount: expectedByteCount)
      return nil
    } catch let mismatch as FileDownloadValidationError {
      guard case .byteCountMismatch = mismatch else { throw mismatch }
      return mismatch
    }
  }
}

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
  private var accountTokens: [UUID: AuthAccountMutationToken] = [:]
  private var downloadLocations: [UUID: FileMessageLocation] = [:]
  private var knownAccountIDs: Set<Int64> = []
  private var cacheMaintenanceDepth = 0
  private var transferGeneration: UInt64 = 0
  private var authorityObserver: NSObjectProtocol?
  private let nativeManager: NativeDownloadManager
  private let nativeCacheDirectories: [URL]
  private var cancellationTasks: [String: Task<Void, Never>] = [:]
  private var joinedCompletions: [UUID: [(UUID, Result<URL, Error>) -> Void]] = [:]
  private struct RequestCompletions {
    let token: UUID
    var handlers: [(Result<URL, Error>) -> Void]
  }
  private var requestCompletions: [String: RequestCompletions] = [:]
  // Keep canceled native work owned until it settles, including during logout.
  private var nativeTasks: [UUID: Task<Void, Never>] = [:]
  private var activeDownloadTokens: [String: UUID] = [:]
  private var finalizationTasks: [String: FinalizationTask] = [:]
  private var session: URLSession!
  private let auth: AuthHandle
  private let log = Log.scoped("FileDownloader")
  private let progressThrottler = DownloadProgressThrottler()
  private var terminalStateKeys = BoundedTerminalStateKeys(limit: terminalStateRetentionLimit)
  private var inactivePublisherKeys = BoundedTerminalStateKeys(limit: inactivePublisherRetentionLimit)
  private var sessionResetTask: Task<Void, Never>?

  override private convenience init() {
    self.init(auth: Auth.shared.handle)
  }

  static var nativeTransferDirectories: [URL] {
    [FileHelpers.getLocalCacheDirectory(for: .documents, createIfNeeded: false),
     FileHelpers.getLocalCacheDirectory(for: .videos, createIfNeeded: false)]
  }

  init(auth: AuthHandle, nativeManager: NativeDownloadManager = .shared,
       nativeCacheDirectories: [URL] = FileDownloader.nativeTransferDirectories) {
    self.auth = auth
    self.nativeManager = nativeManager
    self.nativeCacheDirectories = nativeCacheDirectories
    if let id = auth.userId() { knownAccountIDs.insert(id) }
    super.init()
    makeSession()
    authorityObserver = auth.observeAccountAuthorityWillChange { [weak self] retirement in
      guard let self else { return }
      self.knownAccountIDs.insert(retirement.previousAccount.userID)
      // Auth closes admission synchronously, then awaits this receipt before
      // replacing credentials. The reset owns a separate drain task.
      retirement.requireRetirement(Task {
        await self.resetSession(accountID: retirement.previousAccount.userID)
        return true
      })
    }
  }

  isolated deinit {
    if let authorityObserver { NotificationCenter.default.removeObserver(authorityObserver) }
  }

  public func prepareForLaunch() async {
    for directory in nativeCacheDirectories { await nativeManager.sweep(directory: directory) }
  }

  public func beginCacheMaintenance() async {
    cacheMaintenanceDepth += 1
    await resetSession()
    for directory in nativeCacheDirectories { await nativeManager.clearIdleCache(directory: directory) }
  }

  public func endCacheMaintenance() {
    cacheMaintenanceDepth = max(0, cacheMaintenanceDepth - 1)
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
    let accountToken: AuthAccountMutationToken
    do {
      accountToken = try auth.beginAccountMutation()
    } catch {
      completion(.failure(URLError(.cancelled)))
      return
    }
    let nativeDownload: NativeDownloadOperation?
    do {
      if ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth), let message {
        let source = try NativeMessageFileDownload(auth: auth)
        nativeDownload = { destination, progress in
          try await source.download(
            media: .document(document.document.documentId), message: message, to: destination, progress: progress
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
    if joinRequest(id: downloadId, completion: completion) { return }
    let requestToken = registerRequest(id: downloadId, completion: completion)
    let completion: (Result<URL, Error>) -> Void = { [weak self] result in
      self?.finishRequest(id: downloadId, token: requestToken, result: result)
    }
    let localPath = "\(UUID().uuidString)_\(document.document.fileName ?? "Unknown")"
    let localUrl = FileCache.getUrl(for: .documents, localPath: localPath)
    log.debug("Starting document download \(document.id) transport=\(nativeDownload == nil ? "cdn" : "native")")

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: Int64(document.document.size ?? 0),
      accountToken: accountToken,
      messageLocation: message.map(Self.location(for:)),
      nativeDownload: nativeDownload,
      completion: { [weak self] token, result in
        guard let self else { return }

        switch result {
          case let .success(fileUrl):
            self.finalizeDocumentDownload(id: downloadId, token: token, fileURL: fileUrl, persist: {
              try await FileCache.shared.saveDocumentDownload(
                  document: document,
                  localPath: localPath,
                  message: message, auth: self.auth, accountToken: accountToken
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
    let accountToken: AuthAccountMutationToken
    do {
      accountToken = try auth.beginAccountMutation()
    } catch {
      completion(.failure(URLError(.cancelled)))
      return
    }
    let nativeDownload: NativeDownloadOperation?
    do {
      if ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth) {
        let source = try NativeMessageFileDownload(auth: auth)
        nativeDownload = { destination, progress in
          try await source.download(
            media: .video(video.video.videoId), message: message, to: destination, progress: progress
          )
        }
      } else {
        nativeDownload = nil
      }
    } catch {
      completion(.failure(error))
      return
    }
    let url = video.video.cdnUrl.flatMap(URL.init(string:))
    guard url != nil || nativeDownload != nil else {
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
    if joinRequest(id: downloadId, completion: completion) { return }
    let requestToken = registerRequest(id: downloadId, completion: completion)
    let completion: (Result<URL, Error>) -> Void = { [weak self] result in
      self?.finishRequest(id: downloadId, token: requestToken, result: result)
    }
    let fileExtension = "mp4"
    let localPath = "\(UUID().uuidString).\(fileExtension)"
    let localUrl = FileCache.getUrl(for: .videos, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: Int64(video.video.size ?? 0),
      accountToken: accountToken,
      messageLocation: Self.location(for: message),
      nativeDownload: nativeDownload,
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
                try await FileCache.shared.saveVideoDownload(
                  video: video, localPath: localPath, message: message, auth: self.auth, accountToken: accountToken
                )
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
    let accountToken: AuthAccountMutationToken
    do {
      accountToken = try auth.beginAccountMutation()
    } catch {
      completion(.failure(URLError(.cancelled)))
      return
    }
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
    if joinRequest(id: downloadId, completion: completion) { return }
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

    let requestToken = registerRequest(id: downloadId, completion: completion)
    let completion: (Result<URL, Error>) -> Void = { [weak self] result in
      self?.finishRequest(id: downloadId, token: requestToken, result: result)
    }
    let localPath = "\(UUID().uuidString).\(fileExtension)"
    let localUrl = FileCache.getUrl(for: .voices, localPath: localPath)

    downloadFile(
      id: downloadId,
      url: url,
      localUrl: localUrl,
      expectedBytes: voice.size,
      accountToken: accountToken,
      completion: { [weak self] token, result in
        guard let self else { return }

        switch result {
        case let .success(fileURL):
          self.startFinalization(id: downloadId, token: token) { [weak self] in
            guard let self else { return }
            do {
              try Task.checkCancellation()
              try self.ensureActiveDownload(id: downloadId, token: token)
              try await FileCache.shared.saveVoiceDownload(
                message: message, localPath: localPath, auth: self.auth, accountToken: accountToken
              )
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
  public func resetSession(accountID: Int64? = nil) async {
    if let accountID { knownAccountIDs.insert(accountID) }
    if let sessionResetTask {
      await sessionResetTask.value
      if let accountID {
        knownAccountIDs.remove(accountID)
        await nativeManager.stopAll(accountID: accountID, cacheDirectories: nativeCacheDirectories)
      }
      return
    }

    transferGeneration &+= 1
    let cancellation = URLError(.cancelled)
    let completions = Array(downloadCompletions.values)
    let finalizations = finalizationTasks.values.map(\.task)
    let nativeTransfers = Array(nativeTasks.values)
    let cancellations = Array(cancellationTasks.values)
    let joined = joinedCompletions
    let accountIDs = knownAccountIDs.union(accountTokens.values.map(\.userID))
    let manager = nativeManager
    let directories = nativeCacheDirectories
    let reset = Task {
      for task in cancellations { await task.value }
      for task in nativeTransfers {
        await task.value
      }
      for task in finalizations {
        await task.value
      }
      for id in accountIDs { await manager.stopAll(accountID: id, cacheDirectories: directories) }
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
    accountTokens.removeAll()
    downloadLocations.removeAll()
    knownAccountIDs.removeAll()
    cdnSources.removeAll()
    downloadCompletions.removeAll()
    joinedCompletions.removeAll()
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
    for (token, handlers) in joined {
      for handler in handlers { handler(token, .failure(cancellation)) }
    }
    // Queued restarts and finalizing requests also receive exactly one terminal
    // cancellation even if their old transport callback can no longer deliver.
    let requests = requestCompletions
    requestCompletions.removeAll()
    for request in requests.values {
      for handler in request.handlers { handler(.failure(cancellation)) }
    }

    await reset.value
    sessionResetTask = nil
  }

  /// Called only after the deletion transaction commits, with its captured account.
  public func discardMessageDownloads(accountToken: AuthAccountMutationToken, chatID: Int64,
                                      messageIDs: [Int64]) async {
    guard (try? auth.validateAccountMutation(accountToken)) != nil else { return }
    let ids = Set(messageIDs.filter { $0 > 0 })
    guard !ids.isEmpty else { return }
    let affected = activeDownloadTokens.filter { _, token in
      accountTokens[token]?.userID == accountToken.userID &&
        downloadLocations[token].map { $0.chatID == chatID && ids.contains($0.messageID) } == true
    }
    let transfers = affected.values.compactMap { nativeTasks[$0] }
    let publications = affected.keys.compactMap { finalizationTasks[$0]?.task }
    for id in affected.keys { cancelDownload(id: id, includingFinalization: true) }
    for task in transfers { await task.value }
    for task in publications { await task.value }
    for messageID in ids {
      let location = FileMessageLocation.with { $0.chatID = chatID; $0.messageID = messageID }
      await nativeManager.discard(message: location, accountID: accountToken.userID,
                                  cacheDirectories: nativeCacheDirectories)
    }
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
    if sessionResetTask != nil || cacheMaintenanceDepth > 0 {
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

  private func joinRequest(id: String, completion: @escaping (Result<URL, Error>) -> Void) -> Bool {
    guard var request = requestCompletions[id] else { return false }
    request.handlers.append(completion)
    requestCompletions[id] = request
    return true
  }

  private func registerRequest(id: String, completion: @escaping (Result<URL, Error>) -> Void) -> UUID {
    let token = UUID()
    requestCompletions[id] = RequestCompletions(token: token, handlers: [completion])
    return token
  }

  private func finishRequest(id: String, token: UUID, result: Result<URL, Error>) {
    guard requestCompletions[id]?.token == token else { return }
    let handlers = requestCompletions.removeValue(forKey: id)?.handlers ?? []
    if downloadCompletions[id] == nil, let transferToken = activeDownloadTokens[id] {
      activeDownloadTokens[id] = nil
      if finalizationTasks[id]?.token == transferToken { finalizationTasks[id] = nil }
      accountTokens[transferToken] = nil
      downloadLocations[transferToken] = nil
    }
    for handler in handlers { handler(result) }
  }

  private static func location(for message: Message) -> FileMessageLocation {
    .with { $0.chatID = message.chatId; $0.messageID = message.messageId }
  }

  private func cancelDownload(id: String, includingFinalization: Bool = false) {
    // Once publication has begun its single cache commit decides the result.
    guard includingFinalization || finalizationTasks[id] == nil,
          let token = activeDownloadTokens[id] else { return }
    if includingFinalization { finalizationTasks[id]?.task.cancel() }
    let native = nativeTasks[token]
    let cdn = activeTasks.removeValue(forKey: id)
    let callbacks = downloadCompletions.removeValue(forKey: id)
    cdnSources[token] = nil
    let joined = joinedCompletions.removeValue(forKey: token) ?? []
    activeDownloadTokens[id] = nil
    accountTokens[token] = nil
    downloadLocations[token] = nil
    native?.cancel()
    // Install the barrier before notifying observers: a start triggered by the
    // cancellation completion must wait for native I/O to relinquish ownership.
    cdn?.cancel()
    let barrier = Task { [weak self] in
      await native?.value
      self?.cancellationTasks[id] = nil
    }
    cancellationTasks[id] = barrier
    clearRetainedProgress(id: id)
    callbacks?.handler(.failure(URLError(.cancelled)))
    for callback in joined { callback(token, .failure(URLError(.cancelled))) }
    if includingFinalization, let request = requestCompletions[id] {
      finishRequest(id: id, token: request.token, result: .failure(URLError(.cancelled)))
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
    accountToken: AuthAccountMutationToken? = nil,
    messageLocation: FileMessageLocation? = nil,
    nativeDownload: NativeDownloadOperation? = nil,
    completion: @escaping (UUID, Result<URL, Error>) -> Void
  ) {
    let token = UUID()
    guard sessionResetTask == nil, cacheMaintenanceDepth == 0 else {
      completion(token, .failure(URLError(.cancelled)))
      return
    }
    if let barrier = cancellationTasks[id] {
      let generation = transferGeneration
      Task { [weak self] in
        await barrier.value
        guard let self else { return }
        guard self.transferGeneration == generation else {
          completion(token, .failure(URLError(.cancelled)))
          return
        }
        if let accountToken, (try? self.auth.validateAccountMutation(accountToken)) == nil {
          completion(token, .failure(URLError(.cancelled)))
          return
        }
        self.downloadFile(id: id, url: url, localUrl: localUrl, expectedBytes: expectedBytes,
                          accountToken: accountToken, messageLocation: messageLocation,
                          nativeDownload: nativeDownload, completion: completion)
      }
      return
    }
    if let activeToken = activeDownloadTokens[id] {
      joinedCompletions[activeToken, default: []].append(completion)
      return
    }
    prepareForActiveDownload(id: id)
    activeDownloadTokens[id] = token
    accountTokens[token] = accountToken
    downloadLocations[token] = messageLocation
    if let accountToken { knownAccountIDs.insert(accountToken.userID) }
    downloadCompletions[id] = DownloadCompletion(token: token) { result in completion(token, result) }
    if let nativeDownload {
      startNativeDownload(id: id, token: token, url: url, localUrl: localUrl,
                          expectedBytes: expectedBytes, operation: nativeDownload)
    } else if let url {
      startCDNDownload(id: id, token: token, url: url, localUrl: localUrl, expectedBytes: expectedBytes)
    } else {
      finishTransfer(id: id, token: token, result: .failure(URLError(.badURL)))
    }
    // Ownership is installed before an observer can synchronously cancel.
    if activeDownloadTokens[id] == token {
      publishProgress(.transferring(id: id, bytesReceived: 0, totalBytes: expectedBytes))
    }
  }

  private func startCDNDownload(id: String, token: UUID, url: URL, localUrl: URL, expectedBytes: Int64) {
    guard isActiveDownload(id: id, token: token) else {
      finishTransfer(id: id, token: token, result: .failure(URLError(.cancelled)))
      return
    }
    let task = session.downloadTask(with: url)
    task.taskDescription = id
    activeTasks[id] = task
    cdnSources[token] = CDNSource(localURL: localUrl, expectedBytes: expectedBytes)
    task.resume()
  }

  private struct CDNSource {
    let localURL: URL
    let expectedBytes: Int64
  }
  private var cdnSources: [UUID: CDNSource] = [:]

  private func startNativeDownload(
    id: String, token: UUID, url: URL?, localUrl: URL, expectedBytes: Int64,
    operation: @escaping NativeDownloadOperation
  ) {
    let throttler = progressThrottler
    nativeTasks[token] = Task { [weak self] in
      guard let self else { return }
      defer { self.nativeTasks[token] = nil }
      do {
        try Task.checkCancellation()
        let sharedFile = try await operation(localUrl) { [weak self] received, total in
          guard throttler.shouldPublish(id: id) else { return }
          Task { @MainActor [weak self] in
            guard let self, self.isActiveDownload(id: id, token: token), self.nativeTasks[token] != nil else { return }
            self.publishProgress(.transferring(id: id, bytesReceived: received, totalBytes: total))
          }
        }
        var file = sharedFile
        var ownsFile = sharedFile == localUrl
        do {
          try Task.checkCancellation()
          try self.ensureActiveDownload(id: id, token: token)
          if sharedFile != localUrl {
            // Duplicate native identities can originate in different local rows.
            // Give each cache owner a no-overwrite link without copying 500 MB.
            try FileManager.default.linkItem(at: sharedFile, to: localUrl)
            file = localUrl
            ownsFile = true
          }
          try DownloadedFileValidation.validateDocumentFile(at: file, expectedByteCount: expectedBytes)
        } catch {
          if ownsFile { try? FileManager.default.removeItem(at: file) }
          throw error
        }
        self.nativeTasks[token] = nil
        self.finishTransfer(id: id, token: token, result: .success(file))
      } catch {
        guard self.activeDownloadTokens[id] == token else { return }
        // The operation has returned only after its child ranges and file handle
        // have settled. Relinquish native ownership before admitting CDN fallback.
        self.nativeTasks[token] = nil
        if !Task.isCancelled, self.isActiveDownload(id: id, token: token), !Self.isCancellation(error), !NativeMessageFileDownload.isPermissionFailure(error), let url {
          self.log.warning(Self.nativeFallbackLog(error))
          self.startCDNDownload(id: id, token: token, url: url, localUrl: localUrl, expectedBytes: expectedBytes)
        } else {
          self.finishTransfer(id: id, token: token, result: .failure(
            self.isActiveDownload(id: id, token: token) ? error : URLError(.cancelled)
          ))
        }
      }
    }
  }

  private static func nativeFallbackLog(_ error: any Error) -> String {
    if let rpc = error as? RealtimeDirectRpcError {
      switch rpc {
      case let .rpcError(code, _, status):
        return "native_fallback class=rpc status=\(status) code=\(code.rawValue)"
      case .notConnected: return "native_fallback class=rpc_disconnected"
      case .timeout: return "native_fallback class=rpc_timeout"
      case .commitOutcomeUnknown: return "native_fallback class=rpc_outcome_unknown"
      case .capacityExceeded: return "native_fallback class=rpc_capacity"
      case .notAuthorized: return "native_fallback class=rpc_unauthorized"
      case .unknown: return "native_fallback class=rpc_unknown"
      }
    }
    if let network = error as? URLError { return "native_fallback class=network code=\(network.code.rawValue)" }
    if let filesystem = error as? POSIXError { return "native_fallback class=filesystem code=\(filesystem.code.rawValue)" }
    if error is NativeFileDownloadError { return "native_fallback class=native" }
    if error is FileDownloadValidationError { return "native_fallback class=validation" }
    return "native_fallback class=other"
  }

  private var downloadCompletions: [String: DownloadCompletion] = [:]

  private func finishTransfer(id: String, token: UUID, result: Result<URL, Error>) {
    guard activeDownloadTokens[id] == token else {
      if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
      return
    }
    let completion = downloadCompletions.removeValue(forKey: id)
    let joined = joinedCompletions.removeValue(forKey: token) ?? []
    activeTasks[id] = nil
    cdnSources[token] = nil
    if case let .failure(error) = result { failDownload(id: id, token: token, error: error) }
    completion?.handler(result)
    for handler in joined { handler(token, result) }
    if activeDownloadTokens[id] == token, finalizationTasks[id]?.token != token {
      activeDownloadTokens[id] = nil
      accountTokens[token] = nil
      downloadLocations[token] = nil
    }
  }

  private func updateProgress(
    id: String,
    task: URLSessionTask,
    bytesReceived: Int64,
    totalBytes: Int64
  ) {
    guard let activeTask = activeTasks[id], activeTask === task,
          let token = activeDownloadTokens[id], isActiveDownload(id: id, token: token) else { return }
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

    guard let token = activeDownloadTokens[id], let source = cdnSources[token] else { return }
    if !isActiveDownload(id: id, token: token) {
      if let location { try? FileManager.default.removeItem(at: location) }
      finishTransfer(id: id, token: token, result: .failure(URLError(.cancelled)))
      return
    }
    if let error {
      finishTransfer(id: id, token: token, result: .failure(error))
    } else if let location {
      do {
        if let mismatch = try DownloadedFileValidation.validateCDNFile(
          at: location, expectedByteCount: source.expectedBytes
        ) {
          log.warning("CDN file size mismatch for \(id): \(mismatch); accepting legacy object")
        }
        try FileManager.default.moveItem(at: location, to: source.localURL)
        finishTransfer(id: id, token: token, result: .success(source.localURL))
      } catch {
        try? FileManager.default.removeItem(at: location)
        finishTransfer(id: id, token: token, result: .failure(error))
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
      accountTokens[token] = nil
      downloadLocations[token] = nil
    }
  }

  private func isActiveDownload(id: String, token: UUID) -> Bool {
    guard activeDownloadTokens[id] == token else { return false }
    if let account = accountTokens[token] { return (try? auth.validateAccountMutation(account)) != nil }
    return true
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

  public nonisolated static func isCancellation(_ error: Error) -> Bool {
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
      try DownloadedFileValidation.validateHTTPResponse(downloadTask.response)
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
        self.log.error("Error validating or copying downloaded file", error: downloadError)
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
