import AnimatedMedia
import Auth
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
  public static let shared = FileCache(nativePhotoLoader: FileCache.nativePhotoDownload)

  typealias PhotoDataLoader = @Sendable (URL) async throws -> (Data, URLResponse)
  /// Downloads one stored photo size natively into `destination`, authorized by its message.
  /// Returns nil without trying when no account is signed in.
  typealias NativePhotoLoader = @Sendable (
    _ fileID: String, _ location: FileMessageLocation, _ destination: URL
  ) async throws -> URL?

  /// A photo falls back to its CDN link, which cannot resume a native partial, so native gets
  /// less time to stall than documents and videos do.
  static let nativePhotoStallBudget: Duration = .seconds(10)

  static let nativePhotoDownload: NativePhotoLoader = { fileID, location, destination in
    let auth = Auth.shared.handle
    // Signed out there is no account to authorize the ranges; the CDN link is all there is.
    guard (try? auth.beginAccountMutation()) != nil else { return nil }
    return try await NativeMessageFileDownload(auth: auth).download(
      fileID: fileID, location: location, to: destination, stallBudget: nativePhotoStallBudget
    )
  }

  private let database: AppDatabase
  private let photoDataLoader: PhotoDataLoader
  private let nativePhotoLoader: NativePhotoLoader?
  private let log = Log.scoped("FileCache")

  private var downloadingPhotos: [Int64: Task<URL?, Never>] = [:]
  private var downloadGenerations: [Int64: UUID] = [:]
  private var downloadSources: [Int64: PhotoDownloadSourceKey] = [:]
  private var recentFailures: [Int64: (source: PhotoDownloadSourceKey, until: Date)] = [:]
  private let linkRefresher: MediaLinkRefresher
  private var resetTask: Task<Void, Never>?
  // TODO: Create a message asset downloader middleware over the file cache which tracks messages and downloads, but for now we do it in this file directly
  var messagesToReload: [Int64: Set<Message>] = [:]

  init(
    database: AppDatabase = .shared,
    linkRefresher: MediaLinkRefresher = .shared,
    photoDataLoader: @escaping PhotoDataLoader = {
      try await URLSession.shared.data(from: $0)
    },
    nativePhotoLoader: NativePhotoLoader? = nil
  ) {
    self.database = database
    self.linkRefresher = linkRefresher
    self.photoDataLoader = photoDataLoader
    self.nativePhotoLoader = nativePhotoLoader
  }

  /// A different variant of the photo always replaces the running transfer. For the same
  /// variant, a re-signed link replaces it only when it expires later; links that carry no
  /// expiry keep the newest-wins behavior.
  static func shouldReplace(running: PhotoDownloadSourceKey, with incoming: PhotoDownloadSourceKey) -> Bool {
    guard running.photoID == incoming.photoID, running.sizeType == incoming.sizeType,
          running.format == incoming.format
    else { return true }
    guard let runningExpiry = MediaLinkExpiry.expiryDate(URL(string: running.cdnURL)),
          let incomingExpiry = MediaLinkExpiry.expiryDate(URL(string: incoming.cdnURL))
    else { return running.cdnURL != incoming.cdnURL }
    return incomingExpiry > runningExpiry
  }

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
    downloadSources[id] = nil
    messagesToReload[id] = nil
    log.debug("Released terminal photo download state for \(id)")
  }

  /// Cancel download for a specific photo
  public func cancelDownload(photoId: Int64) {
    if let task = downloadingPhotos[photoId] {
      task.cancel()
      // Keep the task until its cleanup finishes so a replacement can drain it.
    } else {
      downloadGenerations[photoId] = nil
    }
    downloadSources[photoId] = nil
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
    downloadSources.removeAll()
    recentFailures.removeAll()
    messagesToReload.removeAll()

    let reset = Task {
      for task in tasks {
        _ = await task.value
      }
    }
    resetTask = reset
    await reset.value
    resetTask = nil
  }

  /// Wait for a specific photo download to finish
  public func waitForDownload(photoId: Int64) async {
    _ = await downloadingPhotos[photoId]?.value
  }

  public func waitForDownload(photo: PhotoInfo) async {
    _ = await downloadingPhotos[Self.photoCacheID(photo)]?.value
  }

  /// Resolves the deterministic cache file used by `download(photo:)` without
  /// requiring a new message snapshot to project the persisted local path.
  public func cachedLocalURL(photo: PhotoInfo) -> URL? {
    Self.cachedLocalURL(photo: photo)
  }

  public func cachedLocalURLCandidates(photo: PhotoInfo) -> [URL] {
    Self.cachedLocalURLCandidates(photo: photo)
  }

  public static func cachedLocalURL(
    photo: PhotoInfo,
    fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
  ) -> URL? {
    bestLocalURLCandidates(photo: photo, fileExists: fileExists).first
  }

  /// Ordered, existing local files for one photo. The deterministic best-size
  /// download is considered before smaller explicit fallbacks, while unsafe or
  /// duplicate relative paths fail closed.
  public static func cachedLocalURLCandidates(
    photo: PhotoInfo,
    fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
  ) -> [URL] {
    guard photo.bestPhotoSize() != nil else { return [] }
    var result: [URL] = []
    var seen = Set<URL>()
    func append(_ url: URL) {
      guard seen.insert(url).inserted else { return }
      result.append(url)
    }
    bestLocalURLCandidates(photo: photo, fileExists: fileExists).forEach(append)

    let directory = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
    for size in photo.localPhotoSizeCandidates() {
      guard let localPath = size.localPath, !localPath.isEmpty else { continue }
      guard let url = localCacheURL(localPath: localPath, directory: directory), fileExists(url.path) else { continue }
      append(url)
    }
    return result
  }

  private static func bestLocalURLCandidates(
    photo: PhotoInfo,
    fileExists: (String) -> Bool
  ) -> [URL] {
    guard let size = photo.bestPhotoSize() else { return [] }
    let directory = FileHelpers.getLocalCacheDirectory(for: .photos, createIfNeeded: false)
    var result: [URL] = []
    var seen = Set<URL>()
    func append(_ localPath: String?) {
      guard let localPath, !localPath.isEmpty,
            let url = localCacheURL(localPath: localPath, directory: directory),
            fileExists(url.path), seen.insert(url).inserted
      else { return }
      result.append(url)
    }

    append(size.localPath)
    append(photoLocalPath(photo))
    // Legacy filenames used local row IDs. Only an explicit persisted path
    // proves their ownership; inferring either ID can display another photo.
    return result
  }

  private static func photoCacheID(_ photo: PhotoInfo) -> Int64 {
    photo.photo.photoId
  }

  private static func photoLocalPath(_ photo: PhotoInfo) -> String {
    let sizeType = (photo.bestPhotoSize()?.type ?? "").addingPercentEncoding(
      withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    ) ?? ""
    return "IMG-server-" + String(photoCacheID(photo)) + "-" + sizeType + photo.photo.format.toExt()
  }

  /// Rich block projections may carry protocol/server IDs in their detached
  /// `PhotoSize` values. Persist onto the existing local row instead of saving
  /// that detached value, because `PhotoSize.photoId` is a local foreign key.
  static func persistDownloadedPhotoPath(_ localPath: String, for photo: PhotoInfo, in db: Database) throws {
    guard let selectedSize = photo.bestPhotoSize() else { throw FileCacheError.failedToSave }
    guard let localPhotoID = try Photo.filter(Photo.Columns.photoId == photo.photo.photoId).fetchOne(db)?.id
    else { throw FileCacheError.failedToSave }
    let updated = try PhotoSize
      .filter(PhotoSize.Columns.photoId == localPhotoID)
      .filter(PhotoSize.Columns.type == selectedSize.type)
      .updateAll(db, [PhotoSize.Columns.localPath.set(to: localPath)])
    guard updated > 0 else { throw FileCacheError.failedToSave }
  }

  // MARK: -  Fetches

  public static func getUrl(for dir: FileLocalCacheDirectory, localPath: String) -> URL {
    let directory = FileHelpers.getLocalCacheDirectory(for: dir)
    return directory.appendingPathComponent(localPath)
  }

  // MARK: -  Remote downloads

  public func download(photo: PhotoInfo, reloadMessageOnFinish: Message? = nil) async {
    _ = startDownload(photo: photo, reloadMessageOnFinish: reloadMessageOnFinish)
  }

  /// Returns only the file successfully persisted by this exact transfer.
  /// Looking up a task by photo ID after awaiting can join a newer source.
  public func downloadAndWait(photo: PhotoInfo, reloadMessageOnFinish: Message? = nil) async -> URL? {
    guard let task = startDownload(photo: photo, reloadMessageOnFinish: reloadMessageOnFinish) else { return nil }
    return await task.value
  }

  private func startDownload(photo: PhotoInfo, reloadMessageOnFinish: Message?) -> Task<URL?, Never>? {
    guard resetTask == nil else { return nil }
    let photoID = Self.photoCacheID(photo)

    // Validate the remote location before retaining a message for a future reload.
    guard let source = photo.downloadSourceKey(),
          let remoteURL = URL(string: source.cdnURL)
    else {
      log.warning("No valid remote URL found for photo")
      return nil
    }

    // Register the message for reloading if provided
    if let message = reloadMessageOnFinish {
      if messagesToReload[photoID] == nil {
        messagesToReload[photoID] = Set<Message>()
      }
      messagesToReload[photoID]?.insert(message)
      log.debug("Registered message \(message.id) for reload when photo \(photoID) downloads")
    }

    // A photo that just failed is not retried until its link changes or the cooldown ends.
    if let failure = recentFailures[photoID] {
      if failure.until > Date(), failure.source == source { return nil }
      recentFailures[photoID] = nil
    }

    let previousTask = downloadingPhotos[photoID]
    if previousTask != nil, let running = downloadSources[photoID],
       running == source || !Self.shouldReplace(running: running, with: source)
    {
      // Same file with an older or equal link: views holding a stale snapshot join the
      // running transfer instead of cancelling it.
      log.debug("Photo \(photoID) is already being downloaded")
      return previousTask
    }
    previousTask?.cancel()

    log.debug("downloading photo \(photoID) for message \(reloadMessageOnFinish?.id ?? 0)")

    let generation = UUID()
    downloadGenerations[photoID] = generation
    downloadSources[photoID] = source
    let task = Task<URL?, Never> {
      // A superseded transfer may be awaiting persistence with file cleanup
      // still pending. Drain it before replacing the same canonical file.
      _ = await previousTask?.value
      guard !Task.isCancelled, downloadGenerations[photoID] == generation else {
        finishDownload(photoID, generation: generation)
        return nil
      }
      return await downloadWithRetries(
        photo: photo,
        photoID: photoID,
        remoteURL: remoteURL,
        reloadMessage: reloadMessageOnFinish,
        generation: generation
      )
    }
    downloadingPhotos[photoID] = task
    return task
  }

  /// Network errors, 408, 429 and 5xx get this many attempts. Other client errors stop at once.
  static let maxTransientAttempts = 4
  /// A photo whose link was rejected or is missing is not retried for this long unless its
  /// link changes, so a view that keeps reappearing cannot restart the whole cycle each time.
  static let terminalFailureCooldown: TimeInterval = 5 * 60
  /// After transient failures run out (for example while offline), wait briefly instead.
  static let transientFailureCooldown: TimeInterval = 30

  private enum AttemptFailure: Error {
    case http(status: Int, retryAfter: TimeInterval?)
    case empty
  }

  private enum FailureClass: Equatable {
    case transient(retryAfter: TimeInterval?)
    case linkRejected(status: Int)
    case notFound
    case permanent
  }

  private static func classify(_ error: Error) -> FailureClass {
    if let failure = error as? AttemptFailure {
      switch failure {
        case .empty:
          return .transient(retryAfter: nil)
        case let .http(status, retryAfter):
          if MediaLinkExpiry.isLinkRejection(statusCode: status) { return .linkRejected(status: status) }
          if status == 404 { return .notFound }
          if status == 408 || status == 429 || (500 ... 599).contains(status) {
            return .transient(retryAfter: retryAfter)
          }
          return .permanent
      }
    }
    if let urlError = error as? URLError {
      switch urlError.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .cannotFindHost, .dnsLookupFailed, .badServerResponse, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
          return .transient(retryAfter: nil)
        default:
          return .permanent
      }
    }
    return .permanent
  }

  /// 1, 2, 4, 8 … seconds with ±20% jitter, capped at 30.
  static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
    let base = min(30, pow(2, Double(max(0, attempt - 1))))
    return base * Double.random(in: 0.8 ... 1.2)
  }

  private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After"),
          let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
    else { return nil }
    return min(seconds, 60)
  }

  private func recordFailure(_ photoID: Int64, cooldown: TimeInterval) {
    guard let source = downloadSources[photoID] else { return }
    recentFailures[photoID] = (source, Date().addingTimeInterval(cooldown))
  }

  /// Re-fetches the photo's message and returns the photo again if a newer link arrived. A
  /// fetch that did not run, because one ran within the last minute, may still have stored a
  /// newer link: the photo is read either way, and its link used if it has not expired.
  private func refreshedPhoto(
    photoID: Int64,
    reloadMessage: Message?,
    staleURL: URL
  ) async -> (photo: PhotoInfo, url: URL, source: PhotoDownloadSourceKey)? {
    let database = database
    let owner: (peer: Peer, messageId: Int64)?
    if let reloadMessage, reloadMessage.photoId == photoID, reloadMessage.messageId > 0 {
      owner = (reloadMessage.peerId, reloadMessage.messageId)
    } else {
      owner = try? await database.dbWriter.read { db in
        try Message
          .filter(Message.Columns.photoId == photoID)
          .filter(Message.Columns.messageId > 0)
          .order(Message.Columns.date.desc)
          .fetchOne(db)
          .map { ($0.peerId, $0.messageId) }
      }
    }
    guard let owner else { return nil }
    let refreshed = await linkRefresher.refresh(peer: owner.peer, messageId: owner.messageId)
    let fresh = try? await database.dbWriter.read { db in
      try Photo
        .filter(Photo.Columns.photoId == photoID)
        .including(all: Photo.sizes.forKey(PhotoInfo.CodingKeys.sizes))
        .asRequest(of: PhotoInfo.self)
        .fetchOne(db)
    }
    guard let fresh, let source = fresh.downloadSourceKey(),
          let url = URL(string: source.cdnURL), url != staleURL,
          refreshed || !MediaLinkExpiry.isExpired(url)
    else { return nil }
    return (fresh, url, source)
  }

  private func downloadWithRetries(
    photo: PhotoInfo,
    photoID: Int64,
    remoteURL initialURL: URL,
    reloadMessage: Message?,
    generation: UUID
  ) async -> URL? {
    let startedAt = Date()
    var attempt = 0
    var outcome = DownloadTelemetry.Outcome.canceled
    var transport = DownloadTelemetry.Transport.cdn
    var afterFallback = false
    var current = photo
    var remoteURL = initialURL
    var refreshedLink = false
    let expectedBytes = Int64(photo.bestPhotoSize()?.size ?? 0)
    defer {
      finishDownload(photoID, generation: generation)
      DownloadTelemetry.record(
        outcome, transport: transport, downloadID: "photo_\(photoID)", expectedBytes: expectedBytes,
        startedAt: startedAt, attempts: transport == .cdn ? attempt : nil, afterFallback: afterFallback
      )
    }

    // Native first when this size has a server identity and the message that owns this photo
    // can authorize it (a reply preview passes its parent message, which does not). It needs no
    // link, so expiry and re-signing do not apply. Any failure falls back to the CDN below: the
    // signed link is its own authority, so a native refusal never blocks the photo.
    if let nativePhotoLoader, let size = current.bestPhotoSize(), let fileID = size.fileUniqueId,
       let reloadMessage, reloadMessage.photoId == photoID, reloadMessage.messageId > 0, reloadMessage.chatId > 0
    {
      var location = FileMessageLocation()
      location.chatID = reloadMessage.chatId
      location.messageID = reloadMessage.messageId
      let staging = FileCache.getUrl(for: .photos, localPath: ".native-\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
      do {
        if let file = try await nativePhotoLoader(fileID, location, staging) {
          defer { try? FileManager.default.removeItem(at: file) }
          let data = try Data(contentsOf: file)
          guard !data.isEmpty else { throw AttemptFailure.empty }
          transport = .native
          guard let url = try await persistPhoto(data, photo: current, photoID: photoID, generation: generation) else { return nil }
          outcome = .success
          return url
        }
      } catch {
        try? FileManager.default.removeItem(at: staging)
        if Self.isCancellation(error) || Task.isCancelled || downloadGenerations[photoID] != generation {
          transport = .native
          return nil
        }
        log.warning("Native photo \(photoID) download failed; using the CDN")
        DownloadTelemetry.record(
          .fallback(DownloadTelemetry.errorClass(error)), transport: .native, downloadID: "photo_\(photoID)",
          expectedBytes: expectedBytes, startedAt: startedAt
        )
        afterFallback = true
      }
    }

    while true {
      guard !Task.isCancelled, downloadGenerations[photoID] == generation else { return nil }

      // An expired link cannot succeed; get a fresh one before spending a request on it.
      if !refreshedLink, MediaLinkExpiry.isExpired(remoteURL) {
        refreshedLink = true
        if let fresh = await refreshedPhoto(photoID: photoID, reloadMessage: reloadMessage, staleURL: remoteURL) {
          guard downloadGenerations[photoID] == generation else { return nil }
          current = fresh.photo
          remoteURL = fresh.url
          downloadSources[photoID] = fresh.source
          log.debug("Refreshed expired link for photo \(photoID) before downloading")
        }
        continue
      }

      attempt += 1
      do {
        log.debug("Downloading photo \(photoID), attempt \(attempt)")
        let (data, response) = try await photoDataLoader(remoteURL)
        if let httpResponse = response as? HTTPURLResponse, !(200 ... 299).contains(httpResponse.statusCode) {
          throw AttemptFailure.http(status: httpResponse.statusCode, retryAfter: Self.retryAfter(httpResponse))
        }
        guard !data.isEmpty else { throw AttemptFailure.empty }

        guard let localUrl = try await persistPhoto(data, photo: current, photoID: photoID, generation: generation) else {
          return nil
        }
        outcome = .success
        return localUrl
      } catch {
        if Self.isCancellation(error) || Task.isCancelled { return nil }
        guard downloadGenerations[photoID] == generation else { return nil }

        switch Self.classify(error) {
          case let .linkRejected(status):
            if !refreshedLink {
              refreshedLink = true
              if let fresh = await refreshedPhoto(photoID: photoID, reloadMessage: reloadMessage, staleURL: remoteURL) {
                guard downloadGenerations[photoID] == generation else { return nil }
                current = fresh.photo
                remoteURL = fresh.url
                downloadSources[photoID] = fresh.source
                log.debug("Photo \(photoID) link was rejected (HTTP \(status)); retrying with a fresh link")
                continue
              }
            }
            log.warning("Photo \(photoID) link was rejected (HTTP \(status)) and no fresher link is available")
            outcome = .failed(.init(name: "http", code: status))
            recordFailure(photoID, cooldown: Self.terminalFailureCooldown)
            return nil

          case .notFound:
            log.warning("Photo \(photoID) not found (404); not retrying")
            outcome = .notFound
            recordFailure(photoID, cooldown: Self.terminalFailureCooldown)
            return nil

          case .permanent:
            log.error("Photo \(photoID) download failed", error: error)
            outcome = .failed(Self.telemetryClass(error))
            recordFailure(photoID, cooldown: Self.terminalFailureCooldown)
            return nil

          case let .transient(retryAfter):
            guard attempt < Self.maxTransientAttempts else {
              log.error("Failed to download photo \(photoID) after \(attempt) attempts", error: error)
              outcome = .failed(Self.telemetryClass(error))
              recordFailure(photoID, cooldown: Self.transientFailureCooldown)
              return nil
            }
            let delay = retryAfter ?? Self.retryDelay(afterAttempt: attempt)
            log.debug("Retrying photo \(photoID) in \(delay) seconds")
            try? await Task.sleep(for: .seconds(delay))
        }
      }
    }
  }

  /// Writes a downloaded photo to its cache file, records it, and reloads the messages showing
  /// it. Nil when this transfer was superseded or canceled.
  private func persistPhoto(_ data: Data, photo current: PhotoInfo, photoID: Int64, generation: UUID) async throws -> URL? {
    try Task.checkCancellation()
    guard downloadGenerations[photoID] == generation else { return nil }

    let localPath = Self.photoLocalPath(current)
    let localUrl = FileCache.getUrl(for: .photos, localPath: localPath)
    let createdLocalFile = !FileManager.default.fileExists(atPath: localUrl.path)
    var shouldRemoveLocalFile = createdLocalFile
    defer {
      if shouldRemoveLocalFile {
        try? FileManager.default.removeItem(at: localUrl)
      }
    }

    let directory = localUrl.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: localUrl, options: .atomic)

    try Task.checkCancellation()
    guard downloadGenerations[photoID] == generation else { return nil }
    let persisted = current
    try await database.dbWriter.write { db in
      try Self.persistDownloadedPhotoPath(localPath, for: persisted, in: db)
    }
    // Once persistence commits, the cache file is referenced state even if
    // cancellation wins before the UI reload notification.
    shouldRemoveLocalFile = false
    recentFailures[photoID] = nil
    guard downloadGenerations[photoID] == generation else { return nil }
    log.debug("Saved downloaded photo \(photoID) (\(data.count) bytes)")

    await reloadAllMessagesForPhoto(photoID, generation: generation)
    guard !Task.isCancelled, downloadGenerations[photoID] == generation else { return nil }
    return localUrl
  }

  private static func telemetryClass(_ error: Error) -> DownloadTelemetry.ErrorClass {
    switch error as? AttemptFailure {
      case let .http(status, _)?: .init(name: "http", code: status)
      case .empty?: .init(name: "empty", code: nil)
      case nil: DownloadTelemetry.errorClass(error)
    }
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  private func triggerMessageReload(message: Message) async {
    await MessagesPublisher.shared
      .messageUpdated(message: message, peer: message.peerId, animated: true)
  }

  private func reloadAllMessagesForPhoto(_ photoId: Int64, generation: UUID) async {
    var notified = Set<Message>()
    while !Task.isCancelled, downloadGenerations[photoId] == generation {
      guard let message = messagesToReload[photoId]?.popFirst() else { return }
      guard notified.insert(message).inserted else { continue }
      // Publication suspends this actor. Leave unprocessed registrations in
      // the queue so a replacement source inherits them if it arrives here.
      await MessagesPublisher.shared
        .messageUpdated(message: message, peer: message.peerId, animated: true)
    }
  }

  func retainedReloadMessageCount(photoId: Int64) -> Int {
    messagesToReload[photoId]?.count ?? 0
  }

  // MARK: - Download Helpers

  /// Save a downloaded document to the cache and update the database
  public func saveDocumentDownload(
    document: DocumentInfo, localPath: String, message: Message? = nil,
    auth: AuthHandle? = nil, accountToken: AuthAccountMutationToken? = nil
  ) async throws {
    try await database.dbWriter.write { db in
      if let auth, let accountToken { try auth.validateAccountMutation(accountToken) }
      let updated = try Document.filter(id: document.id)
        .updateAll(db, [Document.Columns.localPath.set(to: localPath)])
      guard updated == 1 else { throw FileCacheError.failedToSave }
      self.log.debug("Updated document \(document.id) with local path \(localPath)")
    }

    if let auth, let accountToken, (try? auth.validateAccountMutation(accountToken)) == nil { return }
    if let message {
      await triggerMessageReload(message: message)
    }
  }

  /// Save a downloaded video to the cache and update the database
  public func saveVideoDownload(
    video: VideoInfo, localPath: String, message: Message,
    auth: AuthHandle? = nil, accountToken: AuthAccountMutationToken? = nil
  ) async throws {
    try await database.dbWriter.write { db in
      if let auth, let accountToken { try auth.validateAccountMutation(accountToken) }
      let updated = try Video.filter(id: video.id)
        .updateAll(db, [Video.Columns.localPath.set(to: localPath)])
      guard updated == 1 else { throw FileCacheError.failedToSave }
      self.log.debug("Updated video \(video.id) with local path \(localPath)")
    }

    if let auth, let accountToken, (try? auth.validateAccountMutation(accountToken)) == nil { return }
    await triggerMessageReload(message: message)
  }

  /// Save a downloaded voice message to the cache and update the message payload.
  public func saveVoiceDownload(
    message: Message, localPath: String,
    auth: AuthHandle? = nil, accountToken: AuthAccountMutationToken? = nil
  ) async throws {
    try await database.dbWriter.write { db in
      if let auth, let accountToken { try auth.validateAccountMutation(accountToken) }
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

    if let auth, let accountToken, (try? auth.validateAccountMutation(accountToken)) == nil { return }
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

  /// Media saved here is about to be sent: open the upload connection while the person finishes
  /// the message, so the upload doesn't start with a handshake.
  private static func prewarmUploadConnection() {
    guard Auth.shared.handle.isLoggedIn() else { return }
    DurableUploadCoordinator.shared.prewarmTransport()
  }

  /// Prepares a photo the way it is sent (resized for its content, upright, no metadata; see
  /// `MediaSendPreparation`) and stores the result as a local photo. The stored file is the exact
  /// body that is later staged, hashed and uploaded. Does decode and disk work: call off the main thread.
  public static func savePreparedPhoto(
    _ source: MediaSendPreparation.PhotoSource,
    content: MediaSendPreparation.PhotoContent? = nil,
    target: MediaSendPreparation.PhotoTarget? = nil
  ) throws -> InlineKit.PhotoInfo {
    prewarmUploadConnection()
    let prepared = try MediaSendPreparation.preparePhoto(source, content: content, target: target)
    let localPath = UUID().uuidString + prepared.format.toExt()
    let fileURL = FileHelpers.getLocalCacheDirectory(for: .photos).appendingPathComponent(localPath)
    try prepared.data.write(to: fileURL, options: .atomic)
    do {
      return try AppDatabase.shared.dbWriter.write { db in
        try Photo.createLocalPhoto(
          db,
          format: prepared.format,
          localPath: localPath,
          fileSize: prepared.data.count,
          width: prepared.width,
          height: prepared.height
        )
      }
    } catch {
      try? removeLocalCacheFile(fileURL)
      throw error
    }
  }

  /// Stores a decoded image as a local photo, prepared like any sent photo. Prefer
  /// `savePreparedPhoto(.file(_:))` when the encoded source exists: it reads the camera
  /// details that pick the size and never decodes more pixels than it sends.
  public static func savePhoto(
    image: PlatformImage,
    content: MediaSendPreparation.PhotoContent? = nil,
    target: MediaSendPreparation.PhotoTarget? = nil
  ) throws -> InlineKit.PhotoInfo {
    try savePreparedPhoto(.platformImage(image), content: content, target: target)
  }

  // Note: this does synchronous disk/thumbnail/DB work; avoid calling on MainActor for large assets.
  public static func saveVideo(url: URL, thumbnail: PlatformImage? = nil) async throws -> InlineKit.VideoInfo {
    prewarmUploadConnection()
    // Handle security scoped URL before any reads
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

    try MediaUploadLimits.validate(fileURL: url, kind: .video)

    let assetBox = PreparationAssetBox(AVURLAsset(url: url))
    let (width, height, durationSeconds, hasAudio) = try await TransferPreparation.withDeadline(
      seconds: 30, cancel: { assetBox.asset.cancelLoading() }
    ) {
      let asset = assetBox.asset
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
      let seconds = CMTimeGetSeconds(durationTime)
      guard durationTime.isValid, seconds.isFinite, seconds > 0, seconds < Double(Int.max) else {
        throw FileCacheError.failedToSave
      }
      let durationSeconds = Int(seconds.rounded())
      let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
      return (width, height, durationSeconds, audioTracks?.isEmpty == false)
    }
    let asset = assetBox.asset
    try Task.checkCancellation()

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
    var retained = false
    defer { if !retained { try? fileManager.removeItem(at: localUrl) } }
    let fileSize = FileHelpers.getFileSize(at: localUrl)

    // Generate or reuse thumbnail
    let thumbImage: PlatformImage? = if let thumbnail {
      thumbnail
    } else {
      try? await generateThumbnailImage(from: asset)
    }
    try Task.checkCancellation()

    let thumbnailInfo: PhotoInfo? = if let image = thumbImage {
      try? savePhoto(image: image, target: MediaSendPreparation.videoThumbnailTarget)
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
    retained = true

    return VideoInfo(video: video, photoInfo: thumbnailInfo)
  }

  public static func saveAnimatedImageAsVideo(
    url: URL,
    options: AnimatedImageVideoConversionOptions = .uploadDefault
  ) async throws -> InlineKit.VideoInfo {
    prewarmUploadConnection()
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
      try? savePhoto(image: thumbnail, target: MediaSendPreparation.videoThumbnailTarget)
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
    prewarmUploadConnection()
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

    try MediaUploadLimits.validate(fileURL: url, kind: .document)

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

  /// Removes a photo that was prepared locally and never sent (its file and rows).
  public static func discardLocalPhoto(_ photoInfo: PhotoInfo) async {
    let photoDirectory = FileHelpers.getLocalCacheDirectory(for: .photos)
    do {
      try await Task.detached(priority: .utility) {
        try discardLocalThumbnail(photoInfo, database: AppDatabase.shared, photoDirectory: photoDirectory)
      }.value
    } catch {
      Log.shared.error("Failed to discard unsent local photo", error: error)
    }
  }

  /// Removes a video that was copied locally and never sent (its file, thumbnail and rows).
  public static func discardLocalVideo(_ videoInfo: VideoInfo) async {
    let videoDirectory = FileHelpers.getLocalCacheDirectory(for: .videos)
    let photoDirectory = FileHelpers.getLocalCacheDirectory(for: .photos)
    do {
      try await Task.detached(priority: .utility) {
        guard videoInfo.video.videoId < 0 else { return }
        try AppDatabase.shared.dbWriter.write { db in
          _ = try Video.filter(Video.Columns.videoId == videoInfo.video.videoId).deleteAll(db)
        }
        if let thumbnail = videoInfo.thumbnail {
          try discardLocalThumbnail(thumbnail, database: AppDatabase.shared, photoDirectory: photoDirectory)
        }
        if let localPath = videoInfo.video.localPath,
           let fileURL = localCacheURL(localPath: localPath, directory: videoDirectory) {
          try removeLocalCacheFile(fileURL)
        }
      }.value
    } catch {
      Log.shared.error("Failed to discard unsent local video", error: error)
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
  let box = PreparationThumbnailBox(imageGenerator, asset: asset)
  let cgImage = try await TransferPreparation.withDeadline(seconds: 30, cancel: {
    box.asset.cancelLoading()
    box.generator.cancelAllCGImageGeneration()
  }) {
    let duration = try await box.asset.load(.duration)
    let time = CMTime(seconds: min(1.0, CMTimeGetSeconds(duration)), preferredTimescale: 600)
    return try await box.generator.image(at: time).image
  }

  #if os(iOS)
  return UIImage(cgImage: cgImage)
  #else
  return NSImage(cgImage: cgImage, size: .zero)
  #endif
}

private final class PreparationThumbnailBox: @unchecked Sendable {
  let generator: AVAssetImageGenerator
  let asset: AVAsset
  init(_ generator: AVAssetImageGenerator, asset: AVAsset) {
    self.generator = generator
    self.asset = asset
  }
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
    try await clearCache(downloadCoordinator: FileDownloader.shared)
  }

  func clearCache(downloadCoordinator: FileDownloader) async throws {
    // Keep selection closed across every suspension, including nested local resets.
    await MainActor.run { SharedAudioPlayer.shared.beginLocalDataMaintenance() }
    await downloadCoordinator.beginCacheMaintenance()
    log.debug("Clearing cache")
    do {
      try await clearPhotoCache()
      try await clearDocumentCache()
      try await clearVideoCache()
      try await clearVoiceCache()
    } catch {
      await MainActor.run {
        downloadCoordinator.endCacheMaintenance()
        SharedAudioPlayer.shared.endLocalDataMaintenance()
      }
      throw error
    }
    await MainActor.run {
      downloadCoordinator.endCacheMaintenance()
      SharedAudioPlayer.shared.endLocalDataMaintenance()
    }
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
        // Native partials and their sidecars are deleted only by the manager,
        // which respects a file owner in another process through flock.
        if fileURL.lastPathComponent.hasSuffix(".inline-partial") ||
            fileURL.lastPathComponent.hasSuffix(".inline-partial.json") { continue }
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
