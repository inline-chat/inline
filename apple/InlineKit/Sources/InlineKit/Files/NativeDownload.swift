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
  case invalidRequest
  case invalidResponse
  case integrity
  case fileTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidRequest: "The file download request is invalid."
    case .invalidResponse: "The server returned an invalid file response."
    case .integrity: "The downloaded file failed its integrity check."
    case .fileTooLarge: "The file exceeds the download size limit."
    }
  }
}

/// File materialization over authenticated realtime V2 or V3.
/// Uses at most two pending 512 KiB chunks and never overwrites an existing destination.
public struct NativeFileDownloader: Sendable {
  private static let partSize: UInt32 = 524_288
  private static let concurrency = 2
  private static let maximumRangeAttempts = 3
  private let transport: any NativeFilePartFetching

  public init(transport: any NativeFilePartFetching) {
    self.transport = transport
  }

  /// The caller owns a successful file. Failure/cancellation removes only this
  /// invocation's incomplete destination; existing files are never truncated.
  /// The explicit fetcher must bind every request to one authenticated account
  /// on its realtime transport.
  @concurrent
  public func download(
    fileUniqueID: String,
    message: FileMessageLocation? = nil,
    to destination: URL,
    maximumByteCount: UInt64 = 500_000_000,
    progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
  ) async throws -> URL {
    guard destination.isFileURL, !destination.path.contains("\0"), maximumByteCount > 0,
          (6 ... 128).contains(fileUniqueID.utf8.count),
          fileUniqueID.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) ||
            (97 ... 122).contains($0) || $0 == 45 || $0 == 95 }),
          message.map({ $0.chatID > 0 && $0.messageID > 0 &&
            $0.chatID <= 2_147_483_647 && $0.messageID <= 2_147_483_647 }) ?? true
    else { throw NativeFileDownloadError.invalidRequest }
    try Task.checkCancellation()
    // Avoid fetching bytes for an obviously unusable destination; O_EXCL below
    // remains authoritative if a file appears after this advisory check.
    if FileManager.default.fileExists(atPath: destination.path) { throw POSIXError(.EEXIST) }
    var request = GetFilePartInput()
    request.fileUniqueID = fileUniqueID
    request.limit = Self.partSize
    if let message { request.message = message }
    let first = try await fetch(request, total: nil, maximumByteCount: maximumByteCount)
    let totalSize = first.totalSize
    try Task.checkCancellation()

    let staging = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).inline-download-\(UUID().uuidString).partial"
    )
    let descriptor = staging.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) } ?? -1
    }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var complete = false
    defer {
      try? handle.close()
      if !complete { try? FileManager.default.removeItem(at: staging) }
    }
    var written: UInt64 = 0
    func write(_ part: GetFilePartResult) throws {
      try Task.checkCancellation()
      try handle.write(contentsOf: part.data)
      written += UInt64(part.data.count)
      progress(Int64(written), Int64(totalSize))
    }
    try write(first)
    let baseRequest = request
    try await withThrowingTaskGroup(of: GetFilePartResult.self) { group in
      var nextOffset = written
      var active = 0
      var ready: [UInt64: GetFilePartResult] = [:]
      func refill() {
        while active + ready.count < Self.concurrency, nextOffset < totalSize {
          var partRequest = baseRequest
          partRequest.offset = nextOffset
          let scheduledRequest = partRequest
          nextOffset += UInt64(Self.partSize)
          active += 1
          group.addTask {
            try await fetch(scheduledRequest, total: totalSize, maximumByteCount: maximumByteCount)
          }
        }
      }
      refill()
      while let part = try await group.next() {
        active -= 1
        ready[part.offset] = part
        while let contiguous = ready.removeValue(forKey: written) { try write(contiguous) }
        try Task.checkCancellation()
        refill()
      }
    }
    guard written == totalSize else { throw NativeFileDownloadError.invalidResponse }
    try handle.synchronize()
    try Task.checkCancellation()
    try handle.close()
    let published = staging.withUnsafeFileSystemRepresentation { stagingPath in
      destination.withUnsafeFileSystemRepresentation { destinationPath in
        guard let stagingPath, let destinationPath else { return EINVAL }
        return Darwin.renameatx_np(
          AT_FDCWD, stagingPath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL)
        ) == 0 ? 0 : errno
      }
    }
    guard published == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: published) ?? .EIO)
    }
    complete = true
    return destination
  }

  @concurrent
  private func fetch(
    _ request: GetFilePartInput,
    total: UInt64?,
    maximumByteCount: UInt64
  ) async throws -> GetFilePartResult {
    try Task.checkCancellation()
    let part = try await fetchRange(request)
    try Task.checkCancellation()
    guard part.offset == request.offset, part.totalSize > 0,
          part.totalSize <= UInt64(Int64.max), part.totalSize >= request.offset,
          total.map({ $0 == part.totalSize }) ?? true
    else { throw NativeFileDownloadError.invalidResponse }
    guard part.totalSize <= maximumByteCount else { throw NativeFileDownloadError.fileTooLarge }
    let expected = min(UInt64(request.limit), part.totalSize - request.offset)
    guard UInt64(part.data.count) == expected, part.sha256.count == 32 else {
      throw NativeFileDownloadError.invalidResponse
    }
    guard Data(SHA256.hash(data: part.data)) == part.sha256 else { throw NativeFileDownloadError.integrity }
    return part
  }

  @concurrent
  private func fetchRange(_ request: GetFilePartInput) async throws -> GetFilePartResult {
    for attempt in 0 ..< Self.maximumRangeAttempts {
      try Task.checkCancellation()
      do {
        return try await transport.fetchFilePart(request, timeout: .seconds(30))
      } catch {
        try Task.checkCancellation()
        guard attempt + 1 < Self.maximumRangeAttempts, Self.isRetryableTransportFailure(error) else { throw error }
        try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
      }
    }
    throw NativeFileDownloadError.invalidResponse
  }

  static func isRetryableTransportFailure(_ error: any Error) -> Bool {
    if let error = error as? RealtimeDirectRpcError {
      switch error {
      case .notConnected, .timeout, .commitOutcomeUnknown:
        return true
      case let .unknown(underlying):
        return isRetryableNetworkFailure(underlying)
      case let .rpcError(_, _, code):
        return code == 408
      case .notAuthorized, .capacityExceeded:
        return false
      }
    }
    return isRetryableNetworkFailure(error)
  }

  private static func isRetryableNetworkFailure(_ error: any Error) -> Bool {
    let error = error as NSError
    guard error.domain == NSURLErrorDomain else { return false }
    switch URLError.Code(rawValue: error.code) {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
      return true
    default:
      return false
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
    let result = try await Self.callFilePartRPCWithReplay(
      call: {
        // Give the existing connection owner time to reconnect before the
        // range's own RPC stall timeout starts; no deadline spans the file.
        try await Api.realtime.withUserInitiatedConnection(
          accountToken: accountToken, timeout: timeout + .seconds(30)
        ) { realtime in
          try await realtime.callRpcDirect(
            method: .getFilePart,
            input: .getFilePart(input),
            timeout: timeout,
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
    return try await NativeFileDownloader(transport: self).download(
      fileUniqueID: fileID, message: location, to: destination, progress: progress
    )
  }

  static func fileID(in result: GetMessagesResult, media: Media, location: FileMessageLocation) throws -> String {
    guard location.chatID > 0, location.messageID > 0,
          let message = result.messages.first(where: { $0.chatID == location.chatID && $0.id == location.messageID })
    else { throw NativeFileDownloadError.invalidResponse }
    let fileID: String
    switch (media, message.media.media) {
    case let (.document(id), .document(value)?) where id > 0 && value.document.id == id:
      fileID = value.document.fileUniqueID
    case let (.video(id), .video(value)?) where id > 0 && value.video.id == id:
      fileID = value.video.fileUniqueID
    default:
      throw NativeFileDownloadError.invalidResponse
    }
    guard !fileID.isEmpty else { throw NativeFileDownloadError.invalidResponse }
    return fileID
  }
}
