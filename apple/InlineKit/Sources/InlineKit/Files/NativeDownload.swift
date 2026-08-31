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
  case requiresV3

  public var errorDescription: String? {
    switch self {
    case .invalidRequest: "The file download request is invalid."
    case .invalidResponse: "The server returned an invalid file response."
    case .integrity: "The downloaded file failed its integrity check."
    case .fileTooLarge: "The file exceeds the download size limit."
    case .requiresV3: "Native downloads require a V3 session. Turn off Native File Downloads to use CDN."
    }
  }
}

/// Opt-in file materialization over encrypted V3. Existing CDN consumers are unchanged.
/// Uses at most two pending 512 KiB chunks and never overwrites an existing destination.
public struct NativeFileDownloader: Sendable {
  private static let partSize: UInt32 = 524_288
  private static let concurrency = 2
  private let transport: any NativeFilePartFetching

  public init(transport: any NativeFilePartFetching) {
    self.transport = transport
  }

  /// The caller owns a successful file. Failure/cancellation removes only this
  /// invocation's incomplete destination; existing files are never truncated.
  /// The explicit fetcher must bind every request to one authenticated account
  /// on a V3 transport. Legacy sessions cannot use this RPC.
  @concurrent
  public func download(
    fileUniqueID: String,
    message: FileMessageLocation? = nil,
    to destination: URL,
    maximumByteCount: UInt64 = 500 * 1_024 * 1_024,
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
    let part = try await transport.fetchFilePart(request, timeout: .seconds(30))
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
}

/// Fetch identity at explicit download admission, without adding persistent media
/// fields for the experiment. Bind all RPCs to the account that started it.
struct NativeDocumentDownload: NativeFilePartFetching {
  static let freshRequestReplayMessage = "Retry getFilePart with a fresh request ID"

  let auth: AuthHandle
  let accountToken: AuthAccountMutationToken

  init() throws {
    auth = Auth.shared.handle
    accountToken = try auth.beginAccountMutation()
    guard auth.inlineProtocolCredentials() != nil else { throw NativeFileDownloadError.requiresV3 }
  }

  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    let result = try await Self.callFilePartRPCWithReplay(
      call: {
        try await Api.realtime.callRpcDirect(
          method: .getFilePart,
          input: .getFilePart(input),
          timeout: timeout,
          accountToken: accountToken
        )
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
    documentID: Int64, message: Message, to destination: URL,
    progress: @escaping @Sendable (Int64, Int64) -> Void
  ) async throws -> URL {
    var location = FileMessageLocation()
    location.chatID = message.chatId
    location.messageID = message.messageId
    let response = try await Api.realtime.callRpcDirect(
      method: .getMessages,
      input: .getMessages(.with {
        $0.peerID = message.peerId.toInputPeer()
        $0.messageIds = [message.messageId]
      }), timeout: .seconds(30), accountToken: accountToken
    )
    try auth.validateAccountMutation(accountToken)
    guard case let .getMessages(messages)? = response else { throw NativeFileDownloadError.invalidResponse }
    let fileID = try Self.fileID(in: messages, documentID: documentID, location: location)
    return try await NativeFileDownloader(transport: self).download(
      fileUniqueID: fileID, message: location, to: destination, progress: progress
    )
  }

  static func fileID(in result: GetMessagesResult, documentID: Int64, location: FileMessageLocation) throws -> String {
    guard location.chatID > 0, location.messageID > 0, documentID > 0,
          let message = result.messages.first(where: { $0.chatID == location.chatID && $0.id == location.messageID }),
          case let .document(media)? = message.media.media,
          media.document.id == documentID, !media.document.fileUniqueID.isEmpty
    else { throw NativeFileDownloadError.invalidResponse }
    return media.document.fileUniqueID
  }
}
