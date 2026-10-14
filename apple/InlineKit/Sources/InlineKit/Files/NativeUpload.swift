import CryptoKit
import Darwin
import Foundation
import Auth
import InlineProtocol
import Logger
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

public struct NativeMediaUploadRequest: Sendable {
  public let logicalID: String
  public let fileURL: URL
  public let fileName: String
  public let mimeType: String
  public let kind: UploadKind
  public let thumbnailFileUniqueID: String?
  public let metadata: CreateUploadInput.OneOf_Metadata?

  public init(
    logicalID: String,
    fileURL: URL,
    fileName: String,
    mimeType: String,
    kind: UploadKind,
    thumbnailFileUniqueID: String? = nil,
    metadata: CreateUploadInput.OneOf_Metadata? = nil
  ) {
    self.logicalID = logicalID
    self.fileURL = fileURL
    self.fileName = fileName
    self.mimeType = mimeType
    self.kind = kind
    self.thumbnailFileUniqueID = thumbnailFileUniqueID
    self.metadata = metadata
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
    let fileName: String
    let mimeType: String
    let width: Int
    let height: Int
    let duration: Int
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

    let temporary = root.appendingPathComponent("staging-\(UUID().uuidString)")
    do {
      try fileManager.copyItem(at: copySource, to: temporary)
      try fileManager.moveItem(at: temporary, to: destination)
      return destination
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
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
    let temporary = root.appendingPathComponent("staging-\(UUID().uuidString)")
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
    let fileManager = FileManager.default
    #if os(iOS)
    if let shared = fileManager.containerURL(
      forSecurityApplicationGroupIdentifier: "group.chat.inline"
    ) {
      return shared.appendingPathComponent("NativeUploads", isDirectory: true)
    }
    #endif
    return FileHelpers.getApplicationSupportDirectory()
      .appendingPathComponent("NativeUploads", isDirectory: true)
  }
}

public protocol NativeUploadRPCTransport: Sendable {
  func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result?
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
    accountFence: AuthNativeUploadAccountFence(auth: Auth.shared.handle)
  )

