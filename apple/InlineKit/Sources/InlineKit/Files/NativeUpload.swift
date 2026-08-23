import CryptoKit
import Foundation
import Auth
import InlineProtocol
import Logger
import RealtimeV2

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

extension RealtimeDirectSession: NativeUploadRPCTransport {
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
  case canceled
  case expired

  public var errorDescription: String? {
    switch self {
    case .emptySource: "The upload source is empty."
    case .invalidGeometry: "The server returned invalid upload geometry."
    case .unauthenticated: "An authenticated account is required to upload media."
    case .unexpectedResponse: "The server returned an unexpected upload response."
    case let .rejected(code, retryable):
      "Upload processing failed (\(code), retryable: \(retryable))."
    case .sourceChanged: "The upload source changed while it was being read."
    case .canceled: "The upload was canceled."
    case .expired: "The upload expired before it completed."
    }
  }
}

public actor DurableUploadCoordinator: MediaUploading {
  public static let shared = DurableUploadCoordinator()

  private static let hashReadSize = 1_048_576
  private static let maximumPartSize = 16 * 1_048_576
  private static let maximumConcurrentPartsPerUpload = 2
  // These are individual RPC stall bounds, not a deadline for the complete upload.
  // A large file can span any number of successful part requests.
  private static let mutationTimeout: Duration = .seconds(60)
  private static let stateProbeTimeout: Duration = .seconds(15)
  private static let cancellationCleanupTimeout: Duration = .seconds(5)

  private enum FinishReconciliation {
    case complete(UploadComplete)
    case uploading(Set<UInt32>)
    case failed(UploadFailure)
    case canceled
    case expired
  }

  private let log = Log.scoped("NativeUpload")
  private let transport: any NativeUploadRPCTransport
  private let staging: any NativeUploadStaging
  private let ownerScope: @Sendable () -> String?
  private var activePartTransfers = 0
  private struct PartTransferWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }
  private var partTransferWaiters: [PartTransferWaiter] = []

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
      timeout: Self.mutationTimeout
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
        let missingParts = (0 ..< created.partCount).filter { !accepted.contains($0) }
        if !missingParts.isEmpty {
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
                  byteCount: byteCount
                )
              }
            }

            while let partIndex = try await group.next() {
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

              if nextPart < missingParts.count {
                let nextPartIndex = missingParts[nextPart]
                nextPart += 1
                group.addTask { [self] in
                  try await transferPart(
                    nextPartIndex,
                    uploadID: created.uploadID,
                    stagedURL: stagedURL,
                    partSize: partSize,
                    byteCount: byteCount
                  )
                }
              }
            }
          }
        }

        var finish = FinishUploadInput()
        finish.uploadID = created.uploadID
        let finished: FinishUploadResult
        do {
          let result = try await transport.callUploadRPC(
            method: .finishUpload,
            input: .finishUpload(finish),
            timeout: Self.mutationTimeout
          )
          guard case let .finishUpload(value)? = result,
                value.state != nil
          else {
            throw NativeMediaUploadError.unexpectedResponse
          }
          finished = value
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          switch try await reconcileLostFinish(uploadID: created.uploadID) {
          case let .complete(complete):
            if durableAcceptedBytes < byteCount {
              progress(byteCount, byteCount)
            }
            await staging.discard(logicalID: ownerScopedLogicalID)
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
              await staging.recordProgress(
                logicalID: ownerScopedLogicalID,
                acceptedBytes: durableAcceptedBytes,
                totalBytes: byteCount
              )
              progress(durableAcceptedBytes, byteCount)
            }
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
            progress(byteCount, byteCount)
          }
          await staging.discard(logicalID: ownerScopedLogicalID)
          return complete
        case let .missing(missing):
          guard missing.partIndices.allSatisfy({ $0 < created.partCount }) else {
            throw NativeMediaUploadError.invalidGeometry
          }
          accepted.subtract(missing.partIndices)
        case let .processing(processing):
          try await Task.sleep(for: .seconds(boundedUploadProcessingRetrySeconds(
            processing.retryAfterSeconds
          )))
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
        let transport = transport
        // The upload task is already cancelled, but cancellation has one terminal owner. Give
        // that owner a short, awaited, non-cancelled window to release server staging before the
        // caller tears down its transport. Failure remains best effort and server TTL is the
        // safety net.
        await Task.detached {
          _ = try? await transport.callUploadRPC(
            method: .cancelUpload,
            input: .cancelUpload(cancel),
            timeout: Self.cancellationCleanupTimeout
          )
        }.value
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
      timeout: Self.stateProbeTimeout
    )
    guard case let .getUploadState(state)? = result else {
      throw NativeMediaUploadError.unexpectedResponse
    }
    return state
  }

  private func reconcileLostFinish(uploadID: Data) async throws -> FinishReconciliation {
    while true {
      let state = try await uploadState(uploadID: uploadID)
      switch state.status {
      case .complete:
        guard state.hasComplete else { throw NativeMediaUploadError.unexpectedResponse }
        return .complete(state.complete)
      case .uploading:
        return .uploading(Set(state.acceptedParts))
      case .processing:
        // The finalizer owns this state. Keep querying authoritative state
        // instead of replaying FINISH_UPLOAD while the response is unknown.
        try await Task.sleep(for: .seconds(1))
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
  }

  private func transferPart(
    _ partIndex: UInt32,
    uploadID: Data,
    stagedURL: URL,
    partSize: Int64,
    byteCount: Int64
  ) async throws -> UInt32 {
    try Task.checkCancellation()
    let startedAt = ProcessInfo.processInfo.systemUptime
    let offset = Int64(partIndex) * partSize
    let length = Int(min(partSize, byteCount - offset))
    let readStartedAt = ProcessInfo.processInfo.systemUptime
    let data = try Self.readPart(
      at: stagedURL,
      offset: UInt64(offset),
      length: length
    )
    let readMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - readStartedAt) * 1_000
    )
    var save = SaveUploadPartInput()
    save.uploadID = uploadID
    save.partIndex = partIndex
    save.data = data

    let slotStartedAt = ProcessInfo.processInfo.systemUptime
    try await acquirePartTransferSlot()
    let slotWaitMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - slotStartedAt) * 1_000
    )
    defer { releasePartTransferSlot() }
    try Task.checkCancellation()
    let rpcStartedAt = ProcessInfo.processInfo.systemUptime
    log.debug(
      "Part dispatch started part=\(partIndex) bytes=\(length) active=\(activePartTransfers) read_ms=\(readMilliseconds) slot_wait_ms=\(slotWaitMilliseconds)"
    )
    do {
      let result = try await transport.callUploadRPC(
        method: .saveUploadPart,
        input: .saveUploadPart(save),
        timeout: Self.mutationTimeout
      )
      guard case .saveUploadPart? = result else {
        throw NativeMediaUploadError.unexpectedResponse
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let state = try? await uploadState(uploadID: uploadID)
      guard state?.acceptedParts.contains(partIndex) == true else { throw error }
    }
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

  private func acquirePartTransferSlot() async throws {
    try Task.checkCancellation()
    guard activePartTransfers >= 3 else {
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
