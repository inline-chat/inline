import Auth
import CryptoKit
import Darwin
import Foundation
import InlineProtocol
import RealtimeV2

/// Implementations must honor task cancellation and the supplied RPC deadline.
public protocol NativeFilePartFetching: Sendable {
  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult
}

public enum NativeFileDownloadError: Error, LocalizedError, Sendable {
  case invalidRequest, invalidResponse, integrity, fileTooLarge, inaccessible
  public var errorDescription: String? {
    switch self {
    case .invalidRequest: "The file download request is invalid."
    case .invalidResponse: "The server returned an invalid file response."
    case .integrity: "The downloaded file failed its integrity check."
    case .fileTooLarge: "The file exceeds the download size limit."
    case .inaccessible: "The file is no longer available in this message."
    }
  }
}

private struct NativeDownloadRecord: Codable {
  let v: Int
  let accountID: Int64
  let fileUniqueID: String
  let totalSize: UInt64
  var chatID: Int64?
  var messageID: Int64?
}

/// One owner for native downloads: three files in FIFO order, two ranges each.
/// A slot remains owned until canceled requests and their staging handle drain.
public actor NativeDownloadManager {
  public static let shared = NativeDownloadManager()
  public struct Key: Hashable, Sendable {
    public let accountID: Int64
    public let fileUniqueID: String
    public init(accountID: Int64, fileUniqueID: String) {
      self.accountID = accountID; self.fileUniqueID = fileUniqueID
    }
  }
  public struct Request: Sendable {
    public let accountID: Int64
    public let fileUniqueID: String
    public let message: FileMessageLocation?
    public let destination: URL
    public let maximumByteCount: UInt64
    public let accountToken: AuthAccountMutationToken?
    public let validateAccount: @Sendable () throws -> Void
    public let transport: any NativeFilePartFetching
    var key: Key { Key(accountID: accountID, fileUniqueID: fileUniqueID) }
    public init(
      accountID: Int64, fileUniqueID: String, message: FileMessageLocation? = nil,
      destination: URL, maximumByteCount: UInt64 = 500_000_000,
      accountToken: AuthAccountMutationToken? = nil,
      validateAccount: @escaping @Sendable () throws -> Void = {},
      transport: any NativeFilePartFetching
    ) {
      self.accountID = accountID; self.fileUniqueID = fileUniqueID; self.message = message
      self.destination = destination; self.maximumByteCount = maximumByteCount
      self.accountToken = accountToken; self.validateAccount = validateAccount; self.transport = transport
    }
  }
  private struct Publication: Sendable {
    let destinations: [UUID: Result<URL, any Error>]
  }
  private struct Entry {
    let id: UUID
    let request: Request
    let task: Task<Publication, any Error>
    var destinations: [UUID: URL]
    var running = false
    var lastProgress = ContinuousClock.now
    var received: Int64 = 0
    var total: Int64 = 0
    var locations: [FileMessageLocation]
    var observers: [UUID: @Sendable (Int64, Int64) -> Void]
  }
  private struct Waiter {
    let key: Key
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }
  private var entries: [Key: Entry] = [:]
  private var waiters: [Waiter] = []
  private var activeFiles = 0
  private var stoppedAccounts: [Int64: Int] = [:]
  private var stoppedKeys: [Key: Int] = [:]
  private var knownDirectories: [Int64: Set<URL>] = [:]
  private let retryBudget: Duration
  private let retryBaseDelay: Duration
  public init() { retryBudget = .seconds(180); retryBaseDelay = .seconds(1) }
  init(retryBudget: Duration, retryBaseDelay: Duration = .seconds(1)) {
    self.retryBudget = retryBudget; self.retryBaseDelay = retryBaseDelay
  }

  public func download(
    _ request: Request, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
  ) async throws -> URL {
    try Self.validate(request)
    try Task.checkCancellation()
    try request.validateAccount()
    let key = request.key
    guard stoppedAccounts[key.accountID] == nil, stoppedKeys[key] == nil else { throw CancellationError() }
    if let existing = entries[key], existing.request.accountToken != request.accountToken {
      block(key)
      await drain(key)
      Self.removePartial(fileUniqueID: key.fileUniqueID, directory: existing.request.destination.deletingLastPathComponent(), accountID: key.accountID)
      unblock(key)
      try request.validateAccount()
      guard stoppedAccounts[key.accountID] == nil, stoppedKeys[key] == nil, entries[key] == nil else { throw CancellationError() }
    }
    let observerID = UUID()
    let task: Task<Publication, any Error>
    if var entry = entries[key] {
      entry.observers[observerID] = progress
      entry.destinations[observerID] = request.destination
      if let message = request.message, !entry.locations.contains(message) {
        entry.locations.append(message)
      }
      entries[key] = entry
      if entry.total > 0 { progress(entry.received, entry.total) }
      task = entry.task
    } else {
      let id = UUID()
      task = Task {
        do {
          try await self.acquire(key, id: id)
          let result = try await Self.materialize(request, owner: self, id: id)
          let publication = self.publishDestinations(result, key: key, id: id)
          self.finished(key, id: id)
          return publication
        } catch {
          self.finished(key, id: id)
          throw error
        }
      }
      entries[key] = Entry(id: id, request: request, task: task, destinations: [observerID: request.destination], locations: request.message.map { [$0] } ?? [], observers: [observerID: progress])
      if key.accountID > 0 { knownDirectories[key.accountID, default: []].insert(request.destination.deletingLastPathComponent()) }
    }
    defer {
      if var entry = entries[key] {
        entry.observers.removeValue(forKey: observerID); entry.destinations.removeValue(forKey: observerID)
        entries[key] = entry
      }
    }
    return try await withTaskCancellationHandler {
      // Successful atomic publication wins over a cancellation arriving later.
      let publication = try await task.value
      guard let destination = publication.destinations[observerID] else { throw NativeFileDownloadError.invalidResponse }
      let result = try destination.get()
      do { try request.validateAccount() }
      catch { try? FileManager.default.removeItem(at: result); throw error }
      return result
    } onCancel: {
      task.cancel()
    }
  }

  /// Give every attached cache owner its own path before any caller can remove
  /// the original result. No completed-file registry survives this shared task.
  private func publishDestinations(_ source: URL, key: Key, id: UUID) -> Publication {
    guard let entry = entries[key], entry.id == id else { return Publication(destinations: [:]) }
    var linked: [URL: Result<URL, any Error>] = [source: .success(source)]
    var destinations: [UUID: Result<URL, any Error>] = [:]
    for (observer, destination) in entry.destinations {
      if linked[destination] == nil {
        do {
          try FileManager.default.linkItem(at: source, to: destination)
          linked[destination] = .success(destination)
        } catch {
          linked[destination] = .failure(error)
        }
      }
      destinations[observer] = linked[destination]
    }
    return Publication(destinations: destinations)
  }

  public func stop(_ key: Key) async {
    block(key)
    defer { unblock(key) }
    await drain(key)
  }

  private func block(_ key: Key) { stoppedKeys[key, default: 0] += 1 }
  private func unblock(_ key: Key) {
    if stoppedKeys[key] == 1 { stoppedKeys[key] = nil }
    else { stoppedKeys[key, default: 1] -= 1 }
  }

  private func drain(_ key: Key) async {
    guard let entry = entries[key] else { return }
    entry.task.cancel()
    cancelQueued(key, id: entry.id)
    _ = await entry.task.result
  }

  public func stopAll(accountID: Int64, cacheDirectories: [URL] = []) async {
    stoppedAccounts[accountID, default: 0] += 1
    defer {
      if stoppedAccounts[accountID] == 1 { stoppedAccounts[accountID] = nil }
      else { stoppedAccounts[accountID, default: 1] -= 1 }
    }
    let owned = entries.filter { $0.key.accountID == accountID }
    for (key, entry) in owned { entry.task.cancel(); cancelQueued(key, id: entry.id) }
    for entry in owned.values { _ = await entry.task.result }
    let directories = (knownDirectories.removeValue(forKey: accountID) ?? []).union(cacheDirectories)
    for directory in directories { purge(accountID: accountID, directory: directory) }
  }

  public func discard(fileUniqueID: String, accountID: Int64, cacheDirectory: URL) async {
    let key = Key(accountID: accountID, fileUniqueID: fileUniqueID)
    guard Self.validFileID(fileUniqueID) else { return }
    block(key)
    defer { unblock(key) }
    let ownedDirectory = entries[key]?.request.destination.deletingLastPathComponent()
    await drain(key)
    for directory in Set([cacheDirectory, ownedDirectory].compactMap { $0 }) {
      let recordURL = Self.partial(fileUniqueID, in: directory).appendingPathExtension("json")
      if directory == ownedDirectory || Self.record(at: recordURL)?.accountID == accountID {
        Self.removePartial(fileUniqueID: fileUniqueID, directory: directory, accountID: accountID)
      }
    }
  }

  /// Active duplicate references are tracked; idle provenance belongs to the
  /// first owner. Legacy records without IDs remain resumable and expire normally.
  public func discard(message: FileMessageLocation, accountID: Int64, cacheDirectories: [URL]) async {
    let owned = entries.filter { $0.key.accountID == accountID && $0.value.locations.contains(message) }
    for key in owned.keys { block(key) }
    defer { for key in owned.keys { unblock(key) } }
    for (key, entry) in owned { entry.task.cancel(); cancelQueued(key, id: entry.id) }
    for entry in owned.values { _ = await entry.task.result }
    for entry in owned.values {
      Self.removePartial(fileUniqueID: entry.request.fileUniqueID, directory: entry.request.destination.deletingLastPathComponent(), accountID: accountID)
    }
    for directory in cacheDirectories {
      for body in Self.partialFiles(in: directory) where !isOwned(body) {
        Self.removeIdlePartial(body) { saved in
          saved?.accountID == accountID && saved?.chatID == message.chatID && saved?.messageID == message.messageID
        }
      }
    }
  }

  /// Called under the coordinator's cache-maintenance admission barrier.
  public func clearIdleCache(directory: URL) {
    for body in Self.partialFiles(in: directory) where !isOwned(body) {
      Self.removeIdlePartial(body)
    }
  }

  public func sweep(directory: URL) {
    let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    for body in Self.partialFiles(in: directory) where !isOwned(body) {
      let record = body.appendingPathExtension("json")
      Self.removeIdlePartial(body) { _ in
        let latest = [body, record].compactMap {
          try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
        return latest.map({ $0 < cutoff }) ?? true
      }
    }
  }

  private func purge(accountID: Int64, directory: URL) {
    for body in Self.partialFiles(in: directory) where !isOwned(body) {
      // Account cleanup cannot attribute missing/malformed records. Launch
      // expiry or explicit cache clearing can remove those once inactive.
      Self.removeIdlePartial(body) { $0?.accountID == accountID }
    }
  }
  private func isOwned(_ body: URL) -> Bool {
    entries.values.contains { Self.partial($0.request.fileUniqueID, in: $0.request.destination.deletingLastPathComponent()) == body }
  }
  private static func partialFiles(in directory: URL) -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return Array(Set(files.compactMap { url in
      if url.lastPathComponent.hasSuffix(".inline-partial") { return url }
      if url.lastPathComponent.hasSuffix(".inline-partial.json") { return url.deletingPathExtension() }
      return nil
    }))
  }
  private static func partial(_ file: String, in directory: URL) -> URL {
    directory.appendingPathComponent("\(file).inline-partial")
  }
  private static func record(at url: URL) -> NativeDownloadRecord? {
    let descriptor = url.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) } ?? -1
    }
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 2_049), data.count <= 2_048 else { return nil }
    return try? JSONDecoder().decode(NativeDownloadRecord.self, from: data)
  }
  private static func removePartial(fileUniqueID: String, directory: URL, accountID: Int64) {
    removeIdlePartial(partial(fileUniqueID, in: directory)) { $0 == nil || $0?.accountID == accountID }
  }
  private static func removeIdlePartial(_ body: URL, matching: (NativeDownloadRecord?) -> Bool = { _ in true }) {
    let descriptor = body.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW) } ?? -1
    }
    if descriptor < 0, errno != ENOENT { return }
    defer { if descriptor >= 0 { Darwin.close(descriptor) } }
    // A different manager/process may own this cache-adjacent file. Its lock
    // protects the body while it creates or refreshes the small sidecar.
    if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) != 0 { return }
    let metadata = body.appendingPathExtension("json")
    guard matching(record(at: metadata)) else { return }
    try? FileManager.default.removeItem(at: body)
    try? FileManager.default.removeItem(at: metadata)
  }
  private func acquire(_ key: Key, id: UUID) async throws {
    try Task.checkCancellation()
    if activeFiles < 3, waiters.isEmpty {
      activeFiles += 1
      entries[key]?.running = true
      entries[key]?.lastProgress = .now
      return
    }
    let granted = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: false); return }
        waiters.append(Waiter(key: key, id: id, continuation: continuation))
      }
    } onCancel: { Task { await self.cancelQueued(key, id: id) } }
    guard granted else { throw CancellationError() }
    try Task.checkCancellation()
  }
  private func cancelQueued(_ key: Key, id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.key == key && $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(returning: false)
  }
  private func finished(_ key: Key, id: UUID) {
    guard let entry = entries[key], entry.id == id else { return }
    if entry.running { activeFiles -= 1 }
    cancelQueued(key, id: id)
    entries.removeValue(forKey: key)
    while activeFiles < 3, !waiters.isEmpty {
      let next = waiters.removeFirst()
      guard entries[next.key]?.id == next.id else { next.continuation.resume(returning: false); continue }
      activeFiles += 1
      entries[next.key]?.running = true
      entries[next.key]?.lastProgress = .now
      next.continuation.resume(returning: true)
    }
  }
  private func received(_ count: Int64, total: Int64, key: Key, id: UUID) {
    guard var entry = entries[key], entry.id == id else { return }
    if count > entry.received { entry.lastProgress = .now }
    entry.received = count; entry.total = total
    entries[key] = entry
    for observer in entry.observers.values { observer(count, total) }
  }
  private func remaining(_ key: Key, id: UUID) -> Duration {
    guard let entry = entries[key], entry.id == id else { return .zero }
    return ContinuousClock.now.duration(to: entry.lastProgress.advanced(by: retryBudget))
  }
  private func retryDelay(_ attempt: Int) -> Duration { min(retryBaseDelay * (1 << min(attempt, 3)), .seconds(8)) }

  private static func validate(_ request: Request) throws {
    guard request.destination.isFileURL, !request.destination.path.contains("\0"), request.maximumByteCount > 0,
          validFileID(request.fileUniqueID),
          request.message.map({ $0.chatID > 0 && $0.messageID > 0 && $0.chatID <= 2_147_483_647 && $0.messageID <= 2_147_483_647 }) ?? true
    else { throw NativeFileDownloadError.invalidRequest }
  }

  private static func validFileID(_ file: String) -> Bool {
    (6 ... 128).contains(file.utf8.count) && file.utf8.allSatisfy {
      (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
    }
  }

  @concurrent
  private static func materialize(_ request: Request, owner: NativeDownloadManager, id: UUID) async throws -> URL {
    let destination = request.destination
    try Task.checkCancellation(); try request.validateAccount()
    if FileManager.default.fileExists(atPath: destination.path) { throw POSIXError(.EEXIST) }
    let persistent = request.accountID > 0
    let body = persistent ? partial(request.fileUniqueID, in: destination.deletingLastPathComponent()) :
      destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).inline-download-\(UUID().uuidString).partial")
    let metadata = body.appendingPathExtension("json")
    let descriptor = body.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR) } ?? -1
    }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { try? handle.close(); throw POSIXError(.EBUSY) }
    var retain = false
    var complete = false
    var written: UInt64 = 0
    var total: UInt64 = 0
    var metadataData: Data?
    defer {
      if !complete && !retain { try? FileManager.default.removeItem(at: metadata) }
      if !complete && !retain { try? FileManager.default.removeItem(at: body) }
      // Keep the original staging flock until cleanup has relinquished paths.
      try? handle.close()
    }
    do {
      let saved = persistent ? record(at: metadata) : nil
      let length = try handle.seekToEnd()
      if let saved, saved.v == 1, saved.accountID == request.accountID,
         saved.fileUniqueID == request.fileUniqueID, saved.totalSize > 0,
         saved.totalSize <= request.maximumByteCount, length <= saved.totalSize {
        written = length / UInt64(NativeFileDownloader.partSize) * UInt64(NativeFileDownloader.partSize)
        total = saved.totalSize
      }
      try handle.truncate(atOffset: written)
      try handle.seek(toOffset: written)
      var input = GetFilePartInput()
      input.fileUniqueID = request.fileUniqueID; input.limit = NativeFileDownloader.partSize
      if let message = request.message { input.message = message }
      // An aligned complete prefix has no range at EOF. Re-authorize its last
      // range instead, then publish the already verified complete prefix.
      input.offset = total > 0 && written == total ? total - min(total, UInt64(input.limit)) : written
      var first: GetFilePartResult
      do {
        first = try await fetch(input, request: request, owner: owner, id: id)
      } catch {
        guard written > 0, isGeometryFailure(error) else { throw error }
        written = 0; total = 0
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        input.offset = 0
        first = try await fetch(input, request: request, owner: owner, id: id)
      }
      if total > 0 && first.totalSize != total {
        written = 0; try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        input.offset = 0
        first = try await fetch(input, request: request, owner: owner, id: id)
      }
      total = first.totalSize
      if persistent {
        let data = try JSONEncoder().encode(NativeDownloadRecord(v: 1, accountID: request.accountID,
          fileUniqueID: request.fileUniqueID, totalSize: total, chatID: request.message?.chatID, messageID: request.message?.messageID))
        metadataData = data
        try data.write(to: metadata, options: .atomic)
      }
      await owner.received(Int64(written), total: Int64(total), key: request.key, id: id)
      func write(_ part: GetFilePartResult) async throws {
        try Task.checkCancellation(); try request.validateAccount()
        guard part.offset == written, part.totalSize == total else { throw NativeFileDownloadError.invalidResponse }
        try handle.write(contentsOf: part.data)
        written += UInt64(part.data.count)
        await owner.received(Int64(written), total: Int64(total), key: request.key, id: id)
      }
      if written < total { try await write(first) }
      input.offset = 0
      let base = input
      try await withThrowingTaskGroup(of: GetFilePartResult.self) { group in
        var next = written
        var active = 0
        var ready: [UInt64: GetFilePartResult] = [:]
        func refill() {
          // Four ranges per file (at most three files): 12 per client, under the server's 16.
          while active + ready.count < 4, next < total {
            var nextInput = base; nextInput.offset = next
            let scheduled = nextInput
            next += UInt64(base.limit); active += 1
            group.addTask { try await fetch(scheduled, request: request, owner: owner, id: id) }
          }
        }
        refill()
        while let part = try await group.next() {
          active -= 1; ready[part.offset] = part
          while let part = ready.removeValue(forKey: written) { try await write(part) }
          try Task.checkCancellation(); try request.validateAccount()
          refill()
        }
      }
      guard written == total, try handle.seekToEnd() == total else { throw NativeFileDownloadError.invalidResponse }
      try handle.synchronize()
      try Task.checkCancellation(); try request.validateAccount()
      if persistent {
        // Retire our sidecar before rename frees the stable body pathname for a
        // successor. Only this owner writes it; duplicates track locations in memory.
        try FileManager.default.removeItem(at: metadata)
      }
      let result = body.withUnsafeFileSystemRepresentation { source in
        destination.withUnsafeFileSystemRepresentation { target in
          guard let source, let target else { return EINVAL }
          return Darwin.renameatx_np(AT_FDCWD, source, AT_FDCWD, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
      }
      guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
      complete = true
      return destination
    } catch {
      retain = persistent && written > 0 && (try? request.validateAccount()) != nil &&
        (error is CancellationError || NativeFileDownloader.isRetryableTransportFailure(error) || (error as? POSIXError)?.code == .EEXIST)
      if retain {
        try? handle.synchronize()
        if (error as? POSIXError)?.code == .EEXIST, let metadataData {
          // Rename did not free the body pathname, so its original flock still
          // protects restoring the known record for complete-prefix recovery.
          try? metadataData.write(to: metadata, options: .atomic)
        }
      }
      throw error
    }
  }

  private static func isGeometryFailure(_ error: any Error) -> Bool {
    if let error = error as? NativeFileDownloadError {
      switch error {
      case .invalidRequest, .invalidResponse: return true
      case .integrity, .fileTooLarge, .inaccessible: return false
      }
    }
    if case let .rpcError(_, _, status)? = error as? RealtimeDirectRpcError { return status == 400 }
    return false
  }

  @concurrent
  private static func fetch(_ input: GetFilePartInput, request: Request, owner: NativeDownloadManager, id: UUID) async throws -> GetFilePartResult {
    var attempt = 0
    while true {
      try Task.checkCancellation(); try request.validateAccount()
      let remaining = await owner.remaining(request.key, id: id)
      guard remaining > .zero else { throw RealtimeDirectRpcError.timeout }
      do {
        let part = try await request.transport.fetchFilePart(input, timeout: min(.seconds(30), remaining))
        try Task.checkCancellation(); try request.validateAccount()
        guard part.offset == input.offset, part.totalSize > 0, part.totalSize <= UInt64(Int64.max), part.totalSize >= input.offset else {
          throw NativeFileDownloadError.invalidResponse
        }
        guard part.totalSize <= request.maximumByteCount else { throw NativeFileDownloadError.fileTooLarge }
        let expected = min(UInt64(input.limit), part.totalSize - input.offset)
        guard UInt64(part.data.count) == expected, part.sha256.count == 32 else { throw NativeFileDownloadError.invalidResponse }
        guard Data(SHA256.hash(data: part.data)) == part.sha256 else { throw NativeFileDownloadError.integrity }
        return part
      } catch {
        try Task.checkCancellation(); try request.validateAccount()
        guard NativeFileDownloader.isRetryableTransportFailure(error) else { throw error }
        let delay = await owner.retryDelay(attempt)
        let remaining = await owner.remaining(request.key, id: id)
        guard remaining > .zero else { throw error }
        attempt += 1
        try await Task.sleep(for: min(delay, remaining))
      }
    }
  }
}

