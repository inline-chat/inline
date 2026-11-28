import CryptoKit
import Darwin
import Foundation
import Auth
import InlineConfig
import InlineProtocol
import Logger
import os
import RealtimeV2

public enum MediaUploadLimits {
  public static func maximumByteCount(for kind: UploadKind) -> Int? {
    switch kind {
    case .photo: 40_000_000
    case .video, .document: 500_000_000
    case .voice: 20_000_000
    case .unspecified, .UNRECOGNIZED: nil
    }
  }

  public static func validate(fileURL: URL, kind: UploadKind) throws {
    guard let limit = maximumByteCount(for: kind) else { throw NativeMediaUploadError.fileTooLarge }
    let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= limit else { throw AttachmentSizeLimitError(maximumBytes: limit) }
  }
}

public struct AttachmentSizeLimitError: LocalizedError, Sendable {
  public let maximumBytes: Int
  public var errorDescription: String? { "This file is too large. The upload limit is \(maximumBytes / 1_000_000) MB." }
}

let maximumUploadProcessingRetrySeconds: UInt32 = 30

func boundedUploadProcessingRetrySeconds(_ seconds: UInt32) -> UInt32 {
  min(maximumUploadProcessingRetrySeconds, max(1, seconds))
}

/// A file still being written (a video encoding) that uploads as it grows. The writer calls
/// `finish()` once the file is final, or `fail(_:)`. Bytes after the first part are final once
/// written; the first part (the MP4 header's size field) is sent only when the file is done.
public final class NativeLiveUploadSource: Sendable {
  private let outcome = OSAllocatedUnfairLock<Result<Void, any Error>?>(initialState: nil)

  public init() {}

  public func finish() { outcome.withLock { if $0 == nil { $0 = .success(()) } } }
  public func fail(_ error: any Error) { outcome.withLock { if $0 == nil { $0 = .failure(error) } } }

  /// Nil while the file is still being written.
  var result: Result<Void, any Error>? { outcome.withLock { $0 } }

  /// Waits for the file to be final; throws the writer's failure.
  func waitUntilFinished() async throws {
    while true {
      switch result {
      case .success: return
      case let .failure(error): throw error
      case nil: try await Task.sleep(for: .milliseconds(50))
      }
    }
  }
}

public struct NativeMediaUploadRequest: Sendable {
  public let logicalID: String
  public let fileURL: URL
  public let fileName: String
  public let mimeType: String
  public let kind: UploadKind
  public let thumbnailFileUniqueID: String?
  public let metadata: CreateUploadInput.OneOf_Metadata?
  /// Holds the finish until it opens (an upload started at attach waits for Send). The bytes still
  /// move; until finish the server keeps the upload unfinished, so canceling deletes all of it.
  public let finishGate: NativeUploadFinishGate?
  /// Names the thumbnail at finish instead of create (`thumbnailFileUniqueID` stays nil), so the
  /// upload can start before its thumbnail is done. Only for servers that take it; see
  /// `DurableUploadCoordinator.acceptsThumbnailAtFinish`.
  public let thumbnailAtFinish: (@Sendable () async throws -> String?)?
  /// `fileURL` is still being written: a video uploads while it encodes, on servers that take the
  /// size at finish (`DurableUploadCoordinator.acceptsSizeAtFinish`). Elsewhere the upload waits
  /// for the file and goes as usual. Such an upload starts over rather than resume after a relaunch.
  public let liveSource: NativeLiveUploadSource?

  public init(
    logicalID: String,
    fileURL: URL,
    fileName: String,
    mimeType: String,
    kind: UploadKind,
    thumbnailFileUniqueID: String? = nil,
    metadata: CreateUploadInput.OneOf_Metadata? = nil,
    finishGate: NativeUploadFinishGate? = nil,
    thumbnailAtFinish: (@Sendable () async throws -> String?)? = nil,
    liveSource: NativeLiveUploadSource? = nil
  ) {
    self.logicalID = logicalID
    self.fileURL = fileURL
    // Backslash is legal on the device. Document upload names must be portable.
    self.fileName = kind == .document ? fileName.replacingOccurrences(of: "\\", with: "_") : fileName
    self.mimeType = mimeType
    self.kind = kind
    self.thumbnailFileUniqueID = thumbnailFileUniqueID
    self.metadata = metadata
    self.finishGate = finishGate
    self.thumbnailAtFinish = thumbnailAtFinish
    self.liveSource = liveSource
  }
}

public protocol MediaUploading: Sendable {
  func upload(
    _ request: NativeMediaUploadRequest,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> UploadComplete
}

public protocol NativeUploadStaging: Sendable {
  func stage(logicalID: String, sourceURL: URL) async throws -> URL
  func sourceHash(
    logicalID: String,
    stagedURL: URL,
    compute: @escaping @Sendable (URL) async throws -> (Int64, Data)
  ) async throws -> (Int64, Data)
  func discard(logicalID: String) async
  func identitySalt(logicalID: String) async throws -> Data
  func invalidateIdentity(logicalID: String) async
  func pendingCancellationIDs(owner: String) async -> [Data]
  func recordPendingCancellation(uploadID: Data, owner: String) async
  func removePendingCancellation(uploadID: Data, owner: String) async
}

extension NativeUploadStaging {
  public func sourceHash(
    logicalID: String,
    stagedURL: URL,
    compute: @escaping @Sendable (URL) async throws -> (Int64, Data)
  ) async throws -> (Int64, Data) {
    try await compute(stagedURL)
  }
  public func identitySalt(logicalID: String) async throws -> Data { Data() }
  public func invalidateIdentity(logicalID: String) async {}
  public func pendingCancellationIDs(owner: String) async -> [Data] { [] }
  public func recordPendingCancellation(uploadID: Data, owner: String) async {}
  public func removePendingCancellation(uploadID: Data, owner: String) async {}
}

/// Owns immutable upload sources independently of picker URLs and preprocessing temporaries.
/// iOS and its Share Extension use the app-group container; macOS falls back to Application Support.
public actor FileNativeUploadStagingStore: NativeUploadStaging {
  public static let shared = FileNativeUploadStagingStore()

  private let root: URL
  private let availableCapacity: @Sendable (URL) -> Int64?
  private let copyRequiresFullAllocation: @Sendable (URL, URL) -> Bool?

  private struct SourceSignature: Codable, Equatable {
    let device: Int64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    static func read(at url: URL, requireRegularFile: Bool = true) throws -> Self {
      var info = stat()
      let result = url.withUnsafeFileSystemRepresentation { path in
        path.map { lstat($0, &info) } ?? -1
      }
      guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      guard !requireRegularFile || info.st_mode & S_IFMT == S_IFREG else {
        throw NativeMediaUploadError.sourceChanged
      }
      return Self(
        device: Int64(info.st_dev), inode: UInt64(info.st_ino), byteCount: Int64(info.st_size),
        modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
        changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
      )
    }
  }

  private struct CachedSourceHash: Codable {
    let version: Int
    let logicalKey: String
    let signature: SourceSignature
    let sha256: Data
  }

  private struct PendingCancellation: Codable {
    let owner: String
    let uploadID: Data
    let date: Date
  }

  private func cancellationURL(uploadID: Data, owner: String) -> URL {
    let key = Self.fileName(for: "\(owner):\(uploadID.base64EncodedString())")
    return root.appendingPathComponent("cancel-\(key).json")
  }

  public func pendingCancellationIDs(owner: String) async -> [Data] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return urls.compactMap { url in
      guard url.lastPathComponent.hasPrefix("cancel-"),
            let data = try? Data(contentsOf: url),
            let record = try? JSONDecoder().decode(PendingCancellation.self, from: data),
            record.owner == owner, record.uploadID.count == 16 else { return nil }
      guard Date().timeIntervalSince(record.date) < 7 * 24 * 3600 else {
        try? FileManager.default.removeItem(at: url)
        return nil
      }
      return record.uploadID
    }
  }

  public func recordPendingCancellation(uploadID: Data, owner: String) async {
    let url = cancellationURL(uploadID: uploadID, owner: owner)
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(PendingCancellation(owner: owner, uploadID: uploadID, date: Date())) {
      try? data.write(to: url, options: .atomic)
    }
  }