  private static let hashReadSize = 1_048_576
  private static let partSize = 524_288
  private static let maximumPartCount: UInt32 = 1_000
  private static let maximumConcurrentPartsPerUpload = 2
  private static let maximumConcurrentParts = 3
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
  private var retryingPendingCancellations = false
  private struct PartTransferWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }
  private var partTransferWaiters: [PartTransferWaiter] = []

  public init(
    transport: any NativeUploadRPCTransport = Api.realtime,
    staging: any NativeUploadStaging = FileNativeUploadStagingStore.shared,
    accountFence: (any NativeUploadAccountFencing)? = nil,
    processingTimeout: Duration = .seconds(600),
    ownerScope: @escaping @Sendable () -> String? = {
      Auth.shared.getCurrentUserId().map(String.init)
    }
  ) {
    self.transport = transport
    self.staging = staging
    self.accountFence = accountFence
    self.processingTimeout = processingTimeout
    self.ownerScope = ownerScope
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
    let stagedURL = try await staging.stage(
      logicalID: ownerScopedLogicalID,
      sourceURL: request.fileURL
    )
    var hasAttemptedCreate = false
    do {
      try Task.checkCancellation()
      try validateAccount(accountToken)
      let byteCount: Int64
      let digest: Data
      (byteCount, digest) = try await staging.sourceHash(
        logicalID: ownerScopedLogicalID, stagedURL: stagedURL, compute: Self.hashFile
      )
      try Task.checkCancellation()
      try validateAccount(accountToken)
      guard byteCount > 0 else { throw NativeMediaUploadError.emptySource }
      guard byteCount <= Int64(maximumByteCount) else { throw NativeMediaUploadError.fileTooLarge }

      var create = CreateUploadInput()
      let identitySalt = try await staging.identitySalt(logicalID: ownerScopedLogicalID)
      create.clientUploadID = Self.clientUploadID(
        logicalID: ownerScopedLogicalID,
        sourceDigest: digest,
        identitySalt: identitySalt
      )
      create.fileName = request.fileName
      create.mimeType = request.mimeType
      create.byteCount = UInt64(byteCount)
      create.sha256 = digest
      create.kind = request.kind
      if let thumbnailFileUniqueID = request.thumbnailFileUniqueID {
        create.thumbnailFileUniqueID = thumbnailFileUniqueID
      }
      create.metadata = request.metadata

      let createdResult: RpcResult.OneOf_Result?
      hasAttemptedCreate = true
      do {
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
        createdResult = try await callUploadRPC(
          method: .createUpload,
          input: .createUpload(create),
          timeout: Self.mutationTimeout,
          accountToken: accountToken
        )
      }
      guard case let .createUpload(created)? = createdResult else {
        throw NativeMediaUploadError.unexpectedResponse
      }
      let partSize = Int64(created.partSize)
      guard created.uploadID.count == 16,
            partSize == Self.partSize,
            created.partCount > 0,
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

      var accepted = Set(created.acceptedParts)
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
      try validateAccount(accountToken)
      progress(durableAcceptedBytes, byteCount)

      var finishReconciliationAttempts = 0
      let processingClock = ContinuousClock()
      var processingDeadline: ContinuousClock.Instant?
      do {
        while true {
          try Task.checkCancellation()
          let missingParts = (0 ..< created.partCount).filter { !accepted.contains($0) }
          if !missingParts.isEmpty {
            processingDeadline = nil
            try await withThrowingTaskGroup(of: UInt32.self) { group in
              var nextPart = 0
              for _ in 0 ..< min(Self.maximumConcurrentPartsPerUpload, missingParts.count) {
                let partIndex = missingParts[nextPart]
                nextPart += 1
                group.addTask { [self] in
                  try await transferPart(
                    partIndex,
                    uploadID: created.uploadID,
                    stagedURL: stagedURL,
                    partSize: partSize,
                    byteCount: byteCount,
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
                try validateAccount(accountToken)
                progress(durableAcceptedBytes, byteCount)

                if nextPart < missingParts.count {
                  let nextPartIndex = missingParts[nextPart]
                  nextPart += 1
                  group.addTask { [self] in
                    try await transferPart(
                      nextPartIndex,
                      uploadID: created.uploadID,
                      stagedURL: stagedURL,
                      partSize: partSize,
                      byteCount: byteCount,
                      accountToken: accountToken
                    )
                  }
                }
              }
            }
            finishReconciliationAttempts = 0
          }

          // Healthy part transfers have no overall deadline. Once all bytes are
          // accepted, bound processing separately so a stalled worker cannot
          // keep a send pending forever through successful processing replies.
          let deadline = processingDeadline ?? processingClock.now.advanced(by: processingTimeout)
          processingDeadline = deadline
          guard processingClock.now < deadline else {
            throw NativeMediaUploadError.processingTimedOut
          }

          var finish = FinishUploadInput()
          finish.uploadID = created.uploadID
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
                progress(byteCount, byteCount)
              }
              try validateAccount(accountToken)
              await staging.discard(logicalID: ownerScopedLogicalID)
              try validateAccount(accountToken)
              return complete
            case let .uploading(reconciledAccepted):
              guard reconciledAccepted.allSatisfy({ $0 < created.partCount }) else {
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
                progress(durableAcceptedBytes, byteCount)
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
              progress(byteCount, byteCount)
            }
            try validateAccount(accountToken)
            await staging.discard(logicalID: ownerScopedLogicalID)
            try validateAccount(accountToken)
            return complete
          case let .missing(missing):
            guard !missing.partIndices.isEmpty,
                  missing.partIndices.allSatisfy({ $0 < created.partCount }) else {
              throw NativeMediaUploadError.invalidGeometry
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
        if Task.isCancelled || Self.isTerminalFailure(error) || !isAccountCurrent(accountToken) {
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

  private func transferPart(
    _ partIndex: UInt32,
    uploadID: Data,
    stagedURL: URL,
    partSize: Int64,
    byteCount: Int64,
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
    defer { releasePartTransferSlot() }
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
    var accepted = false
    for attempt in 0 ..< Self.maximumPartAttempts {
      try Task.checkCancellation()
      do {
        let result = try await callUploadRPC(
          method: .saveUploadPart,
          input: .saveUploadPart(save),
          timeout: Self.mutationTimeout,
          accountToken: accountToken
        )
        guard case .saveUploadPart? = result else {
          throw NativeMediaUploadError.unexpectedResponse
        }
        accepted = true
        break
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let saveError = error
        try Task.checkCancellation()
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
    let totalMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    )
    log.debug(
      "Part accepted part=\(partIndex) bytes=\(length) rpc_ms=\(rpcMilliseconds) total_ms=\(totalMilliseconds)"
    )
    return partIndex
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
    guard activePartTransfers >= Self.maximumConcurrentParts else {
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

  private func releasePartTransferSlot() {
    if partTransferWaiters.isEmpty {
      activePartTransfers -= 1
    } else {
      partTransferWaiters.removeFirst().continuation.resume(returning: true)
    }
  }

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