/// Transport facade; account-bound app downloads route through the shared owner.
public struct NativeFileDownloader: Sendable {
  fileprivate static let partSize: UInt32 = 524_288
  private let transport: any NativeFilePartFetching
  private let manager: NativeDownloadManager
  public init(transport: any NativeFilePartFetching) { self.transport = transport; manager = .shared }
  init(transport: any NativeFilePartFetching, manager: NativeDownloadManager) { self.transport = transport; self.manager = manager }
  @concurrent
  public func download(fileUniqueID: String, message: FileMessageLocation? = nil, to destination: URL,
    maximumByteCount: UInt64 = 500_000_000, progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> URL {
    try await manager.download(.init(accountID: -Int64.random(in: 1 ... Int64.max), fileUniqueID: fileUniqueID,
      message: message, destination: destination, maximumByteCount: maximumByteCount, transport: transport), progress: progress)
  }
  static func isRetryableTransportFailure(_ error: any Error) -> Bool {
    if let error = error as? RealtimeDirectRpcError {
      switch error {
      case .notConnected, .timeout, .commitOutcomeUnknown: return true
      case let .unknown(underlying): return isRetryableNetworkFailure(underlying)
      case let .rpcError(code, _, status): return (code == .internalError && status == 408) || (code == .rateLimit && status == 429)
      case .notAuthorized, .capacityExceeded: return false
      }
    }
    return isRetryableNetworkFailure(error)
  }
  private static func isRetryableNetworkFailure(_ error: any Error) -> Bool {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain else { return false }
    switch URLError.Code(rawValue: error.code) {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return true
    default: return false
    }
  }
}

/// Fetch identity at explicit download admission, without adding persistent media
/// fields for the experiment. Bind all RPCs to the account that started it.
struct NativeMessageFileDownload: NativeFilePartFetching {
  static let freshRequestReplayMessage = "Retry getFilePart with a fresh request ID"

