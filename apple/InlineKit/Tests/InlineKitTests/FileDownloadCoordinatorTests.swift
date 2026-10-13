import Auth
import Foundation
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

  private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("inline-download-coordinator-\(UUID())")
  }
}