  public func removePendingCancellation(uploadID: Data, owner: String) async {
    try? FileManager.default.removeItem(at: cancellationURL(uploadID: uploadID, owner: owner))
  }

  struct PreparedVideo: Codable, Sendable {
    /// Re-encoded or remuxed without location or device details. Older builds wrote no version
    /// and could stage the untouched video.
    static let currentVersion = 2

    let fileName: String
    let mimeType: String
    let width: Int
    let height: Int
    let duration: Int
    var version: Int?
  }

  func preparedVideo(logicalID: String) throws -> (URL, PreparedVideo)? {
    let baseName = Self.fileName(for: logicalID)
    let body = root.appendingPathComponent("\(baseName).body")
    let descriptor = root.appendingPathComponent("\(baseName).video.json")
    guard FileManager.default.fileExists(atPath: body.path),
          FileManager.default.fileExists(atPath: descriptor.path) else { return nil }
    return (body, try JSONDecoder().decode(PreparedVideo.self, from: Data(contentsOf: descriptor)))
  }

  func recordPreparedVideo(_ video: PreparedVideo, logicalID: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(video).write(
      to: root.appendingPathComponent("\(Self.fileName(for: logicalID)).video.json"), options: .atomic
    )
  }

  public init(root: URL? = nil) {
    self.root = root ?? Self.defaultRoot()
    availableCapacity = Self.availableCapacityForCopy
    copyRequiresFullAllocation = Self.fullCopyRequirement
  }

  init(
    root: URL,
    availableCapacity: @escaping @Sendable (URL) -> Int64?,
    copyRequiresFullAllocation: @escaping @Sendable (URL, URL) -> Bool? = FileNativeUploadStagingStore.fullCopyRequirement
  ) {
    self.root = root
    self.availableCapacity = availableCapacity
    self.copyRequiresFullAllocation = copyRequiresFullAllocation
  }

  /// The body an earlier attempt already staged for this upload, which `stage` reuses.
  public func stagedBody(logicalID: String) -> URL? {
    let body = root.appendingPathComponent("\(Self.fileName(for: logicalID)).body")
    return FileManager.default.fileExists(atPath: body.path) ? body : nil
  }

  public func stage(logicalID: String, sourceURL: URL) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: nil
    )
    let destination = root.appendingPathComponent("\(Self.fileName(for: logicalID)).body")
    if fileManager.fileExists(atPath: destination.path) {
      return destination
    }

    // Materialize a selected symlink's target so the staged body remains
    // immutable when the original path or target subsequently changes.
    let copySource = sourceURL.resolvingSymlinksInPath()
    try requireCopyCapacity(for: copySource)

    let temporary = temporaryStagingURL()
    do {
      try fileManager.copyItem(at: copySource, to: temporary)
      // copyItem keeps the source's modification date; stamp the staging time so
      // `pruneStale` ages the staged body, not the original photo or file.
      try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: temporary.path)
      try fileManager.moveItem(at: temporary, to: destination)
      return destination
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }

  /// Temporary copies carry their creation time in the name, because a copy keeps the
  /// source's modification date and the App Group folder is shared with the Share Extension.
  private func temporaryStagingURL(now: Date = Date()) -> URL {
    root.appendingPathComponent("staging-\(Int64(now.timeIntervalSince1970))-\(UUID().uuidString)")
  }

  static func temporaryStagingCreation(fileName: String) -> Date? {
    let parts = fileName.split(separator: "-", maxSplits: 2)
    guard parts.count == 3, parts[0] == "staging", let seconds = Int64(parts[1]) else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(seconds))
  }

  /// Interrupted copies older than this are never completed.
  static let abandonedCopyAge: TimeInterval = 60 * 60
  /// Matches the server's hard upload expiry; nothing can resume past it.
  static let staleUploadAge: TimeInterval = 7 * 24 * 60 * 60

  /// Removes staging left behind by terminated processes, failed sends that were
  /// deleted, and uploads past the server's expiry. A retry re-stages from the
  /// original media file, so dropping an expired body only costs a re-copy.
  @discardableResult
  public func pruneStale(now: Date = Date()) -> Int {
    let fileManager = FileManager.default
    guard let urls = try? fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return 0 }
    var removed = 0
    for url in urls {
      let name = url.lastPathComponent
      // Pending server cancellations expire on their own schedule.
      guard !name.hasPrefix("cancel-") else { continue }
      let modified = Self.temporaryStagingCreation(fileName: name)
        ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        ?? .distantPast
      let age = now.timeIntervalSince(modified)
      let limit = name.hasPrefix("staging-") ? Self.abandonedCopyAge : Self.staleUploadAge
      guard age > limit else { continue }
      if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
  }

  /// Removes every staged body, sidecar and pending cancellation. For logout and local data
  /// reset, after uploads are cancelled: nothing of the account may stay behind, and a send
  /// retried later stages again from its original file.
  @discardableResult
  public func removeAll() -> Int {
    let fileManager = FileManager.default
    guard let urls = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
    var removed = 0
    for url in urls where (try? fileManager.removeItem(at: url)) != nil {
      removed += 1
    }
    return removed
  }

  public func discard(logicalID: String) {
    let baseName = Self.fileName(for: logicalID)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("\(baseName).body"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("\(baseName).json"))
    try? FileManager.default.removeItem(at: root.appendingPathComponent("\(baseName).video.json"))
  }

  public func sourceHash(
    logicalID: String,
    stagedURL: URL,
    compute: @escaping @Sendable (URL) async throws -> (Int64, Data)
  ) async throws -> (Int64, Data) {
    let logicalKey = Self.fileName(for: logicalID)
    let body = root.appendingPathComponent("\(logicalKey).body")
    guard stagedURL.standardizedFileURL == body.standardizedFileURL else {
      throw NativeMediaUploadError.sourceChanged
    }
    try Task.checkCancellation()
    if Self.isSymbolicLink(at: body) {
      do {
        try materializeLegacyBody(at: body)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Optional caching must not break a previously supported durable
        // symlink. Keep its body/sidecars and the prior uncached reader when
        // atomic materialization cannot proceed (for example, low disk space).
        try Task.checkCancellation()
        return try await compute(body)
      }
    }
    let signature = try SourceSignature.read(at: body)
    let descriptor = root.appendingPathComponent("\(logicalKey).json")
    if let descriptorSignature = try? SourceSignature.read(at: descriptor),
       descriptorSignature.byteCount <= 4_096,
       let data = try? Data(contentsOf: descriptor),
       let cached = try? JSONDecoder().decode(CachedSourceHash.self, from: data),
       cached.version == 1, cached.logicalKey == logicalKey,
       cached.signature == signature, cached.sha256.count == 32 {
      return (signature.byteCount, cached.sha256)
    }

    let (byteCount, digest) = try await compute(body)
    try Task.checkCancellation()
    guard signature == (try SourceSignature.read(at: body)),
          byteCount == signature.byteCount, digest.count == 32 else {
      throw NativeMediaUploadError.sourceChanged
    }
    let cached = CachedSourceHash(version: 1, logicalKey: logicalKey, signature: signature, sha256: digest)
    // Hash caching is an optimization. Failure to write this small sidecar must
    // not discard a valid durable body or prevent an otherwise healthy upload.
    if let data = try? JSONEncoder().encode(cached) { try? data.write(to: descriptor, options: .atomic) }
    return (byteCount, digest)
  }

  private func materializeLegacyBody(at body: URL) throws {
    let entrySignature = try SourceSignature.read(at: body, requireRegularFile: false)
    let source = body.resolvingSymlinksInPath()
    let sourceSignature = try SourceSignature.read(at: source)
    try requireCopyCapacity(for: source)
    try Task.checkCancellation()
    let temporary = temporaryStagingURL()
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: source, to: temporary)
    guard sourceSignature == (try SourceSignature.read(at: source)),
          entrySignature == (try SourceSignature.read(at: body, requireRegularFile: false)) else {
      throw NativeMediaUploadError.sourceChanged
    }
    try Task.checkCancellation()
    // Both paths are in the staging directory. POSIX rename atomically replaces
    // only the symlink after the independent copy succeeds; sidecars stay put.
    let result = temporary.withUnsafeFileSystemRepresentation { from in
      body.withUnsafeFileSystemRepresentation { to in rename(from!, to!) }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  private static func isSymbolicLink(at url: URL) -> Bool {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &info) } ?? -1 }
    return result == 0 && info.st_mode & S_IFMT == S_IFLNK
  }

  private func requireCopyCapacity(for source: URL) throws {
    // Only a known cross-device copy justifies a full-allocation refusal.
    // Same-device copies may clone; unknown devices/capacity use copy errors.
    guard copyRequiresFullAllocation(source, root) == true else { return }
    if let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
       let capacity = availableCapacity(root), capacity >= 0, Int64(sourceSize) > capacity {
      throw CocoaError(.fileWriteOutOfSpace, userInfo: [
        NSLocalizedDescriptionKey: "There isn't enough free space to prepare this upload."
      ])
    }
  }

  public func identitySalt(logicalID: String) async throws -> Data {
    let url = root.appendingPathComponent("\(Self.fileName(for: logicalID)).identity")
    guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
    let salt = try Data(contentsOf: url)
    guard salt.count == 16 else { throw NativeMediaUploadError.sourceChanged }
    return salt
  }

  public func invalidateIdentity(logicalID: String) async {
    // A cancelled server owner is terminal. Persist the replacement identity
    // across relaunches while retaining the old identity for recoverable errors.
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var uuid = UUID().uuid
    let salt = withUnsafeBytes(of: &uuid) { Data($0) }
    try? salt.write(to: root.appendingPathComponent("\(Self.fileName(for: logicalID)).identity"), options: .atomic)
  }

  private static func fileName(for logicalID: String) -> String {
    SHA256.hash(data: Data(logicalID.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func fullCopyRequirement(source: URL, destinationRoot: URL) -> Bool? {
    guard let sourceSignature = try? SourceSignature.read(at: source.resolvingSymlinksInPath(), requireRegularFile: false),
          let destinationSignature = try? SourceSignature.read(at: destinationRoot.resolvingSymlinksInPath(), requireRegularFile: false)
    else { return nil }
    return sourceSignature.device != destinationSignature.device
  }

  private static func availableCapacityForCopy(at url: URL) -> Int64? {
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
  }

  private static func defaultRoot() -> URL {
    #if os(iOS)
    if let shared = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.chat.inline"
    ) {
      return shared.appendingPathComponent("NativeUploads", isDirectory: true)
    }
    #endif
    return defaultRoot(
      applicationSupportDirectory: FileHelpers.getApplicationSupportDirectory(),
      bundleIdentifier: Bundle.main.bundleIdentifier,
      userProfile: ProjectConfig.userProfile
    )
  }

  /// On macOS, Application Support is shared by every app and Inline profile outside the
  /// sandbox, so staging is scoped like the media cache: one folder per app and profile, which
  /// logout can empty without touching another profile's sends.
  static func defaultRoot(applicationSupportDirectory: URL, bundleIdentifier: String?, userProfile: String?) -> URL {
    #if os(macOS)
    let profile = userProfile.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    return applicationSupportDirectory
      .appendingPathComponent(bundleIdentifier ?? "chat.inline", isDirectory: true)
      .appendingPathComponent("NativeUploads", isDirectory: true)
      .appendingPathComponent(profile, isDirectory: true)
    #else
    return applicationSupportDirectory.appendingPathComponent("NativeUploads", isDirectory: true)
    #endif
  }

  /// The unscoped folder earlier macOS builds staged into. Other builds and profiles may still
  /// use it, so it only gets the age-based prune every build applies.
  static var legacySharedRoot: URL? {
    #if os(macOS)
    FileHelpers.getApplicationSupportDirectory().appendingPathComponent("NativeUploads", isDirectory: true)
    #else
    nil
    #endif
  }
}

public protocol NativeUploadRPCTransport: Sendable {
  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result?

  /// Opens whatever connection uploads use, ahead of one that is about to start. Best effort.
  func prewarmUploadTransport() async
}

public extension NativeUploadRPCTransport {
  func prewarmUploadTransport() async {}
}

public protocol AccountBoundNativeUploadRPCTransport: NativeUploadRPCTransport {
  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?,
    accountToken: AuthAccountMutationToken
  ) async throws -> RpcResult.OneOf_Result?
}

