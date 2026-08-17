import CryptoKit
import Foundation
import Auth
import InlineProtocol
import RealtimeV2

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
  func recordProgress(logicalID: String, acceptedBytes: Int64, totalBytes: Int64) async
  func discard(logicalID: String) async
}

/// Owns immutable upload sources independently of picker URLs and preprocessing temporaries.
/// iOS and its Share Extension use the app-group container; macOS falls back to Application Support.
public actor FileNativeUploadStagingStore: NativeUploadStaging {
  public static let shared = FileNativeUploadStagingStore()

  private let root: URL

  private struct ProgressRecord: Codable {
    let acceptedBytes: Int64
    let totalBytes: Int64
    let updatedAt: Date
  }

  public init(root: URL? = nil) {
    self.root = root ?? Self.defaultRoot()
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

    let temporary = root.appendingPathComponent("staging-\(UUID().uuidString)")
    do {
      try fileManager.copyItem(at: sourceURL, to: temporary)
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
  }

  public func recordProgress(
    logicalID: String,
    acceptedBytes: Int64,
    totalBytes: Int64
  ) {
    let baseName = Self.fileName(for: logicalID)
    let record = ProgressRecord(
      acceptedBytes: max(0, min(acceptedBytes, totalBytes)),
      totalBytes: max(0, totalBytes),
      updatedAt: Date()
    )
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? data.write(
      to: root.appendingPathComponent("\(baseName).json"),
      options: .atomic
    )
  }

  private static func fileName(for logicalID: String) -> String {
    SHA256.hash(data: Data(logicalID.utf8)).map { String(format: "%02x", $0) }.joined()
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

extension RealtimeV2: NativeUploadRPCTransport {
  public func callUploadRPC(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> RpcResult.OneOf_Result? {
    try await callRpcDirect(method: method, input: input, timeout: timeout)
  }
}

public enum NativeMediaUploadError: Error, LocalizedError, Sendable {
  case emptySource
  case invalidGeometry
  case unauthenticated
  case unexpectedResponse
  case rejected(code: UploadFailure.Code, retryable: Bool)
  case sourceChanged

  public var errorDescription: String? {
    switch self {
    case .emptySource: "The upload source is empty."
    case .invalidGeometry: "The server returned invalid upload geometry."
    case .unauthenticated: "An authenticated account is required to upload media."
    case .unexpectedResponse: "The server returned an unexpected upload response."
    case let .rejected(code, retryable):
      "Upload processing failed (\(code), retryable: \(retryable))."
    case .sourceChanged: "The upload source changed while it was being read."
    }
  }
}

public actor DurableUploadCoordinator: MediaUploading {
  public static let shared = DurableUploadCoordinator()

  private static let hashReadSize = 1_048_576
  private static let maximumPartSize = 16 * 1_048_576

  private let transport: any NativeUploadRPCTransport
  private let staging: any NativeUploadStaging
  private let ownerScope: @Sendable () -> String?
  private var activePartTransfers = 0
  private var partTransferWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    transport: any NativeUploadRPCTransport = Api.realtime,
    staging: any NativeUploadStaging = FileNativeUploadStagingStore.shared,
    ownerScope: @escaping @Sendable () -> String? = {
      Auth.shared.getCurrentUserId().map(String.init)
    }
  ) {
    self.transport = transport
    self.staging = staging
    self.ownerScope = ownerScope
  }

  public func upload(
    _ request: NativeMediaUploadRequest,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> UploadComplete {
    guard let owner = ownerScope() else { throw NativeMediaUploadError.unauthenticated }
    let ownerScopedLogicalID = "\(owner):\(request.logicalID)"
    let stagedURL = try await staging.stage(
      logicalID: ownerScopedLogicalID,
      sourceURL: request.fileURL
    )
    let (byteCount, digest) = try Self.hashFile(at: stagedURL)
    guard byteCount > 0 else {
      await staging.discard(logicalID: ownerScopedLogicalID)
      throw NativeMediaUploadError.emptySource
    }

    var create = CreateUploadInput()
    create.clientUploadID = Self.clientUploadID(
      logicalID: ownerScopedLogicalID,
      sourceDigest: digest
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

    let createdResult = try await transport.callUploadRPC(
      method: .createUpload,
      input: .createUpload(create),
      timeout: .seconds(60)
    )
    guard case let .createUpload(created)? = createdResult else {
      throw NativeMediaUploadError.unexpectedResponse
    }
    let partSize = Int64(created.partSize)
    let expectedPartCount = (byteCount + partSize - 1) / partSize
    guard created.uploadID.count == 16,
          partSize > 0,
          partSize <= Self.maximumPartSize,
          created.partCount > 0,
          Int64(created.partCount) == expectedPartCount
    else {
      throw NativeMediaUploadError.invalidGeometry
    }

    var accepted = Set(created.acceptedParts)
    guard accepted.allSatisfy({ $0 < created.partCount }) else {
      throw NativeMediaUploadError.invalidGeometry
    }
    var durableAcceptedBytes = Self.acceptedBytes(
      accepted,
      partSize: partSize,
      total: byteCount
    )
    await staging.recordProgress(
      logicalID: ownerScopedLogicalID,
      acceptedBytes: durableAcceptedBytes,
      totalBytes: byteCount
    )
    progress(durableAcceptedBytes, byteCount)

    do {
      while true {
        for partIndex in 0 ..< created.partCount where !accepted.contains(partIndex) {
          try Task.checkCancellation()
          let offset = Int64(partIndex) * partSize
          let length = Int(min(partSize, byteCount - offset))
          let data = try Self.readPart(
            at: stagedURL,
            offset: UInt64(offset),
            length: length
          )
          var save = SaveUploadPartInput()
          save.uploadID = created.uploadID
          save.partIndex = partIndex
          save.data = data
          await acquirePartTransferSlot()
          do {
            defer { releasePartTransferSlot() }
            let result = try await transport.callUploadRPC(
              method: .saveUploadPart,
              input: .saveUploadPart(save),
              timeout: .seconds(60)
            )
            guard case .saveUploadPart? = result else {
              throw NativeMediaUploadError.unexpectedResponse
            }
          } catch {
            let state = try? await uploadState(uploadID: created.uploadID)
            guard state?.acceptedParts.contains(partIndex) == true else { throw error }
          }
          accepted.insert(partIndex)
          durableAcceptedBytes = Self.acceptedBytes(
            accepted,
            partSize: partSize,
            total: byteCount
          )
          await staging.recordProgress(
            logicalID: ownerScopedLogicalID,
            acceptedBytes: durableAcceptedBytes,
            totalBytes: byteCount
          )
          progress(durableAcceptedBytes, byteCount)
        }

        var finish = FinishUploadInput()
        finish.uploadID = created.uploadID
        let result = try await transport.callUploadRPC(
          method: .finishUpload,
          input: .finishUpload(finish),
          timeout: .seconds(60)
        )
        guard case let .finishUpload(finished)? = result,
              let state = finished.state
        else {
          throw NativeMediaUploadError.unexpectedResponse
        }
        switch state {
        case let .complete(complete):
          progress(byteCount, byteCount)
          await staging.discard(logicalID: ownerScopedLogicalID)
          return complete
        case let .missing(missing):
          guard missing.partIndices.allSatisfy({ $0 < created.partCount }) else {
            throw NativeMediaUploadError.invalidGeometry
          }
          accepted.subtract(missing.partIndices)
        case let .processing(processing):
          try await Task.sleep(for: .seconds(max(1, processing.retryAfterSeconds)))
        case let .failed(failure):
          throw NativeMediaUploadError.rejected(
            code: failure.code,
            retryable: failure.retryable
          )
        }
      }
    } catch {
      if Task.isCancelled {
        var cancel = CancelUploadInput()
        cancel.uploadID = created.uploadID
        _ = try? await transport.callUploadRPC(
          method: .cancelUpload,
          input: .cancelUpload(cancel),
          timeout: .seconds(5)
        )
        await staging.discard(logicalID: ownerScopedLogicalID)
      }
      throw error
    }
  }

  private func uploadState(uploadID: Data) async throws -> GetUploadStateResult {
    var input = GetUploadStateInput()
    input.uploadID = uploadID
    let result = try await transport.callUploadRPC(
      method: .getUploadState,
      input: .getUploadState(input),
      timeout: .seconds(15)
    )
    guard case let .getUploadState(state)? = result else {
      throw NativeMediaUploadError.unexpectedResponse
    }
    return state
  }

  private func acquirePartTransferSlot() async {
    guard activePartTransfers >= 3 else {
      activePartTransfers += 1
      return
    }
    await withCheckedContinuation { continuation in
      partTransferWaiters.append(continuation)
    }
  }

  private func releasePartTransferSlot() {
    if partTransferWaiters.isEmpty {
      activePartTransfers -= 1
    } else {
      partTransferWaiters.removeFirst().resume()
    }
  }

  private static func hashFile(at url: URL) throws -> (Int64, Data) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var byteCount: Int64 = 0
    while true {
      let data = try handle.read(upToCount: hashReadSize) ?? Data()
      guard !data.isEmpty else { break }
      byteCount += Int64(data.count)
      hash.update(data: data)
    }
    return (byteCount, Data(hash.finalize()))
  }

  private static func readPart(at url: URL, offset: UInt64, length: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    let data = try handle.read(upToCount: length) ?? Data()
    guard data.count == length else { throw NativeMediaUploadError.sourceChanged }
    return data
  }

  private static func clientUploadID(logicalID: String, sourceDigest: Data) -> Data {
    var hash = SHA256()
    hash.update(data: Data("inline-native-upload-v1:\(logicalID):".utf8))
    hash.update(data: sourceDigest)
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
