import Auth
import Combine
import CryptoKit
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing
@testable import InlineKit

private actor TransferTestGate {
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    opened = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private actor CoordinatorPublicationTransport: NativeFilePartFetching {
  let started = TransferTestGate()
  let release = TransferTestGate()
  private(set) var requests = 0

  func fetchFilePart(_ input: GetFilePartInput, timeout: Duration) async throws -> GetFilePartResult {
    requests += 1
    await started.open()
    await release.wait()
    try Task.checkCancellation()
    var result = GetFilePartResult()
    result.offset = input.offset
    result.totalSize = 1
    result.data = Data([7])
    result.sha256 = Data(SHA256.hash(data: result.data))
    return result
  }
}

@Suite("File download coordinator", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct FileDownloadCoordinatorTests {
  @Test func duplicateStartJoinsOneTransfer() async throws {
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle)
    let started = TransferTestGate()
    let release = TransferTestGate()
    let done = AsyncStream<Void>.makeStream()
    let destination = temporaryFile()
    defer { try? FileManager.default.removeItem(at: destination) }
    var results: [URL] = []
    var tokens: [UUID] = []
    owner.downloadFile(id: "doc_801", url: nil, localUrl: destination, nativeDownload: { url, _ in
      await started.open()
      await release.wait()
      try Data([1]).write(to: url)
      return url
    }) { token, result in
      tokens.append(token)
      if case let .success(url) = result { results.append(url) }
      else { Issue.record("Owner download failed") }
      done.continuation.yield()
    }
    await started.wait()
    owner.downloadFile(id: "doc_801", url: nil, localUrl: temporaryFile(), nativeDownload: { _, _ in
      Issue.record("Duplicate admission started a second operation")
      throw URLError(.badURL)
    }) { token, result in
      tokens.append(token)
      if case let .success(url) = result { results.append(url) }
      else { Issue.record("Joined download failed") }
      done.continuation.yield()
    }
    await release.open()
    var iterator = done.stream.makeAsyncIterator()
    _ = await iterator.next()
    _ = await iterator.next()
    #expect(results == [destination, destination])
    #expect(tokens.count == 2 && tokens[0] == tokens[1])
    #expect(!owner.isDocumentDownloadActive(documentId: 801))
    await owner.resetSession()
  }

  @Test func cancelStartWaitsForOldNativeOwnershipToSettle() async throws {
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle)
    let firstStarted = TransferTestGate()
    let oldCleanup = TransferTestGate()
    let secondStarted = TransferTestGate()
    let secondDone = AsyncStream<Void>.makeStream()
    let destination = temporaryFile()
    defer { try? FileManager.default.removeItem(at: destination) }
    var cancellations = 0
    owner.downloadFile(id: "doc_802", url: nil, localUrl: destination, nativeDownload: { _, _ in
      await firstStarted.open()
      // Deliberately retain a file owner after cancellation until its cleanup
      // settles; the coordinator must never race a replacement with this work.
      await oldCleanup.wait()
      try Task.checkCancellation()
      throw URLError(.cancelled)
    }) { _, result in
      if case let .failure(error) = result { #expect(FileDownloader.isCancellation(error)); cancellations += 1 }
      else { Issue.record("Canceled native download succeeded") }
    }
    await firstStarted.wait()
    owner.cancelDocumentDownload(documentId: 802)
    owner.downloadFile(id: "doc_802", url: nil, localUrl: destination, nativeDownload: { url, _ in
      await secondStarted.open()
      try Data([2]).write(to: url)
      return url
    }) { _, result in
      if case .failure = result { Issue.record("Restart failed") }
      secondDone.continuation.yield()
    }
    #expect(!owner.isDocumentDownloadActive(documentId: 802))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    await oldCleanup.open()
    await secondStarted.wait()
    var iterator = secondDone.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(cancellations == 1)
    #expect(try Data(contentsOf: destination) == Data([2]))
    await owner.resetSession()
  }

  @Test func nativeFailureAutomaticallyFallsBackAfterOperationSettles() async {
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle)
    let settled = TransferTestGate()
    let done = AsyncStream<Void>.makeStream()
    var completions = 0
    owner.downloadFile(id: "video_803", url: URL(string: "unsupported-fallback://file")!,
                       localUrl: temporaryFile(), nativeDownload: { _, _ in
      await settled.open()
      throw NativeFileDownloadError.integrity
    }) { _, result in
      completions += 1
      guard case let .failure(error) = result else { Issue.record("Unsupported CDN URL succeeded"); return }
      // Receiving Foundation's URL error proves the native integrity failure
      // progressed into the CDN path, rather than terminating the request.
      #expect(error is URLError)
      done.continuation.yield()
    }
    await settled.wait()
    var iterator = done.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(completions == 1)
    #expect(!owner.isVideoDownloadActive(videoId: 803))
    await owner.resetSession()
  }

  @Test func accountFenceRejectsLateNativeCompletionAndFallback() async throws {
    let auth = Auth.mocked(authenticated: true)
    let owner = FileDownloader(auth: auth.handle)
    let token = try auth.handle.beginAccountMutation()
    let started = TransferTestGate()
    let release = TransferTestGate()
    let done = AsyncStream<Void>.makeStream()
    let destination = temporaryFile()
    defer { try? FileManager.default.removeItem(at: destination) }
    owner.downloadFile(id: "doc_804", url: URL(string: "unsupported-fallback://file")!,
                       localUrl: destination, accountToken: token, nativeDownload: { url, _ in
      await started.open()
      await release.wait()
      try Data([1]).write(to: url)
      return url
    }) { _, result in
      guard case let .failure(error) = result else { Issue.record("Late old-account completion succeeded"); return }
      #expect(FileDownloader.isCancellation(error))
      done.continuation.yield()
    }
    await started.wait()
    _ = try auth.beginLogoutSynchronously()
    await release.open()
    var iterator = done.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    await owner.resetSession()
  }

  @Test(arguments: [400, 401, 403, 404])
  func inaccessibleNativeFailureNeverFallsBack(status: Int) async {
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle)
    let done = AsyncStream<Void>.makeStream()
    owner.downloadFile(id: "doc_805", url: URL(string: "unsupported-fallback://file")!,
                       localUrl: temporaryFile(), nativeDownload: { _, _ in
      // The server deliberately uses 400 for both absent and inaccessible files.
      throw RealtimeDirectRpcError.rpcError(errorCode: .badRequest, message: nil, code: status)
    }) { _, result in
      guard case let .failure(error) = result,
            case let .rpcError(_, _, code)? = error as? RealtimeDirectRpcError else {
        Issue.record("Permission error reached CDN or disappeared")
        done.continuation.yield()
        return
      }
      #expect(code == status)
      done.continuation.yield()
    }
    var iterator = done.stream.makeAsyncIterator()
    _ = await iterator.next()
    await owner.resetSession()
  }

  @Test func explicitStopNeverFallsBackAfterLateFailure() async {
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle)
    let started = TransferTestGate()
    let release = TransferTestGate()
    var completions = 0
    owner.downloadFile(id: "doc_806", url: URL(string: "unsupported-fallback://file")!,
                       localUrl: temporaryFile(), nativeDownload: { _, _ in
      await started.open()
      await release.wait()
      throw NativeFileDownloadError.integrity
    }) { _, result in
      completions += 1
      if case let .failure(error) = result { #expect(FileDownloader.isCancellation(error)) }
      else { Issue.record("Stopped download completed") }
    }
    await started.wait()
    owner.cancelDocumentDownload(documentId: 806)
    await release.open()
    await owner.resetSession()
    #expect(completions == 1)
    #expect(owner.currentDocumentProgress(documentId: 806) == nil)
  }

  @Test func sharedNativeResultGetsAnIndependentCacheOwner() async throws {
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle)
    let firstOwnerFile = temporaryFile()
    let destination = temporaryFile()
    try Data([7]).write(to: firstOwnerFile)
    defer {
      try? FileManager.default.removeItem(at: firstOwnerFile)
      try? FileManager.default.removeItem(at: destination)
    }
    let done = AsyncStream<Void>.makeStream()
    owner.downloadFile(id: "doc_807", url: nil, localUrl: destination, nativeDownload: { _, _ in firstOwnerFile }) { _, result in
      if case let .success(url) = result { #expect(url == destination) }
      else { Issue.record("Shared result failed to materialize") }
      done.continuation.yield()
    }
    var iterator = done.stream.makeAsyncIterator()
    _ = await iterator.next()
    try FileManager.default.removeItem(at: destination)
    #expect(try Data(contentsOf: firstOwnerFile) == Data([7]))
    await owner.resetSession()
  }

  @Test func canceledOriginalCannotRemoveJoinedPublication() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = NativeDownloadManager()
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle,
                               nativeManager: manager, nativeCacheDirectories: [directory])
    let transport = CoordinatorPublicationTransport()
    let original = directory.appendingPathComponent("original")
    let duplicate = directory.appendingPathComponent("duplicate")
    let originalPublished = TransferTestGate()
    let duplicatePublished = TransferTestGate()
    let releaseOriginal = TransferTestGate()
    let releaseDuplicate = TransferTestGate()
    let admitted = AsyncStream<Void>.makeStream()
    let done = AsyncStream<Void>.makeStream()
    var cancellations = 0

    owner.downloadFile(id: "doc_808", url: nil, localUrl: original, nativeDownload: { destination, _ in
      let result = try await manager.download(.init(accountID: 1, fileUniqueID: "IND_publication",
                                                   destination: destination, transport: transport))
      await originalPublished.open()
      await releaseOriginal.wait()
      return result
    }) { _, result in
      if case let .failure(error) = result { #expect(FileDownloader.isCancellation(error)); cancellations += 1 }
      else { Issue.record("Canceled original completed") }
    }
    await transport.started.wait()
    owner.downloadFile(id: "doc_809", url: nil, localUrl: duplicate, nativeDownload: { destination, _ in
      let result = try await manager.download(.init(accountID: 1, fileUniqueID: "IND_publication",
        destination: destination, validateAccount: { admitted.continuation.yield() }, transport: transport))
      await duplicatePublished.open()
      await releaseDuplicate.wait()
      return result
    }) { _, result in
      if case let .success(url) = result { #expect(url == duplicate) }
      else { Issue.record("Joined publication was removed with the original") }
      done.continuation.yield()
    }
    var admissions = admitted.stream.makeAsyncIterator()
    _ = await admissions.next()
    await transport.release.open()
    await originalPublished.wait()
    await duplicatePublished.wait()

    owner.cancelDocumentDownload(documentId: 808)
    await releaseOriginal.open()
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while FileManager.default.fileExists(atPath: original.path), ContinuousClock.now < deadline { await Task.yield() }
    #expect(!FileManager.default.fileExists(atPath: original.path))
    // The duplicate link must exist before its coordinator continuation resumes.
    #expect(FileManager.default.fileExists(atPath: duplicate.path))
    await releaseDuplicate.open()
    var completions = done.stream.makeAsyncIterator()
    _ = await completions.next()
    #expect(cancellations == 1)
    #expect(try Data(contentsOf: duplicate) == Data([7]))
    #expect(await transport.requests == 1)
    await owner.resetSession()
  }

  @Test func resetPurgesCapturedIdleAccountAndKeepsAnotherAccount() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = try partial(in: directory, fileID: "IND_old", accountID: 17)
    let other = try partial(in: directory, fileID: "IND_other", accountID: 18)
    let owner = FileDownloader(auth: Auth.mocked(authenticated: false).handle,
                               nativeManager: NativeDownloadManager(), nativeCacheDirectories: [directory])
    await owner.resetSession(accountID: 17)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: other.path))
  }

  @Test func messageDeletionPurgesOnlyCapturedProvenance() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let deleted = try partial(in: directory, fileID: "IND_deleted", accountID: 1, chatID: 42, messageID: 7)
    let survivor = try partial(in: directory, fileID: "IND_survivor", accountID: 1, chatID: 42, messageID: 8)
    let auth = Auth.mocked(authenticated: true)
    let owner = FileDownloader(auth: auth.handle, nativeManager: NativeDownloadManager(), nativeCacheDirectories: [directory])
    await owner.discardMessageDownloads(accountToken: try auth.handle.beginAccountMutation(), chatID: 42, messageIDs: [7])
    #expect(!FileManager.default.fileExists(atPath: deleted.path))
    #expect(FileManager.default.fileExists(atPath: survivor.path))
    await owner.resetSession()
  }

  @Test func launchSweepExpiresOnlyOldIdlePartial() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = try partial(in: directory, fileID: "IND_expired", accountID: 1)
    let current = try partial(in: directory, fileID: "IND_current", accountID: 1)
    let past = Date().addingTimeInterval(-8 * 24 * 60 * 60)
    for url in [old, old.appendingPathExtension("json")] {
      try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    }
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle,
                               nativeManager: NativeDownloadManager(), nativeCacheDirectories: [directory])
    await owner.prepareForLaunch()
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: current.path))
    await owner.resetSession()
  }

  @Test func cacheClearErrorReopensDownloadAdmission() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle,
                               nativeManager: NativeDownloadManager(), nativeCacheDirectories: [directory])
    let writer = try DatabaseQueue()
    let database = try AppDatabase(writer)
    try await writer.write { db in try db.drop(table: PhotoSize.databaseTableName) }
    let cache = FileCache(database: database)
    await #expect(throws: (any Error).self) { try await cache.clearCache(downloadCoordinator: owner) }
    let destination = directory.appendingPathComponent("after-error")
    let done = AsyncStream<Void>.makeStream()
    owner.downloadFile(id: "doc_808", url: nil, localUrl: destination, nativeDownload: { url, _ in
      try Data([9]).write(to: url)
      return url
    }) { _, result in
      if case .failure = result { Issue.record("Cache error kept download admission closed") }
      done.continuation.yield()
    }
    var iterator = done.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(FileManager.default.fileExists(atPath: destination.path))
    await owner.resetSession()
  }

  @Test func queuedRestartCannotEscapeSessionReset() async {
    let owner = FileDownloader(auth: Auth.mocked(authenticated: true).handle)
    let started = TransferTestGate()
    let cleanup = TransferTestGate()
    let resetStarted = AsyncStream<Void>.makeStream()
    var restarts = 0
    var cancellations = 0
    owner.downloadFile(id: "doc_809", url: nil, localUrl: temporaryFile(), nativeDownload: { _, _ in
      await started.open()
      await cleanup.wait()
      try Task.checkCancellation()
      throw URLError(.cancelled)
    }) { _, result in
      if case let .failure(error) = result { #expect(FileDownloader.isCancellation(error)); cancellations += 1 }
    }
    await started.wait()
    owner.cancelDocumentDownload(documentId: 809)
    owner.downloadFile(id: "doc_809", url: nil, localUrl: temporaryFile(), nativeDownload: { _, _ in
      Issue.record("A pre-reset restart escaped the reset fence")
      throw URLError(.badURL)
    }) { _, result in
      restarts += 1
      if case let .failure(error) = result { #expect(FileDownloader.isCancellation(error)) }
      else { Issue.record("Queued restart succeeded after reset") }
    }
    let observation = owner.documentProgressPublisher(documentId: 999).sink(
      receiveCompletion: { _ in resetStarted.continuation.yield() }, receiveValue: { _ in }
    )
    let reset = Task { await owner.resetSession() }
    var iterator = resetStarted.stream.makeAsyncIterator()
    _ = await iterator.next()
    await cleanup.open()
    await reset.value
    // The queued waiter may resume immediately after the drain receipt.
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while restarts == 0, ContinuousClock.now < deadline { await Task.yield() }
    #expect(restarts == 1)
    #expect(cancellations == 1)
    #expect(!owner.isDocumentDownloadActive(documentId: 809))
    observation.cancel()
  }

  private func temporaryDirectory() throws -> URL {
    let directory = temporaryFile()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func partial(in directory: URL, fileID: String, accountID: Int64,
                       chatID: Int64? = nil, messageID: Int64? = nil) throws -> URL {
    let url = directory.appendingPathComponent(fileID + ".inline-partial")
    try Data([1]).write(to: url)
    var record: [String: Any] = ["v": 1, "accountID": accountID, "fileUniqueID": fileID, "totalSize": 524_288]
    if let chatID, let messageID { record["chatID"] = chatID; record["messageID"] = messageID }
    try JSONSerialization.data(withJSONObject: record).write(to: url.appendingPathExtension("json"))
    return url
  }

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("inline-download-coordinator-\(UUID())")
  }
}