public protocol NativeUploadAccountFencing: Sendable {
  func beginUploadAccountFence() throws -> AuthAccountMutationToken
  func validateUploadAccountFence(_ token: AuthAccountMutationToken) throws
}

private struct AuthNativeUploadAccountFence: NativeUploadAccountFencing {
  let auth: AuthHandle
  func beginUploadAccountFence() throws -> AuthAccountMutationToken { try auth.beginAccountMutation() }
  func validateUploadAccountFence(_ token: AuthAccountMutationToken) throws {
    try auth.validateAccountMutation(token)
  }
}

extension RealtimeV2: AccountBoundNativeUploadRPCTransport {
  public func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    try await callRpcDirect(method: method, input: input, timeout: timeout)
  }

  public func prewarmUploadTransport() async {
    await prewarmTransfer()
  }

  public func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?,
    accountToken: AuthAccountMutationToken
  ) async throws -> RpcResult.OneOf_Result? {
    try await callRpcDirect(
      method: method, input: input, timeout: timeout, accountToken: accountToken
    )
  }
}

extension RealtimeDirectSession: NativeUploadRPCTransport {
  public func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    try await callRpcDirect(method: method, input: input, timeout: timeout)
  }
}

public enum NativeMediaUploadError: Error, LocalizedError, Sendable, PrivacySafeErrorCategoryProviding {
  case emptySource
  case fileTooLarge
  case invalidGeometry
  case unauthenticated
  case unexpectedResponse
  case processingTimedOut
  case rejected(code: UploadFailure.Code, retryable: Bool)
  case sourceChanged
  case canceled
  case expired

  public var errorDescription: String? {
    switch self {
    case .emptySource: "The upload source is empty."
    case .fileTooLarge: "The upload source exceeds the media size limit."
    case .invalidGeometry: "The server returned invalid upload geometry."
    case .unauthenticated: "An authenticated account is required to upload media."
    case .unexpectedResponse: "The server returned an unexpected upload response."
    case .processingTimedOut: "The file transferred, but processing did not finish in time. Try sending again."
    case let .rejected(code, retryable):
      "Upload processing failed (\(code), retryable: \(retryable))."
    case .sourceChanged: "The upload source changed while it was being read."
    case .canceled: "The upload was canceled."
    case .expired: "The upload expired before it completed."
    }
  }

  public var privacySafeErrorCategory: String {
    switch self {
    case .emptySource: "native_upload:empty_source"
    case .fileTooLarge: "native_upload:file_too_large"
    case .invalidGeometry: "native_upload:invalid_geometry"
    case .unauthenticated: "native_upload:unauthenticated"
    case .unexpectedResponse: "native_upload:unexpected_response"
    case .processingTimedOut: "native_upload:processing_timeout"
    case let .rejected(code, retryable):
      "native_upload:rejected:\(code.rawValue):\(retryable ? "retryable" : "terminal")"
    case .sourceChanged: "native_upload:source_changed"
    case .canceled: "native_upload:canceled"
    case .expired: "native_upload:expired"
    }
  }
}

