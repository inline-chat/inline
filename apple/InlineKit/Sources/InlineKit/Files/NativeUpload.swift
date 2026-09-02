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
  func discard(logicalID: String) async
}

/// Owns immutable upload sources independently of picker URLs and preprocessing temporaries.
/// iOS and its Share Extension use the app-group container; macOS falls back to Application Support.
public actor FileNativeUploadStagingStore: NativeUploadStaging {
  public static let shared = FileNativeUploadStagingStore()

  private let root: URL

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
  private var activePartTransfers = 0
  private struct PartTransferWaiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }
  private var partTransferWaiters: [PartTransferWaiter] = []

  public init(
    transport: any NativeUploadRPCTransport = Api.realtime,
    staging: any NativeUploadStaging = FileNativeUploadStagingStore.shared,
    accountFence: (any NativeUploadAccountFencing)? = nil,
    ownerScope: @escaping @Sendable () -> String? = {
      Auth.shared.getCurrentUserId().map(String.init)
    }
  ) {
    self.transport = transport
    self.staging = staging
    self.accountFence = accountFence
    self.ownerScope = ownerScope
  }

  public func upload(
    _ request: NativeMediaUploadRequest,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> UploadComplete {
    guard let owner = ownerScope() else { throw NativeMediaUploadError.unauthenticated }
    let accountToken = try accountFence?.beginUploadAccountFence()
    try validateAccount(accountToken)
    guard let maximumByteCount = Self.maximumByteCount(for: request.kind) else {
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
      (byteCount, digest) = try await Self.hashFile(at: stagedURL)
      try Task.checkCancellation()
      try validateAccount(accountToken)
      guard byteCount > 0 else { throw NativeMediaUploadError.emptySource }
      guard byteCount <= Int64(maximumByteCount) else { throw NativeMediaUploadError.fileTooLarge }

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
      do {
        while true {
          try Task.checkCancellation()
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
    // The upload task is already cancelled, but cancellation has one terminal owner. Give that
    // owner a short, awaited, non-cancelled window to release server staging before its transport
    // is torn down. Failure remains best effort and server TTL is the safety net.
    await Task.detached {
      if let accountToken {
        guard let boundTransport = transport as? any AccountBoundNativeUploadRPCTransport else { return }
        do {
          try accountFence?.validateUploadAccountFence(accountToken)
          _ = try await boundTransport.callUploadRPC(
            method: .cancelUpload,
            input: .cancelUpload(cancel),
            timeout: Self.cancellationCleanupTimeout,
            accountToken: accountToken
          )
          try accountFence?.validateUploadAccountFence(accountToken)
        } catch { return }
      } else {
        _ = try? await transport.callUploadRPC(
          method: .cancelUpload,
          input: .cancelUpload(cancel),
          timeout: Self.cancellationCleanupTimeout
        )
      }
    }.value
    await staging.discard(logicalID: logicalID)
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

  private static func clientUploadID(logicalID: String, sourceDigest: Data) -> Data {
    var hash = SHA256()
    hash.update(data: Data("inline-native-upload-v1:\(logicalID):".utf8))
    hash.update(data: sourceDigest)
    return Data(hash.finalize().prefix(16))
  }

  private static func maximumByteCount(for kind: UploadKind) -> Int? {
    switch kind {
    case .photo: return 40_000_000
    case .video, .document: return 200_000_000
    case .voice: return 20_000_000
    case .unspecified, .UNRECOGNIZED: return nil
    }
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
