@_spi(LogoutCoordinator) import Auth
import Combine
import CryptoKit
import Darwin
import Foundation
import InlineProtocol
import RealtimeV2
import Testing
@testable import InlineKit

private final class FilePartReplayProbe {
  let message: String
  private(set) var calls = 0
  private(set) var validations = 0

  init(message: String) { self.message = message }

  func call() async throws -> RpcResult.OneOf_Result? {
    calls += 1
    if calls == 1 {
      throw RealtimeDirectRpcError.rpcError(
        errorCode: .rateLimit,
        message: message,
        code: 429
      )
    }
    return .getFilePart(GetFilePartResult())
  }

  func validate() { validations += 1 }
}

private actor DownloadPartMock: NativeFilePartFetching {
  enum Corruption: Sendable { case none, offset, size, length, digest }
  let bytes: Data
  let corruption: Corruption
  let stallOffsets: Set<UInt64>
  let failureOffset: UInt64?
  let failure: any Error
  private var failuresRemaining: Int
  private var gates: [UInt64: AsyncStream<Void>.Continuation] = [:]
  private var requests: [GetFilePartInput] = []
  private var waiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
  private var responses: [UInt64] = []
  private var responseWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
  private var active = 0
  private var maxActive = 0

  init(
    bytes: Data, corruption: Corruption = .none, stallOffset: UInt64? = nil,
    stallOffsets: Set<UInt64> = [],
    failureOffset: UInt64? = nil, failuresRemaining: Int = 0,
    failure: any Error = RealtimeDirectRpcError.timeout
  ) {
    self.bytes = bytes
    self.corruption = corruption
    self.stallOffsets = stallOffsets.union(stallOffset.map { [$0] } ?? [])
    self.failureOffset = failureOffset
    self.failuresRemaining = failuresRemaining
    self.failure = failure
  }

  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    #expect(timeout > .zero && timeout <= .seconds(30))
    requests.append(input)
    waiters.removeValue(forKey: input.offset)?.forEach { $0.resume() }
    active += 1
    maxActive = max(maxActive, active)
    defer { active -= 1 }
    if input.offset == failureOffset, failuresRemaining > 0 {
      failuresRemaining -= 1
      throw failure
    }
    if stallOffsets.contains(input.offset) {
      let gate = AsyncStream<Void>.makeStream()
      gates[input.offset] = gate.continuation
      for await _ in gate.stream { break }
      try Task.checkCancellation()
    }
    var part = GetFilePartResult()
    part.offset = input.offset
    part.totalSize = UInt64(bytes.count)
    guard input.offset <= UInt64(bytes.count) else {
      throw RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: "Range is beyond the file", code: 400)
    }
    let end = min(bytes.count, Int(input.offset) + Int(input.limit))
    part.data = bytes.subdata(in: Int(input.offset) ..< end)
    part.sha256 = Data(SHA256.hash(data: part.data))
    // Corrupt a later range so the failure must remove an already-created file.
    if input.offset > 0 {
      switch corruption {
      case .none: break
      case .offset: part.offset += 1
      case .size: part.totalSize += 1
      case .length: part.data.removeLast()
      case .digest: part.sha256[0] ^= 1
      }
    }
    responses.append(input.offset)
    responseWaiters.removeValue(forKey: input.offset)?.forEach { $0.resume() }
    return part
  }

  func waitForRequest(_ offset: UInt64) async {
    if requests.contains(where: { $0.offset == offset }) { return }
    await withCheckedContinuation { waiters[offset, default: []].append($0) }
  }
  func waitForResponse(_ offset: UInt64) async {
    if responses.contains(offset) { return }
    await withCheckedContinuation { responseWaiters[offset, default: []].append($0) }
  }
  func release(_ offset: UInt64) { gates.removeValue(forKey: offset)?.finish() }
  func responseOffsets() -> [UInt64] { responses }
  func snapshot() -> ([GetFilePartInput], Int, Int) { (requests, maxActive, active) }
}

@Suite("Native download session ownership", .serialized)
@MainActor private struct NativeDownloadSessionTests {
  @Test(arguments: [false, true])
  func smallBearerDocumentsUseCDNWithoutOptIn(includeMessage: Bool) async throws {
    let auth = Auth.mocked(authenticated: true)
    let owner = FileDownloader(auth: auth.handle)
    #expect(auth.getIsLoggedIn())
    #expect(auth.getInlineProtocolCredentials() == nil)
    let key = ExperimentalFeatureFlags.nativeFileDownloadsKey
    let previousPreference = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(false, forKey: key)
    defer { UserDefaults.standard.set(previousPreference, forKey: key) }

    let document = DocumentInfo(document: Document(
      documentId: 99004, date: Date(), fileName: "download-policy.txt", size: 1,
      cdnUrl: "unsupported-download-policy://document"
    ))
    let message = Message(
      messageId: 1, fromId: 1, date: Date(), text: nil,
      peerUserId: 1, peerThreadId: nil, chatId: 1, documentId: document.document.documentId
    )
    var completions = 0
    owner.downloadDocument(document: document, for: includeMessage ? message : nil) { result in
      completions += 1
      if case let .failure(error) = result {
        #expect(error is URLError)
      } else {
        Issue.record("The unsupported test URL unexpectedly downloaded")
      }
    }

    // The real URLSession route publishes progress before resuming its task.
    // The old native admission instead failed synchronously before this point.
    #expect(owner.isDocumentDownloadActive(documentId: document.id))
    #expect(owner.currentDocumentProgress(documentId: document.id) != nil)
    #expect(!ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth.handle))
    #expect(!UserDefaults.standard.bool(forKey: key))
    await owner.resetSession()
    #expect(completions == 1)
    try await completeMockLogout(auth)
  }

  @Test func bearerDocumentWithoutCDNURLReturnsMissingURLError() async throws {
    let auth = Auth.mocked(authenticated: true)
    let owner = FileDownloader(auth: auth.handle)
    let key = ExperimentalFeatureFlags.nativeFileDownloadsKey
    let previousPreference = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(false, forKey: key)
    defer { UserDefaults.standard.set(previousPreference, forKey: key) }
    let document = DocumentInfo(document: Document(documentId: 99006, date: Date()))
    let message = Message(
      messageId: 1, fromId: 1, date: Date(), text: nil,
      peerUserId: 1, peerThreadId: nil, chatId: 1, documentId: document.document.documentId
    )
    var completions = 0
    owner.downloadDocument(document: document, for: message) { result in
      completions += 1
      guard case let .failure(error) = result else { Issue.record("A missing URL started a download"); return }
      #expect((error as NSError).domain == "FileDownloader")
      #expect((error as NSError).code == 404)
    }
    #expect(completions == 1)
    #expect(!owner.isDocumentDownloadActive(documentId: document.id))
    #expect(owner.currentDocumentProgress(documentId: document.id) == nil)
    await owner.resetSession()
    try await completeMockLogout(auth)
  }