public actor DurableUploadCoordinator: MediaUploading {
  public static let shared = DurableUploadCoordinator(
    accountFence: AuthNativeUploadAccountFence(auth: Auth.shared.handle),
    remembersServerTraits: true
  )

  private static let hashReadSize = 1_048_576
  /// Upload part size; a file up to this size goes inline with its create (one round trip).
  static let partSize = 524_288
  private static let maximumPartCount: UInt32 = 1_000
  /// Parts in flight across every upload adapt to how long a part takes: grow by one when a part
  /// is accepted within 5 s, halve over 15 s or after a failed attempt. A long round trip alone
  /// is not congestion (a far server needs more parts in flight, not fewer); a part that takes
  /// many seconds means the link is shared too thinly and later parts risk their timeouts.
  /// Telegram runs 3 parallel parts per file, 30 with its boosted setting.
  static let partWindowLimits = 2 ... 8
  static let initialPartWindow = 4
  private static let maximumPartAttempts = 2
  private static let maximumFinishReconciliationAttempts = 3
  // These are individual RPC stall bounds, not a deadline for the complete upload.
  // A large file can span any number of successful part requests.
  private static let mutationTimeout: Duration = .seconds(60)
  private static let stateProbeTimeout: Duration = .seconds(15)
  private static let cancellationCleanupTimeout: Duration = .seconds(5)

  private enum FinishReconciliation {
    case complete(UploadComplete)
    case uploading(Set<UInt32>)
    case processing
    case failed(UploadFailure)
    case canceled
    case expired
  }

  private let log = Log.scoped("NativeUpload")
  private let transport: any NativeUploadRPCTransport
  private let staging: any NativeUploadStaging
  private let ownerScope: @Sendable () -> String?
  private let accountFence: (any NativeUploadAccountFencing)?
  private let processingTimeout: Duration
  private var activePartTransfers = 0
  private(set) var partWindow = DurableUploadCoordinator.initialPartWindow
  private(set) var throughput = NativeUploadThroughput()
  private struct ServerTraits {
    /// The last create used the upload ID this client proposed (servers with pieces, parts sent
    /// ahead of the create reply, and thumbnails at finish).
    var takesClientUploadIDs = false
    var pieceGranularity: Int?
    /// Takes creates without a digest, and a video's size at finish (CreateUploadResult.size_at_finish).
    var takesSizeAtFinish = false
  }

  private nonisolated let serverTraits: OSAllocatedUnfairLock<ServerTraits>
  /// The shared coordinator remembers traits across launches, so the first upload after one
  /// already benefits; any create corrects them.
  private let remembersServerTraits: Bool
  private static let takesClientUploadIDsKey = "nativeUpload.server.takesClientUploadIDs"
  private static let pieceGranularityKey = "nativeUpload.server.pieceGranularity"
  private static let takesSizeAtFinishKey = "nativeUpload.server.takesSizeAtFinish"

  /// Whether this server names thumbnails at finish, learned from earlier creates.
  public nonisolated var acceptsThumbnailAtFinish: Bool { serverTraits.withLock { $0.takesClientUploadIDs } }
  /// Whether this server takes a video's size at finish, so it can upload while it encodes.
  public nonisolated var acceptsSizeAtFinish: Bool { serverTraits.withLock { $0.takesSizeAtFinish } }
  private var retryingPendingCancellations = false
  private struct PartTransferWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }
  private var partTransferWaiters: [PartTransferWaiter] = []
  /// Transfers (parts, and one-part creates) waiting for a slot in the shared window.
  var waitingPartTransfers: Int { partTransferWaiters.count }

  public init(
    transport: any NativeUploadRPCTransport = Api.realtime,
    staging: any NativeUploadStaging = FileNativeUploadStagingStore.shared,
    accountFence: (any NativeUploadAccountFencing)? = nil,
    processingTimeout: Duration = .seconds(600),
    ownerScope: @escaping @Sendable () -> String? = {
      Auth.shared.getCurrentUserId().map(String.init)
    },
    remembersServerTraits: Bool = false
  ) {
    self.transport = transport
    self.staging = staging
    self.accountFence = accountFence
    self.processingTimeout = processingTimeout
    self.ownerScope = ownerScope
    self.remembersServerTraits = remembersServerTraits
    let defaults = UserDefaults.standard
    serverTraits = OSAllocatedUnfairLock(initialState: remembersServerTraits ? ServerTraits(
      takesClientUploadIDs: defaults.bool(forKey: Self.takesClientUploadIDsKey),
      pieceGranularity: defaults.object(forKey: Self.pieceGranularityKey) as? Int,
      takesSizeAtFinish: defaults.bool(forKey: Self.takesSizeAtFinishKey)
    ) : ServerTraits())
  }

  /// Opens the upload connection while the caller still prepares the file (attaching, or encoding a
  /// video), so the first part doesn't also pay its handshake (about seven round trips to the
  /// origin; ~1.4 s measured from Europe). Returns at once; repeating it is cheap.
  public nonisolated func prewarmTransport() {
    let transport = transport
    Task.detached(priority: .utility) {
      await transport.prewarmUploadTransport()
    }
  }

  public func upload(
    _ request: NativeMediaUploadRequest,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> UploadComplete {
    guard let owner = ownerScope() else { throw NativeMediaUploadError.unauthenticated }
    let accountToken = try accountFence?.beginUploadAccountFence()
    try validateAccount(accountToken)
    guard let maximumByteCount = MediaUploadLimits.maximumByteCount(for: request.kind) else {
      throw NativeMediaUploadError.fileTooLarge
    }
    if let sourceValues = try? request.fileURL.resourceValues(forKeys: [.fileSizeKey]),
       let sourceByteCount = sourceValues.fileSize,
       sourceByteCount > maximumByteCount {
      throw NativeMediaUploadError.fileTooLarge
    }
    let ownerScopedLogicalID = "\(owner):\(request.logicalID)"
    try Task.checkCancellation()
    let traitsAtStart = serverTraits.withLock { $0 }
    // A video still encoding streams to a server that takes its size at finish; elsewhere the
    // upload waits for the encode.
    let live = request.kind == .video && traitsAtStart.takesSizeAtFinish ? request.liveSource : nil
    if live == nil, let source = request.liveSource { try await source.waitUntilFinished() }
    // A growing file can't be staged; it can't resume after a relaunch either (its encoder is gone).
    let stagedURL = live != nil ? request.fileURL : try await staging.stage(
      logicalID: ownerScopedLogicalID,
      sourceURL: request.fileURL
    )
    var hasAttemptedCreate = false
    do {
      try Task.checkCancellation()
      try validateAccount(accountToken)
      var byteCount: Int64
      let digest: Data
      if live != nil {
        (byteCount, digest) = (0, Data())
      } else if traitsAtStart.takesSizeAtFinish {
        // This server needs no digest (the transport checks every message); skip reading the file.
        byteCount = Int64(try stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        digest = Data()
      } else {
        (byteCount, digest) = try await staging.sourceHash(
          logicalID: ownerScopedLogicalID, stagedURL: stagedURL, compute: Self.hashFile
        )
      }
      try Task.checkCancellation()
      try validateAccount(accountToken)
      guard byteCount > 0 || live != nil else { throw NativeMediaUploadError.emptySource }
      guard byteCount <= Int64(maximumByteCount) else { throw NativeMediaUploadError.fileTooLarge }

      var create = CreateUploadInput()
      let identitySalt = try await staging.identitySalt(logicalID: ownerScopedLogicalID)
      create.clientUploadID = Self.clientUploadID(
        logicalID: ownerScopedLogicalID,
        // A live upload is new each time: nothing of an earlier attempt can be resumed.
        sourceDigest: live != nil ? Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }) : digest,
        identitySalt: identitySalt
      )
      create.fileName = request.fileName
      create.mimeType = request.mimeType
      // 0 when streaming: the finish names the size.
      create.byteCount = UInt64(byteCount)
      create.sha256 = digest
      create.kind = request.kind
      if let thumbnailFileUniqueID = request.thumbnailFileUniqueID {
        create.thumbnailFileUniqueID = thumbnailFileUniqueID
      }
      create.metadata = request.metadata
      // Picked here, so the first part can go right behind the create (see sendsAhead below).
      let proposedUploadID = Self.proposedUploadID(clientUploadID: create.clientUploadID)
      create.uploadID = proposedUploadID
      // A file that fits in one part and uploads quickly rides along with create, which stores and
      // finishes it in the same call: one round trip instead of create, part and finish. Older
      // servers ignore it and the part uploads as usual. A slower one goes in pieces instead, so
      // progress starts after the first 16 KiB rather than at the end. It takes a part slot like
      // any part, waiting its turn when the window is full (an album).
      // Inline data finishes in create, which a held finish must not do.
      let holdsInlineSlot = request.finishGate == nil && request.thumbnailAtFinish == nil && live == nil &&
        NativeUploadPieces.sendsInline(
        byteCount: byteCount,
        partSize: Int64(Self.partSize),
        bytesPerSecond: throughput.bytesPerSecond
      )
      if holdsInlineSlot {
        try await acquirePartTransferSlot()
        do {
          // The wait can be long: recheck what may have changed during it.
          try validateAccount(accountToken)
          create.inlineData = try await Self.readPart(at: stagedURL, offset: 0, length: Int(byteCount))
        } catch {
          releasePartTransferSlot()
          throw error
        }
      }

      let meter = NativeUploadProgressMeter(total: byteCount, report: progress)
      // A server that took this client's upload IDs before gets the first part without waiting
      // for the create reply: it holds a part for an upload being created until the create lands.
      let traits = serverTraits.withLock { $0 }
      let sendsAhead = traits.takesClientUploadIDs && !holdsInlineSlot && live == nil
      let fileByteCount = byteCount
      let partAhead: Task<Bool, Never>? = sendsAhead ? Task { [self] in
        do {
          _ = try await transferPart(
            0,
            uploadID: proposedUploadID,
            stagedURL: stagedURL,
            partSize: Int64(Self.partSize),
            byteCount: fileByteCount,
            pieceGranularity: traits.pieceGranularity,
            rampUp: true,
            meter: meter,
            accountToken: accountToken
          )
          return true
        } catch {
          return false
        }
      } : nil
      defer { partAhead?.cancel() }

      let createdResult: RpcResult.OneOf_Result?
      hasAttemptedCreate = true
      do {
        defer { if holdsInlineSlot { releasePartTransferSlot() } }
        createdResult = try await callUploadRPC(
          method: .createUpload,
          input: .createUpload(create),
          timeout: Self.mutationTimeout,
          accountToken: accountToken
        )
      } catch {
        try Task.checkCancellation()
        try validateAccount(accountToken)
        // createUpload is idempotent for the stable clientUploadID. Replay once
        // to recover a commit whose response was lost, without adding resume state.
        // The replay goes without the body: if the first attempt stored it, the result reports
        // it accepted or complete; otherwise the part uploads through the ordinary path.
        create.clearInlineData()
        do {
          createdResult = try await callUploadRPC(
            method: .createUpload,
            input: .createUpload(create),
            timeout: Self.mutationTimeout,
            accountToken: accountToken
          )
        } catch {
          // A create without a digest or size goes only to servers that said they take one. One
          // that fails may have reached a server that doesn't (a rollback, a machine mid-deploy):
          // forget the trait so the next attempt sends both, and relearn it from that create.
          if create.sha256.isEmpty || create.byteCount == 0 { forgetSizeAtFinish() }
          throw error
        }
      }
      guard case let .createUpload(created)? = createdResult else {
        throw NativeMediaUploadError.unexpectedResponse
      }
      let tookProposedID = created.uploadID == proposedUploadID
      let granularity = created.hasPieceGranularity ? Int(created.pieceGranularity) : nil
      let sizeAtFinish = created.hasSizeAtFinish && created.sizeAtFinish
      serverTraits.withLock { traits in
        traits.takesClientUploadIDs = tookProposedID
        traits.pieceGranularity = granularity
        traits.takesSizeAtFinish = sizeAtFinish
      }
      if remembersServerTraits {
        UserDefaults.standard.set(tookProposedID, forKey: Self.takesClientUploadIDsKey)
        UserDefaults.standard.set(granularity, forKey: Self.pieceGranularityKey)
        UserDefaults.standard.set(sizeAtFinish, forKey: Self.takesSizeAtFinishKey)
      }
      if !tookProposedID { partAhead?.cancel() }
      let partSize = Int64(created.partSize)
      guard created.uploadID.count == 16,
            partSize == Self.partSize,
            live != nil ? created.partCount == 0 : created.partCount > 0,
            created.partCount <= Self.maximumPartCount,
            Int64(created.partCount) == (byteCount + partSize - 1) / partSize
      else {
        if created.uploadID.count == 16 {
          await cancelAndDiscard(
            uploadID: created.uploadID,
            logicalID: ownerScopedLogicalID,
            accountToken: accountToken
          )
        } else {
          await staging.discard(logicalID: ownerScopedLogicalID)
        }
        throw NativeMediaUploadError.invalidGeometry
      }

      do {
        try Task.checkCancellation()
      } catch is CancellationError {
        await cancelAndDiscard(
          uploadID: created.uploadID,
          logicalID: ownerScopedLogicalID,
          accountToken: accountToken
        )
        throw CancellationError()
      }

      if created.hasComplete {
        try validateAccount(accountToken)
        progress(byteCount, byteCount)
        await staging.discard(logicalID: ownerScopedLogicalID)
        try validateAccount(accountToken)
        return created.complete
      }

      var accepted = Set(created.acceptedParts)
      var partCount = created.partCount
      // Part 0 is already on its way; the loop below sends the rest alongside it.
      var partAheadPending = tookProposedID ? partAhead : nil
      guard accepted.allSatisfy({ $0 < created.partCount }) else {
        await cancelAndDiscard(
          uploadID: created.uploadID,
          logicalID: ownerScopedLogicalID,
          accountToken: accountToken
        )
        throw NativeMediaUploadError.invalidGeometry
      }
      var durableAcceptedBytes = Self.acceptedBytes(
        accepted,
        partSize: partSize,
        total: byteCount
      )
      // Streaming sends whole parts: the server takes no pieces of a last part it can't know.
      let pieceGranularity = created.hasPieceGranularity && live == nil ? Int(created.pieceGranularity) : nil
      try validateAccount(accountToken)
      meter.accepted(durableAcceptedBytes)
      let transferClock = ContinuousClock()
      var transferStartedAt: ContinuousClock.Instant?
      var transferredBytes: Int64 = 0

      var finishReconciliationAttempts = 0
      var missingPartRounds = 0
      var finishThumbnail: String?
      var finishThumbnailResolved = false
      let processingClock = ContinuousClock()
      var processingDeadline: ContinuousClock.Instant?
      do {
        if let live {
          // Parts go as the encoder writes past them; the first, which it rewrites, and the
          // last go below once it's done, like any upload's remaining parts.
          let streamed = try await streamWhileWritten(
            live,
            uploadID: created.uploadID,
            fileURL: stagedURL,
            partSize: partSize,
            maximumByteCount: Int64(maximumByteCount),
            progress: progress,
            accountToken: accountToken
          )
          byteCount = streamed.byteCount
          partCount = UInt32((byteCount + partSize - 1) / partSize)
          accepted = streamed.sent
          meter.setTotal(byteCount)
          durableAcceptedBytes = Self.acceptedBytes(accepted, partSize: partSize, total: byteCount)
          meter.accepted(durableAcceptedBytes)
        }
        while true {
          try Task.checkCancellation()
          let missingParts = (0 ..< partCount).filter {
            !accepted.contains($0) && !(partAheadPending != nil && $0 == 0)
          }
          if !missingParts.isEmpty {
            processingDeadline = nil
            if transferStartedAt == nil { transferStartedAt = transferClock.now }
            // Tasks capture the size as it is now (a live upload learned it above).
            let fileByteCount = byteCount
            try await withThrowingTaskGroup(of: UInt32.self) { group in
              var nextPart = 0
              // Tasks only wait for a slot; the shared window decides how many parts move, and
              // waiters are served in arrival order, so uploads take turns.
              for _ in 0 ..< min(Self.partWindowLimits.upperBound, missingParts.count) {
                let partIndex = missingParts[nextPart]
                // The first part sent ramps up from 16 KiB pieces for an early first progress.
                let rampUp = nextPart == 0 && accepted.isEmpty && partAheadPending == nil
                nextPart += 1
                group.addTask { [self] in
                  try await transferPart(
                    partIndex,
                    uploadID: created.uploadID,
                    stagedURL: stagedURL,
                    partSize: partSize,
                    byteCount: fileByteCount,
                    pieceGranularity: pieceGranularity,
                    rampUp: rampUp,
                    meter: meter,
                    accountToken: accountToken
                  )
                }
              }

              while let partIndex = try await group.next() {
                try Task.checkCancellation()
                accepted.insert(partIndex)
                durableAcceptedBytes = Self.acceptedBytes(
                  accepted,
                  partSize: partSize,
                  total: byteCount
                )
                transferredBytes += min(partSize, byteCount - Int64(partIndex) * partSize)
                try validateAccount(accountToken)
                meter.accepted(durableAcceptedBytes, parts: [partIndex])

                if nextPart < missingParts.count {
                  let nextPartIndex = missingParts[nextPart]
                  nextPart += 1
                  group.addTask { [self] in
                    try await transferPart(
                      nextPartIndex,
                      uploadID: created.uploadID,
                      stagedURL: stagedURL,
                      partSize: partSize,
                      byteCount: fileByteCount,
                      pieceGranularity: pieceGranularity,
                      rampUp: false,
                      meter: meter,
                      accountToken: accountToken
                    )
                  }
                }
              }
            }
            if let transferStartedAt {
              let elapsed = transferClock.now - transferStartedAt
              throughput.record(
                bytes: transferredBytes,
                seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
              )
            }
            finishReconciliationAttempts = 0
          }
          if let ahead = partAheadPending {
            partAheadPending = nil
            // An unstructured task: cancel it with this one, or a cancel would wait out its part.
            if await withTaskCancellationHandler(operation: { await ahead.value }, onCancel: { ahead.cancel() }) {
              accepted.insert(0)
              durableAcceptedBytes = Self.acceptedBytes(accepted, partSize: partSize, total: byteCount)
              meter.accepted(durableAcceptedBytes, parts: [0])
            }
            // Sent again below if it failed.
            continue
          }

          // Every byte is in; an upload started at attach waits here for Send. Canceling the
          // wait cancels the upload, and the server deletes what it has.
          if let finishGate = request.finishGate { try await finishGate.wait() }

          // Healthy part transfers have no overall deadline. Once all bytes are
          // accepted, bound processing separately so a stalled worker cannot
          // keep a send pending forever through successful processing replies.
          let deadline = processingDeadline ?? processingClock.now.advanced(by: processingTimeout)
          processingDeadline = deadline
          guard processingClock.now < deadline else {
            throw NativeMediaUploadError.processingTimedOut
          }

          if let thumbnailAtFinish = request.thumbnailAtFinish, !finishThumbnailResolved {
            // A thumbnail that failed to upload leaves the file without one rather than failing it.
            finishThumbnail = (try? await thumbnailAtFinish()) ?? nil
            finishThumbnailResolved = true
          }
          var finish = FinishUploadInput()
          finish.uploadID = created.uploadID
          if let finishThumbnail { finish.thumbnailFileUniqueID = finishThumbnail }
          if live != nil { finish.byteCount = UInt64(byteCount) }
          let finished: FinishUploadResult
          do {
            let result = try await callUploadRPC(
              method: .finishUpload,
              input: .finishUpload(finish),
              timeout: Self.mutationTimeout,
              accountToken: accountToken
            )
            guard case let .finishUpload(value)? = result,
                  value.state != nil
            else {
              throw NativeMediaUploadError.unexpectedResponse
            }
            finishReconciliationAttempts = 0
            finished = value
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            finishReconciliationAttempts += 1
            guard finishReconciliationAttempts <= Self.maximumFinishReconciliationAttempts else {
              throw error
            }
            switch try await reconcileLostFinish(uploadID: created.uploadID, accountToken: accountToken) {
            case let .complete(complete):
              if durableAcceptedBytes < byteCount {
                try validateAccount(accountToken)
                meter.complete()
              }
              try validateAccount(accountToken)
              await staging.discard(logicalID: ownerScopedLogicalID)
              try validateAccount(accountToken)
              return complete
            case let .uploading(reconciledAccepted):
              guard reconciledAccepted.allSatisfy({ $0 < partCount }) else {
                throw NativeMediaUploadError.invalidGeometry
              }
              accepted = reconciledAccepted
              let reconciledBytes = Self.acceptedBytes(
                accepted,
                partSize: partSize,
                total: byteCount
              )
              if reconciledBytes > durableAcceptedBytes {
                durableAcceptedBytes = reconciledBytes
                try validateAccount(accountToken)
                meter.accepted(durableAcceptedBytes, parts: accepted)
              }
            case .processing:
              // Replay the idempotent finish operation so it can reclaim a stale server lease.
              // A normal processing response below supplies the authoritative retry delay.
              continue
            case let .failed(failure):
              throw NativeMediaUploadError.rejected(
                code: failure.code,
                retryable: failure.retryable
              )
            case .canceled:
              throw NativeMediaUploadError.canceled
            case .expired:
              throw NativeMediaUploadError.expired
            }
            continue
          }
          guard let state = finished.state else {
            throw NativeMediaUploadError.unexpectedResponse
          }
          switch state {
          case let .complete(complete):
            if durableAcceptedBytes < byteCount {
              try validateAccount(accountToken)
              meter.complete()
            }
            try validateAccount(accountToken)
            await staging.discard(logicalID: ownerScopedLogicalID)
            try validateAccount(accountToken)
            return complete
          case let .missing(missing):
            guard !missing.partIndices.isEmpty,
                  missing.partIndices.allSatisfy({ $0 < partCount }) else {
              throw NativeMediaUploadError.invalidGeometry
            }
            missingPartRounds += 1
            guard missingPartRounds <= Self.maximumMissingPartRounds else {
              throw NativeMediaUploadError.unexpectedResponse
            }
            accepted.subtract(missing.partIndices)
          case let .processing(processing):
            let nextPoll = processingClock.now.advanced(by: .seconds(boundedUploadProcessingRetrySeconds(
              processing.retryAfterSeconds
            )))
            try await Task.sleep(until: min(nextPoll, deadline), clock: processingClock)
          case let .failed(failure):
            throw NativeMediaUploadError.rejected(
              code: failure.code,
              retryable: failure.retryable
            )
          }
        }
      } catch {
        // A live upload can't resume (its encoder is gone): any failure ends it.
        if Task.isCancelled || live != nil || Self.isTerminalFailure(error) || !isAccountCurrent(accountToken) {
          await cancelAndDiscard(
            uploadID: created.uploadID,
            logicalID: ownerScopedLogicalID,
            accountToken: accountToken
          )
        }
        throw error
      }
    } catch {
      // Before create, no durable server owner can recover this staging body.
      // After any create attempt, the stable clientUploadID may already own a
      // committed upload even when both bounded responses were lost.
      if !hasAttemptedCreate {
        await staging.discard(logicalID: ownerScopedLogicalID)
      }
      throw error
    }
  }

  private static func isTerminalFailure(_ error: any Error) -> Bool {
    guard let error = error as? NativeMediaUploadError else { return false }
    switch error {
    case .invalidGeometry, .sourceChanged, .canceled, .expired, .emptySource, .fileTooLarge: return true
    case let .rejected(_, retryable): return !retryable
    case .processingTimedOut:
      // The server may still complete; retain the source for an explicit retry.
      return false
    case .unauthenticated, .unexpectedResponse: return false
    }
  }

  private func cancelAndDiscard(
    uploadID: Data,
    logicalID: String,
    accountToken: AuthAccountMutationToken?
  ) async {
    var cancel = CancelUploadInput()
    cancel.uploadID = uploadID
    let transport = transport
    let accountFence = accountFence
    let owner = accountToken.map { String($0.userID) } ?? String(logicalID.split(separator: ":").first ?? "")
    await staging.recordPendingCancellation(uploadID: uploadID, owner: owner)
    await staging.invalidateIdentity(logicalID: logicalID)
    // The upload task is already cancelled, but cancellation has one terminal owner. Give that
    // owner a short, awaited, non-cancelled window to release server staging before its transport
    // is torn down. Failure remains best effort and server TTL is the safety net.
    let canceled = await Task.detached { () -> Bool in
      if let accountToken {
        guard let boundTransport = transport as? any AccountBoundNativeUploadRPCTransport else { return false }
        do {
          try accountFence?.validateUploadAccountFence(accountToken)
          let result = try await boundTransport.callUploadRPC(
            method: .cancelUpload,
            input: .cancelUpload(cancel),
            timeout: Self.cancellationCleanupTimeout,
            accountToken: accountToken
          )
          try accountFence?.validateUploadAccountFence(accountToken)
          guard case .cancelUpload? = result else { return false }
          return true
        } catch { return false }
      } else {
        let result = try? await transport.callUploadRPC(
          method: .cancelUpload,
          input: .cancelUpload(cancel),
          timeout: Self.cancellationCleanupTimeout
        )
        guard case .cancelUpload? = result else { return false }
        return true
      }
    }.value
    if canceled { await staging.removePendingCancellation(uploadID: uploadID, owner: owner) }
    await staging.discard(logicalID: logicalID)
  }

  public func retryPendingCancellations() async {
    guard !retryingPendingCancellations, let owner = ownerScope() else { return }
    let token: AuthAccountMutationToken?
    do { token = try accountFence?.beginUploadAccountFence() } catch { return }
    retryingPendingCancellations = true
    defer { retryingPendingCancellations = false }
    for uploadID in await staging.pendingCancellationIDs(owner: owner) {
      do {
        try Task.checkCancellation()
        try validateAccount(token)
        var input = CancelUploadInput()
        input.uploadID = uploadID
        let result = try await callUploadRPC(
          method: .cancelUpload, input: .cancelUpload(input),
          timeout: Self.cancellationCleanupTimeout, accountToken: token
        )
        try validateAccount(token)
        guard case .cancelUpload? = result else { continue }
        await staging.removePendingCancellation(uploadID: uploadID, owner: owner)
      } catch {
        guard isAccountCurrent(token), !Task.isCancelled else { return }
        if let error = error as? RealtimeDirectRpcError,
           case let .rpcError(_, _, code) = error, [400, 401, 403, 404, 410].contains(code) {
          // This owner is no longer addressable (expired or belongs to an old
          // session). It must not block later, still-active cancellations.
          await staging.removePendingCancellation(uploadID: uploadID, owner: owner)
          continue
        }
        return
      }
    }
  }

  private func uploadState(
    uploadID: Data,
    accountToken: AuthAccountMutationToken?
  ) async throws -> GetUploadStateResult {
    var input = GetUploadStateInput()
    input.uploadID = uploadID
    let result = try await callUploadRPC(
      method: .getUploadState,
      input: .getUploadState(input),
      timeout: Self.stateProbeTimeout,
      accountToken: accountToken
    )
    guard case let .getUploadState(state)? = result else {
      throw NativeMediaUploadError.unexpectedResponse
    }
    return state
  }

  private func reconcileLostFinish(
    uploadID: Data,
    accountToken: AuthAccountMutationToken?
  ) async throws -> FinishReconciliation {
    let state = try await uploadState(uploadID: uploadID, accountToken: accountToken)
    switch state.status {
    case .complete:
      guard state.hasComplete else { throw NativeMediaUploadError.unexpectedResponse }
      return .complete(state.complete)
    case .uploading:
      return .uploading(Set(state.acceptedParts))
    case .processing:
      return .processing
    case .failed:
      guard state.hasFailure else { throw NativeMediaUploadError.unexpectedResponse }
      return .failed(state.failure)
    case .canceled:
      return .canceled
    case .expired:
      return .expired
    case .unspecified, .UNRECOGNIZED:
      throw NativeMediaUploadError.unexpectedResponse
    }
  }

  private enum StreamEvent: Sendable {
    case sent(UInt32, Data)
    case tick
  }

  /// How often a live upload checks how far its file has grown.
  static let liveGrowthPollInterval: Duration = .milliseconds(100)

  /// Sends each part of a growing file once the writer has written past it, except the first
  /// (the writer rewrites the MP4 header's size there at the end). Returns when the file is final,
  /// with its size and the parts sent. A sent part that changed afterwards fails the upload with
  /// `sourceChanged` (the caller uploads the finished file instead).
  private func streamWhileWritten(
    _ live: NativeLiveUploadSource,
    uploadID: Data,
    fileURL: URL,
    partSize: Int64,
    maximumByteCount: Int64,
    progress: @escaping @Sendable (Int64, Int64) -> Void,
    accountToken: AuthAccountMutationToken?
  ) async throws -> (byteCount: Int64, sent: Set<UInt32>) {
    var sentHashes: [UInt32: Data] = [:]
    try await withThrowingTaskGroup(of: StreamEvent.self) { group in
      var nextPart: UInt32 = 1
      var inFlight = 0
      var tickPending = false
      while true {
        try Task.checkCancellation()
        let outcome = live.result
        if case let .failure(error)? = outcome { throw error }
        let written = Self.fileSize(fileURL)
        guard written <= maximumByteCount else { throw NativeMediaUploadError.fileTooLarge }
        if outcome == nil {
          // Parts wholly written are final, except the first.
          let ready = UInt32(written / partSize)
          while nextPart < ready, inFlight < Self.partWindowLimits.upperBound {
            let partIndex = nextPart
            nextPart += 1
            inFlight += 1
            group.addTask { [self] in
              let data = try await Self.readPart(
                at: fileURL, offset: UInt64(Int64(partIndex) * partSize), length: Int(partSize)
              )
              _ = try await transferPart(
                partIndex,
                uploadID: uploadID,
                stagedURL: fileURL,
                partSize: partSize,
                byteCount: Int64(partIndex + 1) * partSize,
                accountToken: accountToken
              )
              return .sent(partIndex, Data(SHA256.hash(data: data)))
            }
          }
          if !tickPending {
            tickPending = true
            group.addTask {
              try await Task.sleep(for: Self.liveGrowthPollInterval)
              return .tick
            }
          }
        } else if inFlight == 0 {
          group.cancelAll()
          break
        }
        guard let event = try await group.next() else { break }
        switch event {
        case .tick:
          tickPending = false
        case let .sent(partIndex, hash):
          inFlight -= 1
          sentHashes[partIndex] = hash
          let sentBytes = Int64(sentHashes.count) * partSize
          progress(sentBytes, max(sentBytes, Self.fileSize(fileURL)))
        }
      }
    }
    let byteCount = Self.fileSize(fileURL)
    guard byteCount > 0 else { throw NativeMediaUploadError.emptySource }
    guard byteCount <= maximumByteCount else { throw NativeMediaUploadError.fileTooLarge }
    // The writer is expected to touch only the first part at the end; prove nothing sent moved.
    for (partIndex, hash) in sentHashes {
      let offset = Int64(partIndex) * partSize
      guard offset + partSize <= byteCount else { throw NativeMediaUploadError.sourceChanged }
      let data = try await Self.readPart(at: fileURL, offset: UInt64(offset), length: Int(partSize))
      guard Data(SHA256.hash(data: data)) == hash else { throw NativeMediaUploadError.sourceChanged }
    }
    return (byteCount, Set(sentHashes.keys))
  }

  /// The file's current size; `stat`, since URL resource values are cached and the file grows.
  private func forgetSizeAtFinish() {
    serverTraits.withLock { $0.takesSizeAtFinish = false }
    if remembersServerTraits { UserDefaults.standard.set(false, forKey: Self.takesSizeAtFinishKey) }
  }

  private static func fileSize(_ url: URL) -> Int64 {
    var info = stat()
    return stat(url.path, &info) == 0 ? Int64(info.st_size) : 0
  }

  private func transferPart(
    _ partIndex: UInt32,
    uploadID: Data,
    stagedURL: URL,
    partSize: Int64,
    byteCount: Int64,
    pieceGranularity: Int? = nil,
    rampUp: Bool = false,
    meter: NativeUploadProgressMeter? = nil,
    accountToken: AuthAccountMutationToken?
  ) async throws -> UInt32 {
    try Task.checkCancellation()
    let startedAt = ProcessInfo.processInfo.systemUptime
    let offset = Int64(partIndex) * partSize
    let length = Int(min(partSize, byteCount - offset))
    let slotStartedAt = ProcessInfo.processInfo.systemUptime
    try await acquirePartTransferSlot()
    let slotWaitMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - slotStartedAt) * 1_000
    )
    var partLatency: Duration?
    var attemptFailed = false
    defer { releasePartTransferSlot(latency: partLatency, attemptFailed: attemptFailed) }
    try Task.checkCancellation()
    let readStartedAt = ProcessInfo.processInfo.systemUptime
    let data = try await Self.readPart(
      at: stagedURL,
      offset: UInt64(offset),
      length: length
    )
    try validateAccount(accountToken)
    let readMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - readStartedAt) * 1_000
    )
    var save = SaveUploadPartInput()
    save.uploadID = uploadID
    save.partIndex = partIndex
    save.data = data

    try Task.checkCancellation()
    let rpcStartedAt = ProcessInfo.processInfo.systemUptime
    log.debug(
      "Part dispatch started part=\(partIndex) bytes=\(length) active=\(activePartTransfers) read_ms=\(readMilliseconds) slot_wait_ms=\(slotWaitMilliseconds)"
    )
    let pieces = pieceGranularity.flatMap {
      NativeUploadPieces.ranges(partLength: length, granularity: $0, rampUp: rampUp)
    }
    var accepted = false
    for attempt in 0 ..< Self.maximumPartAttempts {
      try Task.checkCancellation()
      do {
        // A retry sends the part whole: a server mid-deploy may not take pieces.
        if let pieces, pieces.count > 1, attempt == 0 {
          try await savePieces(
            pieces, of: data, partIndex: partIndex, uploadID: uploadID, meter: meter,
            accountToken: accountToken
          )
        } else {
          let result = try await callUploadRPC(
            method: .saveUploadPart,
            input: .saveUploadPart(save),
            timeout: Self.mutationTimeout,
            accountToken: accountToken
          )
          guard case .saveUploadPart? = result else {
            throw NativeMediaUploadError.unexpectedResponse
          }
        }
        accepted = true
        break
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let saveError = error
        meter?.partReset(partIndex)
        try Task.checkCancellation()
        attemptFailed = true
        let state: GetUploadStateResult
        do {
          state = try await uploadState(uploadID: uploadID, accountToken: accountToken)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          throw saveError
        }
        try Task.checkCancellation()
        if state.acceptedParts.contains(partIndex) {
          accepted = true
          break
        }
        // The server's verdict is final for this upload: surface it so the caller rotates
        // the identity instead of retrying a dead upload with the raw transport error.
        switch state.status {
          case .expired: throw NativeMediaUploadError.expired
          case .canceled: throw NativeMediaUploadError.canceled
          case .failed:
            throw NativeMediaUploadError.rejected(
              code: state.failure.code,
              retryable: state.hasFailure && state.failure.retryable
            )
          default: break
        }
        guard state.status == .uploading,
              attempt + 1 < Self.maximumPartAttempts
        else { throw saveError }
        // State proved this part is still missing. Stagger the bounded retry
        // so several uploads do not immediately repeat a capacity/provider burst.
        try await Task.sleep(for: .milliseconds(Int.random(in: 200 ... 400)))
      }
    }
    guard accepted else { throw NativeMediaUploadError.unexpectedResponse }
    try Task.checkCancellation()
    let rpcMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - rpcStartedAt) * 1_000
    )
    partLatency = .milliseconds(rpcMilliseconds)
    let totalMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    )
    log.debug(
      "Part accepted part=\(partIndex) bytes=\(length) rpc_ms=\(rpcMilliseconds) total_ms=\(totalMilliseconds)"
    )
    return partIndex
  }

  /// Sends one part as pieces, all at once; the transport writes them in order and the server
  /// replies to each as it arrives. Throws on the first failed piece.
  private func savePieces(
    _ pieces: [Range<Int>],
    of data: Data,
    partIndex: UInt32,
    uploadID: Data,
    meter: NativeUploadProgressMeter?,
    accountToken: AuthAccountMutationToken?
  ) async throws {
    try await withThrowingTaskGroup(of: Int.self) { group in
      for piece in pieces {
        var save = SaveUploadPartInput()
        save.uploadID = uploadID
        save.partIndex = partIndex
        save.offset = UInt32(piece.lowerBound)
        save.data = data.subdata(in: (data.startIndex + piece.lowerBound) ..< (data.startIndex + piece.upperBound))
        let request = save
        group.addTask { [self] in
          let result = try await callUploadRPC(
            method: .saveUploadPart,
            input: .saveUploadPart(request),
            timeout: Self.mutationTimeout,
            accountToken: accountToken
          )
          guard case .saveUploadPart? = result else {
            throw NativeMediaUploadError.unexpectedResponse
          }
          return piece.count
        }
      }
      while let bytes = try await group.next() {
        meter?.pieceAcknowledged(part: partIndex, bytes: Int64(bytes))
      }
    }
  }

  private func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?,
    accountToken: AuthAccountMutationToken?
  ) async throws -> RpcResult.OneOf_Result? {
    guard let accountToken else {
      return try await transport.callUploadRPC(method: method, input: input, timeout: timeout)
    }
    try validateAccount(accountToken)
    guard let boundTransport = transport as? any AccountBoundNativeUploadRPCTransport else {
      throw NativeMediaUploadError.unauthenticated
    }
    let result = try await boundTransport.callUploadRPC(
      method: method,
      input: input,
      timeout: timeout,
      accountToken: accountToken
    )
    try validateAccount(accountToken)
    return result
  }

  private func validateAccount(_ accountToken: AuthAccountMutationToken?) throws {
    if let accountToken { try accountFence?.validateUploadAccountFence(accountToken) }
  }

  private func isAccountCurrent(_ accountToken: AuthAccountMutationToken?) -> Bool {
    do {
      try validateAccount(accountToken)
      return true
    } catch {
      return false
    }
  }

  private func acquirePartTransferSlot() async throws {
    try Task.checkCancellation()
    guard activePartTransfers >= partWindow || !partTransferWaiters.isEmpty else {
      activePartTransfers += 1
      return
    }

    let waiterID = UUID()
    let granted = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // The cancellation handler hops back to this actor. Re-check while actor-isolated
        // registration is synchronous so cancellation cannot run before the waiter exists.
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        partTransferWaiters.append(
          PartTransferWaiter(id: waiterID, continuation: continuation)
        )
      }
    } onCancel: {
      Task { await self.cancelPartTransferWaiter(waiterID) }
    }
    guard granted else { throw CancellationError() }
    if Task.isCancelled {
      releasePartTransferSlot()
      throw CancellationError()
    }
  }

  /// Returns a slot. A part that was accepted adapts the window to its latency; one that needed
  /// another attempt halves it.
  private func releasePartTransferSlot(latency: Duration? = nil, attemptFailed: Bool = false) {
    activePartTransfers -= 1
    if attemptFailed {
      partWindow = max(partWindow / 2, Self.partWindowLimits.lowerBound)
    } else if let latency {
      partWindow = Self.adaptedPartWindow(partWindow, after: latency)
    }
    while activePartTransfers < partWindow, !partTransferWaiters.isEmpty {
      activePartTransfers += 1
      partTransferWaiters.removeFirst().continuation.resume(returning: true)
    }
  }

  static func adaptedPartWindow(_ window: Int, after latency: Duration) -> Int {
    if latency < .seconds(5) { return min(window + 1, partWindowLimits.upperBound) }
    if latency > .seconds(15) { return max(window / 2, partWindowLimits.lowerBound) }
    return window
  }

  /// Rounds of re-sending parts the server reports missing at finish before the attempt fails
  /// (and the send retries with a fresh state probe), so a server that keeps losing parts can't
  /// hold a send forever.
  static let maximumMissingPartRounds = 3

  private func cancelPartTransferWaiter(_ id: UUID) {
    guard let index = partTransferWaiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = partTransferWaiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }

  @concurrent
  private static func hashFile(at url: URL) async throws -> (Int64, Data) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var byteCount: Int64 = 0
    while true {
      try Task.checkCancellation()
      let data = try handle.read(upToCount: hashReadSize) ?? Data()
      guard !data.isEmpty else { break }
      byteCount += Int64(data.count)
      hash.update(data: data)
    }
    return (byteCount, Data(hash.finalize()))
  }

  @concurrent
  private static func readPart(at url: URL, offset: UInt64, length: Int) async throws -> Data {
    try Task.checkCancellation()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    let data = try handle.read(upToCount: length) ?? Data()
    try Task.checkCancellation()
    guard data.count == length else { throw NativeMediaUploadError.sourceChanged }
    return data
  }

  /// The upload ID proposed with create: fixed per client upload ID, so a replayed create proposes
  /// the same one.
  static func proposedUploadID(clientUploadID: Data) -> Data {
    var hash = SHA256()
    hash.update(data: Data("inline-native-upload-id-v1:".utf8))
    hash.update(data: clientUploadID)
    return Data(hash.finalize().prefix(16))
  }

  private static func clientUploadID(logicalID: String, sourceDigest: Data, identitySalt: Data) -> Data {
    var hash = SHA256()
    hash.update(data: Data("inline-native-upload-v1:\(logicalID):".utf8))
    hash.update(data: sourceDigest)
    hash.update(data: identitySalt)
    return Data(hash.finalize().prefix(16))
  }

  private static func acceptedBytes(
    _ accepted: Set<UInt32>,
    partSize: Int64,
    total: Int64
  ) -> Int64 {
    accepted.reduce(into: 0) { bytes, index in
      let offset = Int64(index) * partSize
      bytes += min(partSize, total - offset)
    }
  }
}