  enum Media: Sendable {
    case document(Int64)
    case video(Int64)
  }

  let auth: AuthHandle
  let accountToken: AuthAccountMutationToken

  init(auth: AuthHandle = Auth.shared.handle) throws {
    self.auth = auth
    accountToken = try auth.beginAccountMutation()
  }

  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    let result = try await Self.callFilePartRPCWithReplay(
      call: {
        // Reconnect and the range RPC share this attempt's remaining budget.
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw RealtimeDirectRpcError.timeout }
        return try await Api.realtime.withUserInitiatedConnection(
          accountToken: accountToken, timeout: remaining
        ) { realtime in
          let remaining = ContinuousClock.now.duration(to: deadline)
          guard remaining > .zero else { throw RealtimeDirectRpcError.timeout }
          return try await realtime.callRpcDirect(
            method: .getFilePart,
            input: .getFilePart(input),
            timeout: remaining,
            accountToken: accountToken
          )
        }
      },
      validateAccount: { try auth.validateAccountMutation(accountToken) }
    )
    guard case let .getFilePart(part)? = result else { throw NativeFileDownloadError.invalidResponse }
    return part
  }

  static func callFilePartRPCWithReplay(
    call: () async throws -> RpcResult.OneOf_Result?,
    validateAccount: () throws -> Void
  ) async throws -> RpcResult.OneOf_Result? {
    for attempt in 0 ... 1 {
      let result: RpcResult.OneOf_Result?
      do {
        result = try await call()
      } catch {
        try validateAccount()
        guard attempt == 0, isFreshRequestReplayTombstone(error) else { throw error }
        continue
      }
      try validateAccount()
      return result
    }
    throw NativeFileDownloadError.invalidResponse
  }

  private static func isFreshRequestReplayTombstone(_ error: any Error) -> Bool {
    guard let error = error as? RealtimeDirectRpcError,
          case let .rpcError(errorCode, message, code) = error
    else {
      return false
    }
    return errorCode == .rateLimit && code == 429 && message == freshRequestReplayMessage
  }

  func download(
    media: Media, message: Message, to destination: URL,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> URL {
    var location = FileMessageLocation()
    location.chatID = message.chatId
    location.messageID = message.messageId
    let response = try await Api.realtime.withUserInitiatedConnection(
      accountToken: accountToken, timeout: .seconds(60)
    ) { realtime in
      try await realtime.callRpcDirect(
        method: .getMessages,
        input: .getMessages(.with {
          $0.peerID = message.peerId.toInputPeer()
          $0.messageIds = [message.messageId]
        }), timeout: .seconds(30), accountToken: accountToken
      )
    }
    try auth.validateAccountMutation(accountToken)
    guard case let .getMessages(messages)? = response else { throw NativeFileDownloadError.invalidResponse }
    let fileID = try Self.fileID(in: messages, media: media, location: location)
    return try await NativeDownloadManager.shared.download(.init(
      accountID: accountToken.userID, fileUniqueID: fileID, message: location, destination: destination,
      accountToken: accountToken, validateAccount: { try auth.validateAccountMutation(accountToken) }, transport: self
    ), progress: progress)
  }

  static func isPermissionFailure(_ error: any Error) -> Bool {
    if error is AuthStorageError { return true }
    if case .inaccessible? = error as? NativeFileDownloadError { return true }
    if case .notAuthorized? = error as? RealtimeDirectRpcError { return true }
    if case let .rpcError(code, _, status)? = error as? RealtimeDirectRpcError {
      return [400, 401, 403, 404].contains(status) || code == .unauthenticated
    }
    return false
  }

  static func fileID(in result: GetMessagesResult, media: Media, location: FileMessageLocation) throws -> String {
    guard location.chatID > 0, location.messageID > 0,
          let message = result.messages.first(where: { $0.chatID == location.chatID && $0.id == location.messageID })
    else { throw NativeFileDownloadError.inaccessible }
    let fileID: String
    switch (media, message.media.media) {
    case let (.document(id), .document(value)?) where id > 0 && value.document.id == id:
      fileID = value.document.fileUniqueID
    case let (.video(id), .video(value)?) where id > 0 && value.video.id == id:
      fileID = value.video.fileUniqueID
    default:
      throw NativeFileDownloadError.inaccessible
    }
    guard !fileID.isEmpty else { throw NativeFileDownloadError.inaccessible }
    return fileID
  }
}