  @Test(arguments: [false, true])
  func authenticatedSessionsRouteByOptInOnly(savedOptIn: Bool) async throws {
    let key = ExperimentalFeatureFlags.nativeFileDownloadsKey
    let previousPreference = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(savedOptIn, forKey: key)
    defer { UserDefaults.standard.set(previousPreference, forKey: key) }
    for useV3 in [false, true] {
      let auth = Auth.mocked(authenticated: !useV3)
      if useV3 {
        let bytes = [UInt8](repeating: 0x31, count: 256)
        let authorization = try InlineProtocolAuthorization(
          key: bytes, keyID: InlineSecureTransport.authKeyID(bytes), serverSalt: 7,
          temporary: false, expiresAt: nil
        )
        try await auth.saveInlineProtocolCredentials(InlineProtocolSessionCredentials(
          userId: 1, accountSessionId: 84, permanent: authorization
        ))
      }
      #expect(ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth.handle) == savedOptIn)
      #expect(try NativeMessageFileDownload(auth: auth.handle).accountToken.userID == 1)
      #expect(UserDefaults.standard.bool(forKey: key) == savedOptIn)
      try await completeMockLogout(auth)
    }
  }

  @Test func optInCannotEnableDownloadsWithoutAuthentication() {
    let auth = Auth.mocked(authenticated: false)
    let key = ExperimentalFeatureFlags.nativeFileDownloadsKey
    let previousPreference = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(true, forKey: key)
    defer { UserDefaults.standard.set(previousPreference, forKey: key) }
    #expect(!ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth.handle))
    #expect(throws: AuthStorageError.self) { try NativeMessageFileDownload(auth: auth.handle) }
  }

  @Test func publishedLogoutCannotAdmitCDNWhenV3Disappears() async throws {
    let auth = Auth.mocked(authenticated: false)
    let owner = FileDownloader(auth: auth.handle)
    let key = ExperimentalFeatureFlags.nativeFileDownloadsKey
    let previousPreference = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(previousPreference, forKey: key) }
    let bytes = [UInt8](repeating: 0x31, count: 256)
    let authorization = try InlineProtocolAuthorization(
      key: bytes, keyID: InlineSecureTransport.authKeyID(bytes), serverSalt: 7,
      temporary: false, expiresAt: nil
    )
    try await auth.saveInlineProtocolCredentials(InlineProtocolSessionCredentials(
      userId: 1, accountSessionId: 84, permanent: authorization
    ))
    UserDefaults.standard.set(false, forKey: key)
    #expect(!ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth.handle))
    UserDefaults.standard.set(true, forKey: key)
    #expect(ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth.handle))
    #expect(try NativeMessageFileDownload(auth: auth.handle).accountToken.userID == 1)

    let fence = try auth.beginLogoutSynchronously()
    #expect(!ExperimentalFeatureFlags.nativeFileDownloadsEnabled(auth: auth.handle))
    await auth.publishLogoutInProgress()
    #expect(auth.getInlineProtocolCredentials() == nil)
    let document = DocumentInfo(document: Document(
      documentId: 99005, date: Date(), cdnUrl: "unsupported-download-policy://document"
    ))
    let message = Message(
      messageId: 1, fromId: 1, date: Date(), text: nil,
      peerUserId: 1, peerThreadId: nil, chatId: 1, documentId: document.document.documentId
    )
    var completions = 0
    owner.downloadDocument(document: document, for: message) { result in
      completions += 1
      if case let .failure(error) = result {
        #expect(FileDownloader.isCancellation(error))
      } else {
        Issue.record("Logout admitted a new download")
      }
    }
    #expect(completions == 1)
    #expect(!owner.isDocumentDownloadActive(documentId: document.id))
    #expect(owner.currentDocumentProgress(documentId: document.id) == nil)
    await owner.resetSession()
    try await completeMockLogout(auth, fence: fence)

    // A stale view can still deliver an action after the logout fence clears.
    owner.downloadDocument(document: document, for: message) { result in
      completions += 1
      if case let .failure(error) = result {
        #expect(FileDownloader.isCancellation(error))
      } else {
        Issue.record("Completed logout admitted a new download")
      }
    }
    #expect(completions == 2)
    #expect(!owner.isDocumentDownloadActive(documentId: document.id))
    #expect(owner.currentDocumentProgress(documentId: document.id) == nil)
    await owner.resetSession()
  }

  private func completeMockLogout(_ auth: Auth, fence: AuthLogoutFence? = nil) async throws {
    let fence = try fence ?? auth.beginLogoutSynchronously()
    let proof = await auth.destroyCredentialsForPendingLogout(fence: fence)
    guard let proof else { throw AuthStorageError.keychainDeleteFailed }
    let completed = await auth.completePendingLogout(
      fence: fence, databaseProof: AuthDatabaseCleanupProof(fence: fence), credentialProof: proof,
      completionPermit: AuthLogoutCompletionPermit(fence: fence)
    )
    #expect(completed)
  }

  @Test func cachePublicationWinsOverLateCancellation() async throws {
    let owner = FileDownloader.shared
    await owner.resetSession()
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let completed = AsyncStream<Void>.makeStream()
    let observation = owner.documentProgressPublisher(documentId: 99003).sink { progress in
      if progress.isComplete { owner.cancelDocumentDownload(documentId: 99003) }
    }
    var completions = 0
    var persisted = false
    owner.downloadFile(id: "doc_99003", url: nil, localUrl: destination, expectedBytes: 1, nativeDownload: { url, progress in
      try Data([1]).write(to: url)
      progress(1, 1)
      return url
    }) { token, result in
      guard case let .success(file) = result else { Issue.record("Transfer failed"); completed.continuation.finish(); return }
      owner.finalizeDocumentDownload(id: "doc_99003", token: token, fileURL: file, persist: {
        entered.continuation.finish()
        for await _ in release.stream {}
        try Task.checkCancellation()
        persisted = true
      }) { result in
        completions += 1
        if case .failure = result { Issue.record("Committed file reported canceled") }
        completed.continuation.finish()
      }
    }
    for await _ in entered.stream {}
    owner.cancelDocumentDownload(documentId: 99003)
    #expect(owner.isDocumentDownloadActive(documentId: 99003))
    release.continuation.finish()
    for await _ in completed.stream {}
    #expect(persisted)
    #expect(completions == 1)
    #expect(owner.currentDocumentProgress(documentId: 99003)?.isComplete == true)
    #expect(try Data(contentsOf: destination) == Data([1]))
    observation.cancel()
    await owner.resetSession()
  }

  @Test func resetCancelsAndDrainsNativeTransferBeforeReadmission() async throws {
    let owner = FileDownloader.shared
    await owner.resetSession()
    let transport = DownloadPartMock(bytes: Data(repeating: 4, count: 524_300), stallOffset: 524_288)
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    var completions = 0
    owner.downloadFile(id: "doc_99001", url: nil, localUrl: destination, nativeDownload: { url, progress in
      try await NativeFileDownloader(transport: transport).download(
        fileUniqueID: "IND_wire", to: url, progress: progress
      )
    }) { _, result in
      completions += 1
      if case let .failure(error) = result { #expect(FileDownloader.isCancellation(error)) }
      else { Issue.record("Canceled download succeeded") }
    }
    await transport.waitForRequest(524_288)
    #expect(owner.isDocumentDownloadActive(documentId: 99001))
    await owner.resetSession()
    #expect(completions == 1)
    #expect(!owner.isDocumentDownloadActive(documentId: 99001))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(await transport.snapshot().2 == 0)

    let next = DownloadPartMock(bytes: Data([5, 6, 7]))
    let completed = AsyncStream<Void>.makeStream()
    owner.downloadFile(id: "doc_99001", url: nil, localUrl: destination, nativeDownload: { url, progress in
      try await NativeFileDownloader(transport: next).download(fileUniqueID: "IND_wire", to: url, progress: progress)
    }) { _, result in
      if case .failure = result { Issue.record("Next download failed") }
      completed.continuation.finish()
    }
    for await _ in completed.stream {}
    #expect(try Data(contentsOf: destination) == Data([5, 6, 7]))
    await owner.resetSession()
  }

  @Test func progressObserverCanCancelBeforeNativeTaskStarts() async {
    let owner = FileDownloader.shared
    await owner.resetSession()
    let transport = DownloadPartMock(bytes: Data([1]))
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let observation = owner.documentProgressPublisher(documentId: 99002).sink { _ in
      if owner.isDocumentDownloadActive(documentId: 99002) { owner.cancelDocumentDownload(documentId: 99002) }
    }
    var completions = 0
    owner.downloadFile(id: "doc_99002", url: nil, localUrl: destination, nativeDownload: { url, progress in
      try await NativeFileDownloader(transport: transport).download(fileUniqueID: "IND_wire", to: url, progress: progress)
    }) { _, result in
      completions += 1
      if case let .failure(error) = result { #expect(FileDownloader.isCancellation(error)) }
      else { Issue.record("Canceled download succeeded") }
    }
    await owner.resetSession()
    #expect(completions == 1)
    #expect(await transport.snapshot().0.isEmpty)
    observation.cancel()
  }
}

private func downloadDestination() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("inline-native-download-test-\(UUID().uuidString)")
}

