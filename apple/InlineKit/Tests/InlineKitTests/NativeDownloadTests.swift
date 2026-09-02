import Combine
import CryptoKit
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
  let stallOffset: UInt64?
  let gate = AsyncStream<Void>.makeStream()
  private var requests: [GetFilePartInput] = []
  private var waiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
  private var active = 0
  private var maxActive = 0

  init(bytes: Data, corruption: Corruption = .none, stallOffset: UInt64? = nil) {
    self.bytes = bytes
    self.corruption = corruption
    self.stallOffset = stallOffset
  }

  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    #expect(timeout == .seconds(30))
    requests.append(input)
    waiters.removeValue(forKey: input.offset)?.forEach { $0.resume() }
    active += 1
    maxActive = max(maxActive, active)
    defer { active -= 1 }
    if input.offset == stallOffset {
      for await _ in gate.stream { break }
      try Task.checkCancellation()
    }
    var part = GetFilePartResult()
    part.offset = input.offset
    part.totalSize = UInt64(bytes.count)
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
    return part
  }

  func waitForRequest(_ offset: UInt64) async {
    if requests.contains(where: { $0.offset == offset }) { return }
    await withCheckedContinuation { waiters[offset, default: []].append($0) }
  }
  func release() { gate.continuation.finish() }
  func snapshot() -> ([GetFilePartInput], Int, Int) { (requests, maxActive, active) }
}

@Suite("Native download session ownership", .serialized)
@MainActor private struct NativeDownloadSessionTests {
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
    #expect(try NativeDocumentDownload.fileID(in: result, documentID: 30, location: location) == "IND_wire")
    for mutation in 0 ..< 4 {
      var changed = result
      switch mutation {
      case 0: changed.messages[0].chatID = 11
      case 1: changed.messages[0].id = 21
      case 2: changed.messages[0].media.document.document.id = 31
      default: changed.messages[0].media.document.document.clearFileUniqueID()
      }
      #expect(throws: NativeFileDownloadError.self) {
        try NativeDocumentDownload.fileID(in: changed, documentID: 30, location: location)
      }
    }
  }

  @Test func exactFreshRequestReplayTombstoneRetriesOnceAfterAccountValidation() async throws {
    let probe = FilePartReplayProbe(message: NativeDocumentDownload.freshRequestReplayMessage)
    let result = try await NativeDocumentDownload.callFilePartRPCWithReplay(
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
      _ = try await NativeDocumentDownload.callFilePartRPCWithReplay(
        call: { try await probe.call() },
        validateAccount: { probe.validate() }
      )
    }
    #expect(probe.calls == 1)
    #expect(probe.validations == 1)
  }

  @Test func boundedOutOfOrderRangesProduceExactFile() async throws {
    let partSize = 524_288
    let bytes = Data((0 ..< partSize * 4 + 17).map { UInt8($0 % 251) })
    let transport = DownloadPartMock(bytes: bytes, stallOffset: UInt64(partSize))
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
    await transport.waitForRequest(UInt64(partSize * 2))
    await transport.waitForRequest(UInt64(partSize))
    let (pending, maximum, _) = await transport.snapshot()
    #expect(pending.map(\.offset).sorted() == [0, UInt64(partSize), UInt64(partSize * 2)])
    #expect(maximum <= 2)
    await transport.release()
    let result = try await download.value
    #expect(result == destination)
    #expect(try Data(contentsOf: result) == bytes)
    let (requests, maxActive, active) = await transport.snapshot()
    #expect(requests.count == 5)
    #expect(requests.allSatisfy { $0.message == provenance && $0.fileUniqueID == "INP_download" })
    #expect(maxActive <= 2)
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
