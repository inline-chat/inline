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

/// Sidecar of a resumable partial (`<file>.inline-partial.json`).
/// v1 described a contiguous prefix: the body's length, rounded down to a part.
/// v2 lists the parts present in a sparse body as half-open `[start, end)` part-index ranges.
/// The body is fsynced before every map write, and the map is replaced atomically, so it never
/// claims bytes that are not on disk; parts past the body's length are distrusted on open.
private struct NativeDownloadRecord: Codable {
  let v: Int
  let accountID: Int64
  let fileUniqueID: String
  let totalSize: UInt64
  var chatID: Int64?
  var messageID: Int64?
  var parts: [[UInt32]]?
}

/// Who is waiting for a file. Part slots go to the highest priority first, then round-robin.
public enum NativeDownloadPriority: Int, Comparable, Sendable {
  case background, prefetch, visible, userInitiated
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One owner for native downloads. Every file shares one window of part slots: it adapts to
/// per-part latency (grow by one under 1 s, halve over 2 s or on a transient failure) and is
/// granted by priority, then round-robin, so a small file is never stuck behind a large one.
/// Parts land at their own offsets in a sparse partial whose map survives relaunch.
/// A slot remains owned until its request returns, including after cancellation.
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
    public let priority: NativeDownloadPriority
    /// How long the file may go without progress before failing; the manager's default if nil.
    public let stallBudget: Duration?
    var key: Key { Key(accountID: accountID, fileUniqueID: fileUniqueID) }
    public init(
      accountID: Int64, fileUniqueID: String, message: FileMessageLocation? = nil,
      destination: URL, maximumByteCount: UInt64 = 500_000_000,
      accountToken: AuthAccountMutationToken? = nil,
      validateAccount: @escaping @Sendable () throws -> Void = {},
      priority: NativeDownloadPriority = .visible,
      stallBudget: Duration? = nil,
      transport: any NativeFilePartFetching
    ) {
      self.accountID = accountID; self.fileUniqueID = fileUniqueID; self.message = message
      self.destination = destination; self.maximumByteCount = maximumByteCount
      self.accountToken = accountToken; self.validateAccount = validateAccount
      self.priority = priority; self.stallBudget = stallBudget; self.transport = transport
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
    var priority: NativeDownloadPriority
    var lastProgress = ContinuousClock.now
    var received: Int64 = 0
    var total: Int64 = 0
    var locations: [FileMessageLocation]
    var observers: [UUID: @Sendable (Int64, Int64) -> Void]
    /// Missing parts in ascending order, handed out one per granted slot.
    var pendingParts: [Int] = []
    var nextPending = 0
  }
  private enum SlotGrant { case denied, granted(part: Int?) }
  private struct PartWaiter {
    let key: Key
    let id: UUID
    let ticket: UInt64
    let wantsPart: Bool
    let renewsBudget: Bool
    let continuation: CheckedContinuation<SlotGrant, Never>
  }
  private var entries: [Key: Entry] = [:]
  private var partWaiters: [PartWaiter] = []
  private var activeParts = 0
  private var nextTicket: UInt64 = 0
  /// When each file last got a slot; the least recent goes next among equal priorities.
  private var lastGrant: [Key: UInt64] = [:]
  private var stoppedAccounts: [Int64: Int] = [:]
  private var stoppedKeys: [Key: Int] = [:]
  private var knownDirectories: [Int64: Set<URL>] = [:]
  private let retryBudget: Duration
  private let retryBaseDelay: Duration
  /// Part slots shared by every file. The server admits 16 ranges per session; the cap leaves
  /// room for ranges it is still serving after the client has given up on them.
  private let windowLimits: ClosedRange<Int>
  private(set) var window: Int
  /// Ranges a file keeps queued for slots; more would only hold memory for nothing.
  static let maximumQueuedParts = 16
  /// Ranges waiting for a slot (tests).
  var waitingParts: Int { partWaiters.count }
  public init() {
    retryBudget = .seconds(180); retryBaseDelay = .seconds(1); windowLimits = 2 ... 12; window = 4
  }
  init(retryBudget: Duration = .seconds(180), retryBaseDelay: Duration = .seconds(1),
       window limits: ClosedRange<Int> = 2 ... 12, initialWindow: Int = 4) {
    self.retryBudget = retryBudget; self.retryBaseDelay = retryBaseDelay
    windowLimits = limits; window = min(max(initialWindow, limits.lowerBound), limits.upperBound)
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
      entry.priority = max(entry.priority, request.priority)
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
          try Task.checkCancellation()
          let result = try await Self.materialize(request, owner: self, id: id)
          let publication = self.publishDestinations(result, key: key, id: id)
          self.finished(key, id: id)
          return publication
        } catch {
          self.finished(key, id: id)
          throw error
        }
      }
      entries[key] = Entry(id: id, request: request, task: task, destinations: [observerID: request.destination],
        priority: request.priority, locations: request.message.map { [$0] } ?? [], observers: [observerID: progress])
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

  /// Moves every running download of this message up to `priority`, for a caller that joins a
  /// download already under way (a tap on a file that started as an auto-download).
  public func raisePriority(accountID: Int64, message: FileMessageLocation, to priority: NativeDownloadPriority) {
    for (key, entry) in entries where key.accountID == accountID && entry.locations.contains(message) {
      entries[key]?.priority = max(entry.priority, priority)
    }
  }

  /// A stopped download's verified bytes, read from its sidecar.
  public struct SavedPartial: Equatable, Sendable {
    public let chatID: Int64
    public let messageID: Int64
    public let bytesReceived: Int64
    public let totalBytes: Int64
  }

  /// The resumable partials this account keeps in `directories` that name their message, except
  /// files downloading now (they report live progress). Lists the directories off this actor, so
  /// running downloads never wait on the scan.
  @concurrent
  public nonisolated func savedPartials(accountID: Int64, in directories: [URL]) async -> [SavedPartial] {
    let running = await runningBodies()
    return directories.flatMap { directory in
      Self.partialFiles(in: directory).compactMap { body -> SavedPartial? in
        guard !running.contains(body), let record = Self.record(at: body.appendingPathExtension("json")),
              record.accountID == accountID,
              let chatID = record.chatID, let messageID = record.messageID, chatID > 0, messageID > 0,
              record.totalSize > 0, record.totalSize <= UInt64(Int64.max)
        else { return nil }
        let length = (try? body.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64(max(0, $0)) } ?? 0
        guard let parts = Self.restoredParts(record, accountID: accountID, fileUniqueID: record.fileUniqueID,
                                             maximumByteCount: record.totalSize, bodyLength: length)
        else { return nil }
        // A partial holding every part (kept when publication found its destination taken) is
        // not progress toward anything.
        let bytes = Self.presentBytes(parts, total: record.totalSize)
        guard bytes > 0, bytes < record.totalSize else { return nil }
        return SavedPartial(chatID: chatID, messageID: messageID, bytesReceived: Int64(bytes), totalBytes: Int64(record.totalSize))
      }
    }
  }

  private func runningBodies() -> Set<URL> {
    Set(entries.values.map { Self.partial($0.request.fileUniqueID, in: $0.request.destination.deletingLastPathComponent()) })
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
    cancelWaiters(id: entry.id)
    _ = await entry.task.result
  }

  public func stopAll(accountID: Int64, cacheDirectories: [URL] = []) async {
    stoppedAccounts[accountID, default: 0] += 1
    defer {
      if stoppedAccounts[accountID] == 1 { stoppedAccounts[accountID] = nil }
      else { stoppedAccounts[accountID, default: 1] -= 1 }
    }
    let owned = entries.filter { $0.key.accountID == accountID }
    for entry in owned.values { entry.task.cancel(); cancelWaiters(id: entry.id) }
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
    for entry in owned.values { entry.task.cancel(); cancelWaiters(id: entry.id) }
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
    guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
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
  /// Waits for a slot for a range the caller already chose: the file's first range, or a retry.
  /// A retry's slot does not renew the retry budget, so a range that keeps failing still runs
  /// out of time. The caller must release it.
  fileprivate func acquirePart(_ key: Key, id: UUID, renewsBudget: Bool) async throws {
    _ = try await waitForSlot(key, id: id, wantsPart: false, renewsBudget: renewsBudget)
  }

  /// Waits for a slot and takes the file's next missing part with it, so slots reach a file's
  /// parts in ascending order whatever order its requests queued in. Returns nil, holding no
  /// slot, once every part has been handed out.
  fileprivate func acquireNextPart(_ key: Key, id: UUID) async throws -> Int? {
    try await waitForSlot(key, id: id, wantsPart: true, renewsBudget: true)
  }

  fileprivate func setPendingParts(_ parts: [Int], key: Key, id: UUID) {
    guard entries[key]?.id == id else { return }
    entries[key]?.pendingParts = parts
    entries[key]?.nextPending = 0
  }

  private func waitForSlot(_ key: Key, id: UUID, wantsPart: Bool, renewsBudget: Bool) async throws -> Int? {
    try Task.checkCancellation()
    guard entries[key]?.id == id else { throw CancellationError() }
    if activeParts < window, partWaiters.isEmpty {
      return grant(key, wantsPart: wantsPart, renewsBudget: renewsBudget)
    }
    nextTicket += 1
    let ticket = nextTicket
    let granted = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<SlotGrant, Never>) in
        guard !Task.isCancelled else { continuation.resume(returning: .denied); return }
        partWaiters.append(PartWaiter(key: key, id: id, ticket: ticket, wantsPart: wantsPart,
          renewsBudget: renewsBudget, continuation: continuation))
      }
    } onCancel: { Task { await self.cancelWaiter(ticket: ticket) } }
    guard case let .granted(part) = granted else { throw CancellationError() }
    return part
  }

  /// Returns a slot, adapting the window to the latency of a part that succeeded.
  fileprivate func releasePart(latency: Duration?) {
    activeParts -= 1
    if let latency { adaptWindow(after: latency) }
    grantWaiting()
  }

  /// A part under 1 s grows the window by one; one over 2 s halves it.
  func adaptWindow(after latency: Duration) {
    if latency < .seconds(1) { window = min(window + 1, windowLimits.upperBound) }
    else if latency > .seconds(2) { window = max(window / 2, windowLimits.lowerBound) }
  }

  /// A transient failure is congestion until proven otherwise.
  func partFailedTransiently() {
    window = max(window / 2, windowLimits.lowerBound)
  }

  /// Takes a slot, plus the next pending part when asked. A file with nothing left to hand out
  /// takes no slot.
  private func grant(_ key: Key, wantsPart: Bool, renewsBudget: Bool) -> Int? {
    var part: Int?
    if wantsPart {
      guard var entry = entries[key], entry.nextPending < entry.pendingParts.count else { return nil }
      part = entry.pendingParts[entry.nextPending]
      entry.nextPending += 1
      entries[key] = entry
    }
    activeParts += 1
    nextTicket += 1
    lastGrant[key] = nextTicket
    // Waiting for a new range's slot is not a stall: the budget runs from when it is served.
    if renewsBudget { entries[key]?.lastProgress = .now }
    return part
  }

  private func grantWaiting() {
    partWaiters.removeAll { waiter in
      guard entries[waiter.key]?.id != waiter.id else { return false }
      waiter.continuation.resume(returning: .denied)
      return true
    }
    while activeParts < window, !partWaiters.isEmpty {
      // Highest priority first; among equals, the file served least recently; then arrival.
      let index = partWaiters.indices.max { lhs, rhs in
        let left = partWaiters[lhs], right = partWaiters[rhs]
        let leftPriority = entries[left.key]?.priority ?? .background
        let rightPriority = entries[right.key]?.priority ?? .background
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        let leftGrant = lastGrant[left.key] ?? 0, rightGrant = lastGrant[right.key] ?? 0
        if leftGrant != rightGrant { return leftGrant > rightGrant }
        return left.ticket > right.ticket
      }!
      let next = partWaiters.remove(at: index)
      next.continuation.resume(returning: .granted(
        part: grant(next.key, wantsPart: next.wantsPart, renewsBudget: next.renewsBudget)
      ))
    }
  }

  private func cancelWaiter(ticket: UInt64) {
    guard let index = partWaiters.firstIndex(where: { $0.ticket == ticket }) else { return }
    partWaiters.remove(at: index).continuation.resume(returning: .denied)
  }

  private func cancelWaiters(id: UUID) {
    partWaiters.removeAll { waiter in
      guard waiter.id == id else { return false }
      waiter.continuation.resume(returning: .denied)
      return true
    }
  }

  private func finished(_ key: Key, id: UUID) {
    guard let entry = entries[key], entry.id == id else { return }
    cancelWaiters(id: id)
    entries.removeValue(forKey: key)
    lastGrant.removeValue(forKey: key)
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
    return ContinuousClock.now.duration(to: entry.lastProgress.advanced(by: entry.request.stallBudget ?? retryBudget))
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

  private static var partSize: UInt64 { UInt64(NativeFileDownloader.partSize) }
  static func partCount(total: UInt64) -> Int { Int((total + partSize - 1) / partSize) }
  private static func partEnd(_ index: Int, total: UInt64) -> UInt64 { min(UInt64(index + 1) * partSize, total) }
  private static func presentBytes(_ parts: IndexSet, total: UInt64) -> UInt64 {
    parts.reduce(0) { $0 + partEnd($1, total: total) - UInt64($1) * partSize }
  }

  /// Parts a saved record vouches for, distrusting any that the body does not fully hold.
  private static func restoredParts(
    _ saved: NativeDownloadRecord?, accountID: Int64, fileUniqueID: String, maximumByteCount: UInt64, bodyLength: UInt64
  ) -> IndexSet? {
    guard let saved, saved.v == 1 || saved.v == 2, saved.accountID == accountID,
          saved.fileUniqueID == fileUniqueID, saved.totalSize > 0,
          saved.totalSize <= maximumByteCount, bodyLength <= saved.totalSize
    else { return nil }
    let total = saved.totalSize
    let count = partCount(total: total)
    var claimed = IndexSet()
    if saved.v == 1 {
      // A v1 body is a contiguous prefix of whole parts.
      claimed.insert(integersIn: 0 ..< count)
    } else {
      for range in saved.parts ?? [] {
        guard range.count == 2, range[0] < range[1], Int(range[1]) <= count else { return nil }
        claimed.insert(integersIn: Int(range[0]) ..< Int(range[1]))
      }
    }
    return claimed.filteredIndexSet { partEnd($0, total: total) <= bodyLength }
  }

  /// Flushes the body to stable storage, past the drive cache that a plain fsync leaves on Darwin.
  private static func fullSync(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  /// At most this many ranges are recorded; a pathological map keeps its first ranges.
  private static let maximumRecordedRanges = 512

  private static func encodeRecord(_ request: Request, total: UInt64, parts: IndexSet) throws -> Data {
    let ranges = parts.rangeView.prefix(maximumRecordedRanges).map { [UInt32($0.lowerBound), UInt32($0.upperBound)] }
    return try JSONEncoder().encode(NativeDownloadRecord(
      v: 2, accountID: request.accountID, fileUniqueID: request.fileUniqueID, totalSize: total,
      chatID: request.message?.chatID, messageID: request.message?.messageID, parts: ranges
    ))
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
    var present = IndexSet()
    var total: UInt64 = 0
    defer {
      if !complete && !retain { try? FileManager.default.removeItem(at: metadata) }
      if !complete && !retain { try? FileManager.default.removeItem(at: body) }
      // Keep the original staging flock until cleanup has relinquished paths.
      try? handle.close()
    }
    func reset() throws {
      present = IndexSet(); total = 0
      try handle.truncate(atOffset: 0)
    }
    do {
      let saved = persistent ? record(at: metadata) : nil
      let length = try handle.seekToEnd()
      if let restored = restoredParts(saved, accountID: request.accountID, fileUniqueID: request.fileUniqueID,
                                      maximumByteCount: request.maximumByteCount, bodyLength: length), let saved {
        present = restored; total = saved.totalSize
      } else {
        try reset()
      }
      var base = GetFilePartInput()
      base.fileUniqueID = request.fileUniqueID; base.limit = NativeFileDownloader.partSize
      if let message = request.message { base.message = message }
      func input(_ index: Int) -> GetFilePartInput {
        var input = base; input.offset = UInt64(index) * partSize; return input
      }
      // The first range authorizes the file and confirms its size before saved bytes are trusted.
      // With every part present, it re-reads the last one, then publishes the verified body.
      let count = total > 0 ? partCount(total: total) : 0
      var firstIndex = total > 0 ? ((0 ..< count).first { !present.contains($0) } ?? count - 1) : 0
      var first: GetFilePartResult
      do {
        first = try await fetchWithSlot(input(firstIndex), request: request, owner: owner, id: id)
      } catch {
        guard !present.isEmpty, isGeometryFailure(error) else { throw error }
        try reset(); firstIndex = 0
        first = try await fetchWithSlot(input(0), request: request, owner: owner, id: id)
      }
      if total > 0 && first.totalSize != total {
        try reset(); firstIndex = 0
        first = try await fetchWithSlot(input(0), request: request, owner: owner, id: id)
      }
      total = first.totalSize
      var lastMapWrite = ContinuousClock.now
      func writeMap() throws {
        guard persistent else { return }
        try encodeRecord(request, total: total, parts: present).write(to: metadata, options: .atomic)
        lastMapWrite = .now
      }
      try writeMap()
      await owner.received(Int64(presentBytes(present, total: total)), total: Int64(total), key: request.key, id: id)
      func write(_ part: GetFilePartResult) async throws {
        try Task.checkCancellation(); try request.validateAccount()
        guard part.totalSize == total, part.offset % partSize == 0, part.offset < total else {
          throw NativeFileDownloadError.invalidResponse
        }
        let index = Int(part.offset / partSize)
        guard !present.contains(index) else { return }
        try handle.seek(toOffset: part.offset)
        try handle.write(contentsOf: part.data)
        present.insert(index)
        // Bytes reach disk before the map that claims them; at most one map write a second.
        if persistent, ContinuousClock.now - lastMapWrite >= .seconds(1) {
          try fullSync(descriptor)
          try writeMap()
        }
        await owner.received(Int64(presentBytes(present, total: total)), total: Int64(total), key: request.key, id: id)
      }
      try await write(first)
      let missing = (0 ..< partCount(total: total)).filter { !present.contains($0) }
      await owner.setPendingParts(missing, key: request.key, id: id)
      let template = base
      try await withThrowingTaskGroup(of: GetFilePartResult?.self) { group in
        // Each request takes whichever part the scheduler hands it when its slot is granted.
        var spawned = 0
        var queued = 0
        func refill() {
          while queued < maximumQueuedParts, spawned < missing.count {
            spawned += 1; queued += 1
            group.addTask { try await fetchNextPart(template, request: request, owner: owner, id: id) }
          }
        }
        refill()
        // Each range is written as it arrives, in any order, so nothing waits in memory.
        while let result = try await group.next() {
          queued -= 1
          if let part = result { try await write(part) }
          try Task.checkCancellation(); try request.validateAccount()
          refill()
        }
      }
      guard present.count == partCount(total: total), try handle.seekToEnd() == total else {
        throw NativeFileDownloadError.invalidResponse
      }
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
      // Stopping never discards verified bytes; only a file the server refuses or corrupts goes.
      // A CDN failure says nothing about bytes already verified, so those stay too.
      retain = persistent && !present.isEmpty && total > 0 && (try? request.validateAccount()) != nil &&
        (error is CancellationError || error is CDNRangeError ||
         NativeFileDownloader.isRetryableTransportFailure(error) || (error as? POSIXError)?.code == .EEXIST)
      if retain {
        // Rename did not free the body pathname on EEXIST, so the original flock still protects
        // restoring the map for complete-body recovery. A map is written only over synced bytes;
        // if the sync fails the previous map stays, claiming less.
        if (try? fullSync(descriptor)) != nil {
          try? encodeRecord(request, total: total, parts: present).write(to: metadata, options: .atomic)
        }
      }
      throw error
    }
  }

  /// The next part the scheduler hands this file, under its slot; nil when none remain.
  @concurrent
  private static func fetchNextPart(
    _ base: GetFilePartInput, request: Request, owner: NativeDownloadManager, id: UUID
  ) async throws -> GetFilePartResult? {
    guard let index = try await owner.acquireNextPart(request.key, id: id) else { return nil }
    var input = base
    input.offset = UInt64(index) * partSize
    return try await fetchHoldingSlot(input, request: request, owner: owner, id: id)
  }

  /// One range under a freshly acquired slot.
  @concurrent
  private static func fetchWithSlot(
    _ input: GetFilePartInput, request: Request, owner: NativeDownloadManager, id: UUID
  ) async throws -> GetFilePartResult {
    try await owner.acquirePart(request.key, id: id, renewsBudget: true)
    return try await fetchHoldingSlot(input, request: request, owner: owner, id: id)
  }

  /// Fetches a range under a slot the caller holds and always releases it. Transient failures
  /// retry within the file's budget; the slot goes back during each backoff, so a flaky range
  /// never keeps other files waiting while it sleeps.
  @concurrent
  private static func fetchHoldingSlot(
    _ input: GetFilePartInput, request: Request, owner: NativeDownloadManager, id: UUID
  ) async throws -> GetFilePartResult {
    var attempt = 0
    while true {
      do {
        let (part, latency) = try await attemptPart(input, request: request, owner: owner, id: id)
        await owner.releasePart(latency: latency)
        return part
      } catch {
        await owner.releasePart(latency: nil)
        try Task.checkCancellation(); try request.validateAccount()
        guard NativeFileDownloader.isRetryableTransportFailure(error) else { throw error }
        await owner.partFailedTransiently()
        let delay = await owner.retryDelay(attempt)
        let remaining = await owner.remaining(request.key, id: id)
        guard remaining > .zero else { throw error }
        attempt += 1
        try await Task.sleep(for: min(delay, remaining))
        try await owner.acquirePart(request.key, id: id, renewsBudget: false)
      }
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

  /// One verified attempt at a range within the file's remaining budget, with its latency.
  @concurrent
  private static func attemptPart(
    _ input: GetFilePartInput, request: Request, owner: NativeDownloadManager, id: UUID
  ) async throws -> (GetFilePartResult, Duration) {
    try Task.checkCancellation(); try request.validateAccount()
    let remaining = await owner.remaining(request.key, id: id)
    guard remaining > .zero else { throw RealtimeDirectRpcError.timeout }
    let started = ContinuousClock.now
    let part = try await request.transport.fetchFilePart(input, timeout: min(.seconds(30), remaining))
    let latency = ContinuousClock.now - started
    try Task.checkCancellation(); try request.validateAccount()
    guard part.offset == input.offset, part.totalSize > 0, part.totalSize <= UInt64(Int64.max), part.totalSize >= input.offset else {
      throw NativeFileDownloadError.invalidResponse
    }
    guard part.totalSize <= request.maximumByteCount else { throw NativeFileDownloadError.fileTooLarge }
    let expected = min(UInt64(input.limit), part.totalSize - input.offset)
    guard UInt64(part.data.count) == expected, part.sha256.count == 32 else { throw NativeFileDownloadError.invalidResponse }
    guard Data(SHA256.hash(data: part.data)) == part.sha256 else { throw NativeFileDownloadError.integrity }
    return (part, latency)
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
    if let error = error as? CDNRangeError { return error.isTransient }
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
    case voice(Int64)
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

  /// How long native may stall before the CDN takes over: the fallback resumes the same
  /// partial, so leaving early costs nothing.
  static let fallbackStallBudget: Duration = .seconds(30)

  func download(
    media: Media, message: Message, to destination: URL, fallback link: CDNLink? = nil,
    priority: NativeDownloadPriority = .visible,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> NativeDownloadOutcome {
    var location = FileMessageLocation()
    location.chatID = message.chatId
    location.messageID = message.messageId
    // Like Telegram, a stopped file looks like any remote file until it is asked for again;
    // then its progress starts at what it already holds, not at zero until the first round trip.
    await Self.reportSavedProgress(
      manager: .shared, accountID: accountToken.userID, location: location,
      directory: destination.deletingLastPathComponent(), progress: progress
    )
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
    let auth = auth
    let accountToken = accountToken
    let provenance = location
    return try await Self.downloadWithRangeFallback(
      manager: .shared, native: self, link: link, progress: progress,
      validateAccount: { try auth.validateAccountMutation(accountToken) }
    ) { transport, stallBudget in
      .init(
        accountID: accountToken.userID, fileUniqueID: fileID, message: provenance, destination: destination,
        accountToken: accountToken, validateAccount: { try auth.validateAccountMutation(accountToken) },
        priority: priority, stallBudget: stallBudget, transport: transport
      )
    }
  }

  /// Reports the bytes a stopped download of this message already holds, so a resumed file's
  /// progress starts where it left off. Reports nothing for a fresh, finished or running file.
  static func reportSavedProgress(
    manager: NativeDownloadManager, accountID: Int64, location: FileMessageLocation, directory: URL,
    progress: @Sendable (Int64, Int64) -> Void
  ) async {
    let saved = await manager.savedPartials(accountID: accountID, in: [directory])
      .first { $0.chatID == location.chatID && $0.messageID == location.messageID }
    if let saved { progress(saved.bytesReceived, saved.totalBytes) }
  }

  /// Downloads a file whose identity the caller already holds, such as a stored photo size,
  /// without re-fetching its message. The message location still authorizes every range.
  func download(
    fileID: String, location: FileMessageLocation, to destination: URL,
    priority: NativeDownloadPriority = .visible, stallBudget: Duration? = fallbackStallBudget,
    progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
  ) async throws -> URL {
    let auth = auth
    let accountToken = accountToken
    return try await NativeDownloadManager.shared.download(.init(
      accountID: accountToken.userID, fileUniqueID: fileID, message: location, destination: destination,
      accountToken: accountToken, validateAccount: { try auth.validateAccountMutation(accountToken) },
      priority: priority, stallBudget: stallBudget, transport: self
    ), progress: progress)
  }

  /// Downloads natively, and if that fails for a reason the CDN could get past, lets the CDN
  /// fill the same partial with range requests. Permission failures and cancellation never fall
  /// back, and a changed account stops both.
  static func downloadWithRangeFallback(
    manager: NativeDownloadManager,
    native: any NativeFilePartFetching,
    link: CDNLink?,
    progress: @escaping @Sendable (Int64, Int64) -> Void,
    validateAccount: @Sendable () throws -> Void,
    request: @Sendable (any NativeFilePartFetching, Duration?) -> NativeDownloadManager.Request
  ) async throws -> NativeDownloadOutcome {
    do {
      let file = try await manager.download(request(native, link == nil ? nil : fallbackStallBudget), progress: progress)
      return NativeDownloadOutcome(file: file, fallback: nil)
    } catch {
      guard let link, !Task.isCancelled, !(error is CancellationError), !isPermissionFailure(error),
            (error as? POSIXError)?.code != .EEXIST, (try? validateAccount()) != nil
      else { throw error }
      do {
        let file = try await manager.download(request(CDNRangeSource(link: link), nil), progress: progress)
        return NativeDownloadOutcome(file: file, fallback: error)
      } catch let cdnError {
        if Task.isCancelled || cdnError is CancellationError { throw cdnError }
        throw NativeRangeFallbackFailure(native: error, cdn: cdnError)
      }
    }
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
    case let (.voice(id), .voice(value)?) where id > 0 && value.voice.id == id:
      fileID = value.voice.fileUniqueID
    default:
      throw NativeFileDownloadError.inaccessible
    }
    guard !fileID.isEmpty else { throw NativeFileDownloadError.inaccessible }
    return fileID
  }
}