@Suite private struct NativeDownloadTests {
  @Test func crossLanguageWireVectorsAndLegacyMedia() throws {
    // Shared with packages/protocol/tests/downloads.test.ts.
    let callHex = "088801ca081e0a08494e445f77697265108180808080808010188080202205087b10c803"
    let resultHex = "ca08390881808080808080101084808080808080101a0300ff8022200000000000000000000000000000000000000000000000000000000000000000"
    func bytes(_ hex: String) -> Data {
      let characters = Array(hex)
      return Data(stride(from: 0, to: characters.count, by: 2).map {
        UInt8(String(characters[$0 ... $0 + 1]), radix: 16)!
      })
    }
    var input = GetFilePartInput()
    input.fileUniqueID = "IND_wire"
    input.offset = 9_007_199_254_740_993
    input.limit = 524_288
    input.message.chatID = 123
    input.message.messageID = 456
    var call = RpcCall()
    call.method = .getFilePart
    call.input = .getFilePart(input)
    #expect(try call.serializedData() == bytes(callHex))
    #expect(try RpcCall(serializedBytes: bytes(callHex)) == call)
    var part = GetFilePartResult()
    part.offset = input.offset
    part.totalSize = 9_007_199_254_740_996
    part.data = Data([0, 255, 128])
    part.sha256 = Data(repeating: 0, count: 32)
    var result = RpcResult()
    result.result = .getFilePart(part)
    #expect(try result.serializedData() == bytes(resultHex))
    #expect(try RpcResult(serializedBytes: bytes(resultHex)) == result)
    #expect(try !InlineProtocol.Document(serializedBytes: Data()).hasFileUniqueID)
    #expect(try !InlineProtocol.Video(serializedBytes: Data()).hasFileUniqueID)
    #expect(try !InlineProtocol.Voice(serializedBytes: Data()).hasFileUniqueID)
    #expect(try !InlineProtocol.PhotoSize(serializedBytes: Data()).hasFileUniqueID)
    var document = InlineProtocol.Document()
    document.fileUniqueID = "IND_wire"
    #expect(try document.serializedData() == bytes("a20608494e445f77697265"))
  }

  @Test func documentLookupRequiresExactProvenanceAndRepresentation() throws {
    var location = FileMessageLocation()
    location.chatID = 10
    location.messageID = 20
    var message = InlineProtocol.Message()
    message.chatID = 10
    message.id = 20
    message.media.document.document.id = 30
    message.media.document.document.fileUniqueID = "IND_wire"
    var result = GetMessagesResult()
    result.messages = [message]
    #expect(try NativeMessageFileDownload.fileID(in: result, media: .document(30), location: location) == "IND_wire")
    for mutation in 0 ..< 4 {
      var changed = result
      switch mutation {
      case 0: changed.messages[0].chatID = 11
      case 1: changed.messages[0].id = 21
      case 2: changed.messages[0].media.document.document.id = 31
      default: changed.messages[0].media.document.document.clearFileUniqueID()
      }
      #expect(throws: NativeFileDownloadError.self) {
        try NativeMessageFileDownload.fileID(in: changed, media: .document(30), location: location)
      }
    }
  }

  @Test func videoLookupRequiresExactProvenanceAndRepresentation() throws {
    var location = FileMessageLocation()
    location.chatID = 10
    location.messageID = 20
    var message = InlineProtocol.Message()
    message.chatID = 10
    message.id = 20
    message.media.video.video.id = 30
    message.media.video.video.fileUniqueID = "INV_wire"
    var result = GetMessagesResult()
    result.messages = [message]
    #expect(try NativeMessageFileDownload.fileID(in: result, media: .video(30), location: location) == "INV_wire")
    #expect(throws: NativeFileDownloadError.self) {
      try NativeMessageFileDownload.fileID(in: result, media: .document(30), location: location)
    }
    result.messages[0].media.video.video.id = 31
    #expect(throws: NativeFileDownloadError.self) {
      try NativeMessageFileDownload.fileID(in: result, media: .video(30), location: location)
    }
  }

  @Test func exactFreshRequestReplayTombstoneRetriesOnceAfterAccountValidation() async throws {
    let probe = FilePartReplayProbe(message: NativeMessageFileDownload.freshRequestReplayMessage)
    let result = try await NativeMessageFileDownload.callFilePartRPCWithReplay(
      call: { try await probe.call() },
      validateAccount: { probe.validate() }
    )
    guard let result, case .getFilePart = result else {
      Issue.record("Fresh request replay did not return the second RPC result")
      return
    }
    #expect(probe.calls == 2)
    #expect(probe.validations == 2)
  }

  @Test func nearMatchFreshRequestErrorIsTerminal() async {
    let probe = FilePartReplayProbe(message: "Retry a different RPC")
    await #expect(throws: RealtimeDirectRpcError.self) {
      _ = try await NativeMessageFileDownload.callFilePartRPCWithReplay(
        call: { try await probe.call() },
        validateAccount: { probe.validate() }
      )
    }
    #expect(probe.calls == 1)
    #expect(probe.validations == 1)
  }

  @Test func boundedOutOfOrderRangesProduceExactFile() async throws {
    let partSize = 524_288
    let bytes = Data((0 ..< partSize * 6 + 17).map { UInt8($0 % 251) })
    let window = (1 ... 4).map { UInt64(partSize * $0) }
    let transport = DownloadPartMock(bytes: bytes, stallOffsets: Set(window))
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    var message = FileMessageLocation()
    message.chatID = 11
    message.messageID = 12
    let provenance = message
    let download = Task {
      try await NativeFileDownloader(transport: transport).download(
        fileUniqueID: "INP_download", message: provenance, to: destination
      )
    }
    // The size probe finishes first, then all four range slots must fill. More
    // parts remain beyond this window, so the assertion also checks admission.
    for offset in window { await transport.waitForRequest(offset) }
    let (pending, maximum, inFlight) = await transport.snapshot()
    #expect(pending.map(\.offset).sorted() == [0] + window)
    #expect(maximum == 4)
    #expect(inFlight == 4)
    // Return the later ranges in reverse order while the next writable range
    // remains blocked, then verify the published file still has exact bytes.
    for offset in window.dropFirst().reversed() {
      await transport.release(offset)
      await transport.waitForResponse(offset)
    }
    #expect(await transport.responseOffsets() == [0] + window.dropFirst().reversed())
    await transport.release(window[0])
    let result = try await download.value
    #expect(result == destination)
    #expect(try Data(contentsOf: result) == bytes)
    let (requests, maxActive, active) = await transport.snapshot()
    #expect(requests.map(\.offset).sorted() == (0 ... 6).map { UInt64(partSize * $0) })
    #expect(requests.allSatisfy { $0.message == provenance && $0.fileUniqueID == "INP_download" })
    #expect(maxActive == 4)
    #expect(active == 0)
  }

  @Test(arguments: [DownloadPartMock.Corruption.offset, .size, .length, .digest])
  func corruptRangeRemovesPartialFile(_ corruption: DownloadPartMock.Corruption) async throws {
    let transport = DownloadPartMock(bytes: Data(repeating: 3, count: 524_300), corruption: corruption)
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    await #expect(throws: NativeFileDownloadError.self) {
      try await NativeFileDownloader(transport: transport).download(fileUniqueID: "INP_download", to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(await transport.snapshot().0.filter { $0.offset == 524_288 }.count == 1)
  }

  @Test func retriesOnlyTheFailedRangeAfterTransientDisconnects() async throws {
    let bytes = Data(repeating: 3, count: 524_300)
    let transport = DownloadPartMock(
      bytes: bytes, failureOffset: 524_288, failuresRemaining: 2, failure: RealtimeDirectRpcError.notConnected
    )
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    _ = try await NativeFileDownloader(transport: transport).download(fileUniqueID: "INP_download", to: destination)
    #expect(try Data(contentsOf: destination) == bytes)
    let requests = await transport.snapshot().0
    #expect(requests.filter { $0.offset == 0 }.count == 1)
    #expect(requests.filter { $0.offset == 524_288 }.count == 3)
  }

  @Test func bridgedNetworkErrorsRemainRetryableAndCancellationDoesNot() {
    #expect(NativeFileDownloader.isRetryableTransportFailure(
      RealtimeDirectRpcError.unknown(NSError(domain: NSURLErrorDomain, code: URLError.Code.networkConnectionLost.rawValue))
    ))
    #expect(!NativeFileDownloader.isRetryableTransportFailure(URLError(.cancelled)))
    #expect(!NativeFileDownloader.isRetryableTransportFailure(AuthStorageError.loginUnavailable))
    #expect(!NativeFileDownloader.isRetryableTransportFailure(
      RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: "failure", code: 500)
    ))
  }

  @Test func serverRangeTimeoutRetriesTheCurrentRange() async throws {
    let bytes = Data(repeating: 3, count: 524_300)
    let transport = DownloadPartMock(
      bytes: bytes, failureOffset: 524_288, failuresRemaining: 1,
      failure: RealtimeDirectRpcError.rpcError(
        errorCode: .internalError, message: "File download part timed out", code: 408
      )
    )
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    _ = try await NativeFileDownloader(transport: transport).download(fileUniqueID: "INP_download", to: destination)
    #expect(try Data(contentsOf: destination) == bytes)
    let requests = await transport.snapshot().0
    #expect(requests.filter { $0.offset == 0 }.count == 1)
    #expect(requests.filter { $0.offset == 524_288 }.count == 2)
  }

  @Test func exhaustedTimeBudgetRemovesAnonymousIncompleteFile() async throws {
    let manager = NativeDownloadManager(retryBudget: .milliseconds(500), retryBaseDelay: .milliseconds(50))
    let transport = DownloadPartMock(
      bytes: Data(repeating: 3, count: 524_300), failureOffset: 524_288, failuresRemaining: 100
    )
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    await #expect(throws: RealtimeDirectRpcError.self) {
      try await NativeFileDownloader(transport: transport, manager: manager).download(fileUniqueID: "INP_download", to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let attempts = await transport.snapshot().0.filter { $0.offset == 524_288 }.count
    #expect(attempts >= 2 && attempts <= 4)
  }

  @Test func permissionFailureDoesNotRetryARange() async throws {
    let transport = DownloadPartMock(
      bytes: Data(repeating: 3, count: 524_300), failureOffset: 524_288, failuresRemaining: 3,
      failure: RealtimeDirectRpcError.rpcError(errorCode: .unauthenticated, message: "denied", code: 403)
    )
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    await #expect(throws: RealtimeDirectRpcError.self) {
      try await NativeFileDownloader(transport: transport).download(fileUniqueID: "INP_download", to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(await transport.snapshot().0.filter { $0.offset == 524_288 }.count == 1)
  }

  @Test func cancellationStopsRangeRetryBackoff() async throws {
    let transport = DownloadPartMock(
      bytes: Data([1, 2, 3]), failureOffset: 0, failuresRemaining: 3
    )
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let download = Task {
      try await NativeFileDownloader(transport: transport).download(fileUniqueID: "INP_download", to: destination)
    }
    await transport.waitForRequest(0)
    download.cancel()
    await #expect(throws: CancellationError.self) { try await download.value }
    #expect(await transport.snapshot().0.count == 1)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func cancellationDrainsRequestsAndRemovesPartialFile() async throws {
    let transport = DownloadPartMock(bytes: Data(repeating: 4, count: 524_300), stallOffset: 524_288)
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let download = Task {
      try await NativeFileDownloader(transport: transport).download(fileUniqueID: "INP_download", to: destination)
    }
    await transport.waitForRequest(524_288)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let sentinel = Data([9, 8, 7])
    try sentinel.write(to: destination)
    download.cancel()
    await #expect(throws: CancellationError.self) { try await download.value }
    #expect(try Data(contentsOf: destination) == sentinel)
    let partialPrefix = ".\(destination.lastPathComponent).inline-download-"
    let siblings = try FileManager.default.contentsOfDirectory(
      at: destination.deletingLastPathComponent(),
      includingPropertiesForKeys: nil
    )
    #expect(!siblings.contains(where: {
      $0.lastPathComponent.hasPrefix(partialPrefix) && $0.pathExtension == "partial"
    }))
    let (_, _, active) = await transport.snapshot()
    #expect(active == 0)
  }

  @Test func rejectsOversizeBeforeCreatingFileAndPreservesExistingDestination() async throws {
    let transport = DownloadPartMock(bytes: Data([1, 2, 3]))
    let downloader = NativeFileDownloader(transport: transport)
    let destination = downloadDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    await #expect(throws: NativeFileDownloadError.self) {
      try await downloader.download(fileUniqueID: "INP_download", to: destination, maximumByteCount: 2)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let existing = Data([9, 8, 7])
    try existing.write(to: destination)
    let (before, _, _) = await transport.snapshot()
    await #expect(throws: POSIXError.self) {
      try await downloader.download(fileUniqueID: "INP_download", to: destination)
    }
    #expect(try Data(contentsOf: destination) == existing)
    let (after, _, _) = await transport.snapshot()
    #expect(after.count == before.count)
  }
}

private final class DownloadAdmissionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: Set<String> = []
  private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  func mark(_ name: String) {
    lock.lock()
    seen.insert(name)
    let ready = waiters.removeValue(forKey: name) ?? []
    lock.unlock()
    ready.forEach { $0.resume() }
  }
  func wasMarked(_ name: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return seen.contains(name)
  }
  func wait(for name: String) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if seen.contains(name) { lock.unlock(); continuation.resume() }
      else { waiters[name, default: []].append(continuation); lock.unlock() }
    }
  }
}

/// Deliberately delays cancellation completion: the manager must retain the file
/// permit until every outstanding RPC has returned and closed its staging file.
private actor HeldDownloadTransport: NativeFilePartFetching {
  let bytes: Data
  let holdAt: UInt64
  private var released: Set<String> = []
  private var pending: [(String, CheckedContinuation<Void, Never>)] = []
  private var requests: [GetFilePartInput] = []
  private var waiters: [(String, UInt64, CheckedContinuation<Void, Never>)] = []
  private var active = 0
  private var maximum = 0
  private var canceled: Set<String> = []
  private var cancellationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  init(bytes: Data, holdAt: UInt64 = 524_288) { self.bytes = bytes; self.holdAt = holdAt }
  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    #expect(timeout > .zero && timeout <= .seconds(30))
    requests.append(input)
    active += 1; maximum = max(maximum, active)
    defer { active -= 1 }
    let ready = waiters.filter { $0.0 == input.fileUniqueID && $0.1 == input.offset }
    waiters.removeAll { $0.0 == input.fileUniqueID && $0.1 == input.offset }
    ready.forEach { $0.2.resume() }
    if input.offset >= holdAt, !released.contains(input.fileUniqueID) {
      await withTaskCancellationHandler {
        await withCheckedContinuation { pending.append((input.fileUniqueID, $0)) }
      } onCancel: {
        Task { await self.markCanceled(input.fileUniqueID) }
      }
    }
    try Task.checkCancellation()
    var result = GetFilePartResult()
    result.offset = input.offset; result.totalSize = UInt64(bytes.count)
    result.data = bytes.subdata(in: Int(input.offset) ..< min(bytes.count, Int(input.offset) + Int(input.limit)))
    result.sha256 = Data(SHA256.hash(data: result.data))
    return result
  }
  func waitForRequest(_ file: String, offset: UInt64) async {
    if requests.contains(where: { $0.fileUniqueID == file && $0.offset == offset }) { return }
    await withCheckedContinuation { waiters.append((file, offset, $0)) }
  }
  private func markCanceled(_ file: String) {
    canceled.insert(file)
    cancellationWaiters.removeValue(forKey: file)?.forEach { $0.resume() }
  }
  func waitForCancellation(_ file: String) async {
    if canceled.contains(file) { return }
    await withCheckedContinuation { cancellationWaiters[file, default: []].append($0) }
  }
  func release(_ file: String) {
    released.insert(file)
    let ready = pending.filter { $0.0 == file }
    pending.removeAll { $0.0 == file }
    ready.forEach { $0.1.resume() }
  }
  func snapshot() -> ([GetFilePartInput], Int, Int) { (requests, maximum, active) }
}

private actor ProgressBudgetTransport: NativeFilePartFetching {
  struct Call: Sendable, CustomStringConvertible {
    let offset: UInt64
    let timeout: Duration
    let afterFirstWrite: Bool
    var description: String { "offset=\(offset), timeout=\(timeout), afterFirstWrite=\(afterFirstWrite)" }
  }
  let bytes = Data(repeating: 4, count: 524_288 * 2)
  let progress: DownloadAdmissionProbe
  private var calls: [Call] = []
  init(progress: DownloadAdmissionProbe) { self.progress = progress }
  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    calls.append(Call(offset: input.offset, timeout: timeout, afterFirstWrite: progress.wasMarked("first-write")))
    if input.offset == 0, calls.count == 1 { throw RealtimeDirectRpcError.timeout }
    var part = GetFilePartResult()
    part.offset = input.offset; part.totalSize = UInt64(bytes.count)
    part.data = bytes.subdata(in: Int(input.offset) ..< min(bytes.count, Int(input.offset) + Int(input.limit)))
    part.sha256 = Data(SHA256.hash(data: part.data))
    return part
  }
  func snapshot() -> [Call] { calls }
}

private final class FinalByteCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<URL, any Error>?
  func install(_ task: Task<URL, any Error>) { lock.lock(); self.task = task; lock.unlock() }
  func progress(_ count: Int64, _ total: Int64) {
    guard count == total, total > 0 else { return }
    lock.lock(); let task = task; lock.unlock()
    task?.cancel()
  }
}

private func nativeCacheDirectory() throws -> URL {
  let directory = downloadDestination()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
private func nativePartial(_ directory: URL, file: String = "INP_resume") -> URL {
  directory.appendingPathComponent("\(file).inline-partial")
}
private func nativeRecord(
  directory: URL, file: String = "INP_resume", accountID: Int64 = 1,
  total: Int, message: FileMessageLocation? = nil
) throws {
  var values: [String: Any] = ["v": 1, "accountID": accountID, "fileUniqueID": file, "totalSize": total]
  if let message { values["chatID"] = message.chatID; values["messageID"] = message.messageID }
  try JSONSerialization.data(withJSONObject: values).write(to: nativePartial(directory, file: file).appendingPathExtension("json"))
}

@Suite("Native download manager", .serialized)
private struct NativeDownloadManagerTests {
  @Test func duplicatesShareOneOwnerWithIndependentDestinations() async throws {
    let manager = NativeDownloadManager()
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data([1, 2, 3, 4])
    let transport = HeldDownloadTransport(bytes: bytes, holdAt: 0)
    let admitted = DownloadAdmissionProbe()
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    let owner = Task { try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: first, transport: transport)) }
    await transport.waitForRequest("INP_resume", offset: 0)
    let duplicate = Task {
      try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: second,
        validateAccount: { admitted.mark("duplicate") }, transport: transport))
    }
    await admitted.wait(for: "duplicate")
    await transport.release("INP_resume")
    #expect(try await owner.value == first)
    #expect(try await duplicate.value == second)
    #expect(try Data(contentsOf: first) == bytes)
    #expect(try Data(contentsOf: second) == bytes)
    #expect(await transport.snapshot().0.count == 1)
    await manager.discard(fileUniqueID: "INP_resume", accountID: 1, cacheDirectory: directory)
    #expect(try Data(contentsOf: first) == bytes)
  }

  @Test func duplicateRemainsExactWhenOriginalCallerImmediatelyRemovesItsResult() async throws {
    let manager = NativeDownloadManager()
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(repeating: 7, count: 524_300)
    let transport = HeldDownloadTransport(bytes: bytes, holdAt: 0)
    let admitted = DownloadAdmissionProbe()
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    let owner = Task {
      let result = try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: first, transport: transport))
      try FileManager.default.removeItem(at: result)
    }
    await transport.waitForRequest("INP_resume", offset: 0)
    let duplicate = Task {
      try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: second,
        validateAccount: { admitted.mark("duplicate") }, transport: transport))
    }
    await admitted.wait(for: "duplicate")
    await transport.release("INP_resume")
    try await owner.value
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(try await duplicate.value == second)
    #expect(try Data(contentsOf: second) == bytes)
    #expect(await transport.snapshot().0.count == 2)
  }

  @Test func fifoAdmissionAndRepeatedCancellationNeverExceedSixRanges() async throws {
    let manager = NativeDownloadManager()
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for cycle in 0 ..< 3 {
      let transport = HeldDownloadTransport(bytes: Data(repeating: UInt8(cycle), count: 524_288 * 3))
      let admitted = DownloadAdmissionProbe()
      var tasks: [Task<URL, any Error>] = []
      for index in 0 ..< 5 {
        let file = "INP_\(cycle)_\(index)"
        let destination = directory.appendingPathComponent(file)
        tasks.append(Task {
          try await manager.download(.init(accountID: 1, fileUniqueID: file, destination: destination,
            validateAccount: { admitted.mark(file) }, transport: transport))
        })
        await admitted.wait(for: file)
        if index < 3 { await transport.waitForRequest(file, offset: 1_048_576) }
      }
      #expect(await transport.snapshot().2 == 6)
      #expect(await transport.snapshot().0.filter { $0.offset == 0 }.map(\.fileUniqueID) == (0 ..< 3).map { "INP_\(cycle)_\($0)" })
      tasks[0].cancel()
      await transport.waitForCancellation("INP_\(cycle)_0")
      // A canceled task's uncooperative RPCs still hold its two range permits.
      #expect(await transport.snapshot().2 == 6)
      #expect(await transport.snapshot().0.filter { $0.offset == 0 }.count == 3)
      await transport.release("INP_\(cycle)_0")
      await #expect(throws: CancellationError.self) { try await tasks[0].value }
      await transport.waitForRequest("INP_\(cycle)_3", offset: 1_048_576)
      #expect(await transport.snapshot().0.filter { $0.offset == 0 }.map(\.fileUniqueID) == (0 ..< 4).map { "INP_\(cycle)_\($0)" })
      tasks[1].cancel()
      await transport.release("INP_\(cycle)_1")
      await #expect(throws: CancellationError.self) { try await tasks[1].value }
      await transport.waitForRequest("INP_\(cycle)_4", offset: 1_048_576)
      for index in 2 ..< 5 { tasks[index].cancel(); await transport.release("INP_\(cycle)_\(index)") }
      for index in 2 ..< 5 { await #expect(throws: CancellationError.self) { try await tasks[index].value } }
      let (_, maximum, active) = await transport.snapshot()
      #expect(maximum == 6 && active == 0)
    }
  }

  @Test func stopThenNewManagerResumesOnlyContiguousPrefix() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data((0 ..< 524_288 * 4 + 17).map { UInt8($0 % 251) })
    let transport = DownloadPartMock(bytes: bytes, stallOffset: 524_288)
    let destination = directory.appendingPathComponent("finished")
    let manager = NativeDownloadManager()
    let task = Task { try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport)) }
    await transport.waitForRequest(1_048_576)
    await manager.stop(.init(accountID: 1, fileUniqueID: "INP_resume"))
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: nativePartial(directory)) == bytes.prefix(524_288))
    #expect(await transport.snapshot().2 == 0)
    let next = DownloadPartMock(bytes: bytes)
    _ = try await NativeDownloadManager().download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: next))
    #expect(await next.snapshot().0.first?.offset == 524_288)
    #expect(try Data(contentsOf: destination) == bytes)
    #expect(!FileManager.default.fileExists(atPath: nativePartial(directory).path))
    #expect(!FileManager.default.fileExists(atPath: nativePartial(directory).appendingPathExtension("json").path))
  }

  @Test func byteProgressRenewsTheRetryBudget() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let progress = DownloadAdmissionProbe()
    let transport = ProgressBudgetTransport(progress: progress)
    // Observe the lease directly within the 30-second RPC cap. One maximum
    // backoff leaves a clear deadline difference without a short expiry race.
    // This uses a finite real clock; a sufficiently long host stall can expire it.
    let manager = NativeDownloadManager(retryBudget: .seconds(30), retryBaseDelay: .seconds(8))
    let destination = directory.appendingPathComponent("finished")
    do {
      _ = try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport),
        progress: { received, total in
          if received == 524_288, total == 1_048_576 { progress.mark("first-write") }
        })
    } catch {
      let calls = await transport.snapshot()
      Issue.record("Budget renewal failed: \(error); \(calls.count) calls: \(Array(calls.prefix(8)))")
      return
    }
    let calls = await transport.snapshot()
    try #require(calls.count == 3, "Captured calls: \(Array(calls.prefix(8)))")
    #expect(calls.map(\.offset) == [0, 0, 524_288], "Captured calls: \(calls)")
    #expect(calls[1].timeout < calls[0].timeout, "Initial retry must consume its lease: \(calls)")
    #expect(calls[2].afterFirstWrite, "The next range must follow contiguous byte progress: \(calls)")
    // Without lastProgress renewal, causally later remaining() calls can only
    // decrease. A larger post-write timeout proves the lease was renewed.
    #expect(calls[2].timeout > calls[1].timeout, "Contiguous progress must renew the lease: \(calls)")
    #expect(try Data(contentsOf: destination) == transport.bytes)
  }

  @Test func ordinaryRateLimitUsesBudgetBeyondThreeAttemptsAndRetainsPrefix() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(repeating: 9, count: 524_300)
    let rateLimit = RealtimeDirectRpcError.rpcError(errorCode: .rateLimit, message: "Slow down", code: 429)
    let transport = DownloadPartMock(bytes: bytes, failureOffset: 524_288, failuresRemaining: 4, failure: rateLimit)
    let manager = NativeDownloadManager(retryBudget: .seconds(2), retryBaseDelay: .milliseconds(10))
    let destination = directory.appendingPathComponent("finished")
    _ = try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport))
    #expect(await transport.snapshot().0.filter { $0.offset == 524_288 }.count == 5)
    #expect(try Data(contentsOf: destination) == bytes)
    try FileManager.default.removeItem(at: destination)
    let failing = DownloadPartMock(bytes: bytes, failureOffset: 524_288, failuresRemaining: 100, failure: rateLimit)
    let short = NativeDownloadManager(retryBudget: .milliseconds(150), retryBaseDelay: .milliseconds(20))
    await #expect(throws: RealtimeDirectRpcError.self) {
      try await short.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: failing))
    }
    #expect(try Data(contentsOf: nativePartial(directory)) == bytes.prefix(524_288))
    #expect(await failing.snapshot().2 == 0)
  }

  @Test(arguments: ["badJSON", "oversizedJSON", "account", "identity", "oversize", "remoteTotal"])
  func mismatchedRecordRestartsFromZero(_ mismatch: String) async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(repeating: 6, count: 524_300)
    try Data(repeating: 0xff, count: 524_288).write(to: nativePartial(directory))
    try nativeRecord(directory: directory, accountID: mismatch == "account" ? 2 : 1,
      total: mismatch == "oversize" ? 500_000_001 : mismatch == "remoteTotal" ? 524_400 : bytes.count)
    let recordURL = nativePartial(directory).appendingPathExtension("json")
    if mismatch == "badJSON" { try Data("{".utf8).write(to: recordURL) }
    if mismatch == "oversizedJSON" { try Data(repeating: 0x20, count: 2_049).write(to: recordURL) }
    if mismatch == "identity" {
      var record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
      record["fileUniqueID"] = "INP_other"
      try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
    }
    let transport = DownloadPartMock(bytes: bytes)
    let destination = directory.appendingPathComponent("finished")
    _ = try await NativeDownloadManager().download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport))
    #expect(await transport.snapshot().0.contains(where: { $0.offset == 0 }))
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test func incompleteTailIsRoundedDownAndAlignedCompletePartialRecovers() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for complete in [false, true] {
      let bytes = Data((0 ..< 524_288 * 2).map { UInt8($0 % 251) })
      try bytes.prefix(complete ? bytes.count : 524_288 + 7).write(to: nativePartial(directory))
      try nativeRecord(directory: directory, total: bytes.count)
      let transport = DownloadPartMock(bytes: bytes)
      let destination = directory.appendingPathComponent(complete ? "complete" : "tail")
      _ = try await NativeDownloadManager().download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport))
      #expect(await transport.snapshot().0.map(\.offset) == [524_288])
      #expect(try Data(contentsOf: destination) == bytes)
    }
  }

  @Test func permissionAndIntegrityFailuresDiscardExistingPrefix() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for integrity in [false, true] {
      let bytes = Data(repeating: 6, count: 524_300)
      try bytes.prefix(524_288).write(to: nativePartial(directory))
      try nativeRecord(directory: directory, total: bytes.count)
      let transport = DownloadPartMock(bytes: bytes, corruption: integrity ? .digest : .none,
        failureOffset: 524_288, failuresRemaining: integrity ? 0 : 1,
        failure: RealtimeDirectRpcError.notAuthorized)
      await #expect(throws: (any Error).self) {
        try await NativeDownloadManager().download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: directory.appendingPathComponent("finished"), transport: transport))
      }
      #expect(!FileManager.default.fileExists(atPath: nativePartial(directory).path))
      #expect(!FileManager.default.fileExists(atPath: nativePartial(directory).appendingPathExtension("json").path))
      #expect(await transport.snapshot().0.count == 1)
    }
  }

  @Test func logoutDrainsActiveRangesAndPurgesOnlyItsAccountAfterRelaunch() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(repeating: 6, count: 524_288 * 3)
    let transport = HeldDownloadTransport(bytes: bytes)
    let manager = NativeDownloadManager()
    let destination = directory.appendingPathComponent("finished")
    let task = Task { try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport)) }
    await transport.waitForRequest("INP_resume", offset: 1_048_576)
    let stopping = Task { await manager.stopAll(accountID: 1, cacheDirectories: [directory]) }
    await transport.waitForCancellation("INP_resume")
    await transport.release("INP_resume")
    await stopping.value
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.snapshot().2 == 0)
    #expect(!FileManager.default.fileExists(atPath: nativePartial(directory).path))
    for account in [Int64(1), 2] {
      let file = "INP_account\(account)"
      try bytes.prefix(524_288).write(to: nativePartial(directory, file: file))
      try nativeRecord(directory: directory, file: file, accountID: account, total: bytes.count)
    }
    await NativeDownloadManager().stopAll(accountID: 1, cacheDirectories: [directory])
    #expect(!FileManager.default.fileExists(atPath: nativePartial(directory, file: "INP_account1").path))
    #expect(FileManager.default.fileExists(atPath: nativePartial(directory, file: "INP_account2").path))
  }

  @Test func messageDeletionDrainsDuplicateReferencesAndPurgesIdleProvenance() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var original = FileMessageLocation(); original.chatID = 10; original.messageID = 20
    var other = original; other.messageID = 21
    let originalLocation = original; let otherLocation = other
    let transport = HeldDownloadTransport(bytes: Data(repeating: 7, count: 524_288 * 3))
    let manager = NativeDownloadManager()
    let first = Task { try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", message: originalLocation, destination: directory.appendingPathComponent("first"), transport: transport)) }
    await transport.waitForRequest("INP_resume", offset: 1_048_576)
    let probe = DownloadAdmissionProbe()
    let duplicate = Task { try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", message: otherLocation, destination: directory.appendingPathComponent("second"), validateAccount: { probe.mark("duplicate") }, transport: transport)) }
    await probe.wait(for: "duplicate")
    let deleting = Task { await manager.discard(message: originalLocation, accountID: 1, cacheDirectories: [directory]) }
    await transport.waitForCancellation("INP_resume")
    await transport.release("INP_resume")
    await deleting.value
    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await duplicate.value }
    #expect(!FileManager.default.fileExists(atPath: nativePartial(directory).path))
    try Data([1]).write(to: nativePartial(directory))
    try nativeRecord(directory: directory, total: 3, message: originalLocation)
    await NativeDownloadManager().discard(message: originalLocation, accountID: 1, cacheDirectories: [directory])
    #expect(!FileManager.default.fileExists(atPath: nativePartial(directory).path))
  }

  @MainActor @Test func changedAccountGenerationDrainsOldOwnerBeforeRestart() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let auth = Auth.mocked(authenticated: true)
    let handle = auth.handle
    let oldToken = try handle.beginAccountMutation()
    let bytes = Data(repeating: 7, count: 524_288 * 3)
    let transport = HeldDownloadTransport(bytes: bytes)
    let manager = NativeDownloadManager()
    let first = Task {
      try await manager.download(.init(accountID: oldToken.userID, fileUniqueID: "INP_resume", destination: directory.appendingPathComponent("old"),
        accountToken: oldToken, validateAccount: { try handle.validateAccountMutation(oldToken) }, transport: transport))
    }
    await transport.waitForRequest("INP_resume", offset: 1_048_576)
    // Same-account credential refresh intentionally preserves the generation.
    // Switch away and back to exercise a real authority transition for this UID.
    try await auth.saveCredentials(token: "native-download-other-account-test-fixture", userId: oldToken.userID + 1)
    try await auth.saveCredentials(token: "native-download-generation-test-fixture", userId: oldToken.userID)
    let newToken = try handle.beginAccountMutation()
    do { try #require(oldToken != newToken) }
    catch {
      first.cancel()
      await transport.release("INP_resume")
      _ = await first.result
      throw error
    }
    let next = Task {
      try await manager.download(.init(accountID: newToken.userID, fileUniqueID: "INP_resume", destination: directory.appendingPathComponent("new"),
        accountToken: newToken, validateAccount: { try handle.validateAccountMutation(newToken) }, transport: transport))
    }
    await transport.waitForCancellation("INP_resume")
    await transport.release("INP_resume")
    await #expect(throws: (any Error).self) { try await first.value }
    let result = try await next.value
    #expect(try Data(contentsOf: result) == bytes)
    #expect(await transport.snapshot().0.filter { $0.offset == 0 }.count == 2)
    #expect(await transport.snapshot().2 == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("old").path))
    let fence = try auth.beginLogoutSynchronously()
    let proof = try #require(await auth.destroyCredentialsForPendingLogout(fence: fence))
    #expect(await auth.completePendingLogout(fence: fence, databaseProof: AuthDatabaseCleanupProof(fence: fence),
      credentialProof: proof, completionPermit: AuthLogoutCompletionPermit(fence: fence)))
  }

  @Test func cancellationAtFinalByteRetainsCompletePrefixForRecovery() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(repeating: 7, count: 524_288 * 2)
    let transport = HeldDownloadTransport(bytes: bytes)
    let destination = directory.appendingPathComponent("finished")
    let manager = NativeDownloadManager()
    let cancellation = FinalByteCancellation()
    let task = Task {
      try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport),
        progress: { cancellation.progress($0, $1) })
    }
    cancellation.install(task)
    await transport.waitForRequest("INP_resume", offset: 524_288)
    await transport.release("INP_resume")
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: nativePartial(directory)) == bytes)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    let retry = DownloadPartMock(bytes: bytes)
    _ = try await NativeDownloadManager().download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: retry))
    #expect(await retry.snapshot().0.map(\.offset) == [524_288])
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test func finalPublicationNeverOverwritesAndCanRecoverCompletePartial() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bytes = Data(repeating: 7, count: 524_288 * 2)
    let transport = HeldDownloadTransport(bytes: bytes)
    let manager = NativeDownloadManager()
    let destination = directory.appendingPathComponent("finished")
    let task = Task { try await manager.download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: transport)) }
    await transport.waitForRequest("INP_resume", offset: 524_288)
    let sentinel = Data([9, 8, 7]); try sentinel.write(to: destination)
    await transport.release("INP_resume")
    await #expect(throws: POSIXError.self) { try await task.value }
    #expect(try Data(contentsOf: destination) == sentinel)
    #expect(try Data(contentsOf: nativePartial(directory)) == bytes)
    try FileManager.default.removeItem(at: destination)
    let retry = DownloadPartMock(bytes: bytes)
    _ = try await NativeDownloadManager().download(.init(accountID: 1, fileUniqueID: "INP_resume", destination: destination, transport: retry))
    #expect(await retry.snapshot().0.map(\.offset) == [524_288])
    #expect(try Data(contentsOf: destination) == bytes)
  }

  @Test func sweepRemovesOldOrphanRecordsAndPreservesRecentFiles() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try nativeRecord(directory: directory, file: "INP_orphan", total: 3)
    let oldRecord = nativePartial(directory, file: "INP_orphan").appendingPathExtension("json")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)], ofItemAtPath: oldRecord.path)
    try Data([1]).write(to: nativePartial(directory))
    try nativeRecord(directory: directory, total: 3)
    await NativeDownloadManager().sweep(directory: directory)
    #expect(!FileManager.default.fileExists(atPath: oldRecord.path))
    #expect(FileManager.default.fileExists(atPath: nativePartial(directory).path))
  }

  @Test func cleanupSkipsFilesLockedByAnotherOwnerAndUnknownAccountRecords() async throws {
    let directory = try nativeCacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let body = nativePartial(directory)
    try Data([1, 2, 3]).write(to: body)
    try nativeRecord(directory: directory, total: 3)
    let descriptor = body.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
    #expect(descriptor >= 0)
    defer { if descriptor >= 0 { Darwin.close(descriptor) } }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: body.path)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: body.appendingPathExtension("json").path)
    let manager = NativeDownloadManager()
    await manager.stopAll(accountID: 1, cacheDirectories: [directory])
    await manager.discard(fileUniqueID: "INP_resume", accountID: 1, cacheDirectory: directory)
    await manager.sweep(directory: directory)
    #expect(try Data(contentsOf: body) == Data([1, 2, 3]))
    #expect(flock(descriptor, LOCK_UN) == 0)
    await manager.stopAll(accountID: 1, cacheDirectories: [directory])
    #expect(!FileManager.default.fileExists(atPath: body.path))
    try Data([4, 5, 6]).write(to: body)
    await manager.stopAll(accountID: 1, cacheDirectories: [directory])
    #expect(try Data(contentsOf: body) == Data([4, 5, 6]))
  }

  @Test func permissionClassifierCoversPrivacyPreservingMissingFiles() {
    for status in [400, 401, 403, 404] {
      #expect(NativeMessageFileDownload.isPermissionFailure(RealtimeDirectRpcError.rpcError(errorCode: .internalError, message: "Unavailable", code: status)))
    }
    #expect(NativeMessageFileDownload.isPermissionFailure(NativeFileDownloadError.inaccessible))
    #expect(!NativeMessageFileDownload.isPermissionFailure(NativeFileDownloadError.invalidResponse))
    #expect(!NativeMessageFileDownload.isPermissionFailure(NativeFileDownloadError.integrity))
  }
}
