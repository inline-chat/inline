import Foundation
import GRDB
import Testing
@testable import InlineKit

@Suite("Photo transfer source lifetime", .timeLimit(.minutes(1)))
struct FileCachePhotoSourceTests {
  @Test("two same-source callers complete from one cancelled transport")
  func sameSourceWaitersShareCancelledTransfer() async throws {
    try await withCache { cache, probe in
      let sharedPhoto = photo("https://example.com/shared.jpg")
      var otherMessage = Message.preview
      otherMessage.messageId += 1
      let first = Task {
        let result = await cache.downloadAndWait(photo: sharedPhoto, reloadMessageOnFinish: .preview)
        await probe.markWaiterComplete()
        return result
      }
      try await probe.waitForStarts(1)
      let second = Task { [otherMessage] in
        let result = await cache.downloadAndWait(photo: sharedPhoto, reloadMessageOnFinish: otherMessage)
        await probe.markWaiterComplete()
        return result
      }
      // Registration happens before joining/scheduling the transfer. Waiting
      // for both subscribers avoids a negative scheduler-timing assertion.
      try await waitUntil { await cache.retainedReloadMessageCount(photoId: 71) == 2 }
      await probe.finish("https://example.com/shared.jpg")
      try await probe.waitForCompletions(2)
      #expect(await first.value == nil)
      #expect(await second.value == nil)
      #expect(await probe.started == ["https://example.com/shared.jpg"])
    }
  }

  @Test("same source joins while a rotated URL waits for old transfer cleanup")
  func joinsAndDrainsSources() async throws {
    try await withCache { cache, probe in
      let first = photo("https://example.com/first.jpg")
      let second = photo("https://example.com/second.jpg")
      await cache.download(photo: first, reloadMessageOnFinish: .preview)
      try await probe.waitForStarts(1)
      await cache.download(photo: first)
      #expect(await probe.started == ["https://example.com/first.jpg"])

      await cache.download(photo: second, reloadMessageOnFinish: .preview)
      #expect(await probe.started == ["https://example.com/first.jpg"])
      await probe.finish("https://example.com/first.jpg")
      try await probe.waitForStarts(2)
      #expect(await cache.retainedReloadMessageCount(photoId: 71) == 1)

      await probe.finish("https://example.com/second.jpg")
      await cache.waitForDownload(photo: second)
      #expect(await cache.retainedReloadMessageCount(photoId: 71) == 0)
    }
  }

  @Test("a caller awaiting the old source never waits for its replacement")
  func awaitsExactTransfer() async throws {
    try await withCache { cache, probe in
      let first = photo("https://example.com/first.jpg")
      let second = photo("https://example.com/second.jpg")
      let waiter = Task {
        let result = await cache.downloadAndWait(photo: first)
        await probe.markWaiterComplete()
        return result
      }
      try await probe.waitForStarts(1)
      await cache.download(photo: second)
      await probe.finish("https://example.com/first.jpg")
      try await probe.waitForCompletions(1)
      #expect(await waiter.value == nil)
      try await probe.waitForStarts(2)
      #expect(await probe.isPending("https://example.com/second.jpg"))
      await cache.cancelDownload(photoId: 71)
      await probe.finish("https://example.com/second.jpg")
      await cache.waitForDownload(photo: second)
    }
  }

  private func photo(_ url: String) -> PhotoInfo {
    PhotoInfo(photo: Photo(id: 9, photoId: 71, format: .jpeg), sizes: [
      PhotoSize(photoId: 9, type: "f", width: 100, height: 100, size: 200, cdnUrl: url),
    ])
  }

  private func withCache(_ body: (FileCache, TransferProbe) async throws -> Void) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let probe = TransferProbe()
    let cache = FileCache(database: database, photoDataLoader: { try await probe.load($0) })
    do {
      try await body(cache, probe)
    } catch {
      await probe.finishAll()
      await cache.cancelAllDownloads()
      throw error
    }
    await probe.finishAll()
    await cache.cancelAllDownloads()
  }

  private func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw ProbeTimeout()
  }

  private struct ProbeTimeout: Error {}

  /// Deliberately ignores task cancellation until released, modelling transport
  /// cleanup that must finish before another source can write the same file.
  private actor TransferProbe {
    private(set) var started: [String] = []
    private(set) var completedWaiterCount = 0
    private var pending: [String: [CheckedContinuation<(Data, URLResponse), Error>]] = [:]
    private var finished = false
    private let starts = AsyncStream<Void>.makeStream()
    private let completions = AsyncStream<Void>.makeStream()

    func waitForStarts(_ count: Int) async throws {
      if started.count >= count { return }
      for await _ in starts.stream {
        if started.count >= count { return }
      }
      throw CancellationError()
    }

    func waitForCompletions(_ count: Int) async throws {
      if completedWaiterCount >= count { return }
      for await _ in completions.stream {
        if completedWaiterCount >= count { return }
      }
      throw CancellationError()
    }

    func load(_ url: URL) async throws -> (Data, URLResponse) {
      guard !finished else { throw CancellationError() }
      started.append(url.absoluteString)
      starts.continuation.yield(())
      return try await withCheckedThrowingContinuation { pending[url.absoluteString, default: []].append($0) }
    }

    func isPending(_ url: String) -> Bool { pending[url] != nil }

    func markWaiterComplete() {
      completedWaiterCount += 1
      completions.continuation.yield(())
    }

    func finish(_ url: String) {
      for continuation in pending.removeValue(forKey: url) ?? [] {
        continuation.resume(throwing: CancellationError())
      }
    }

    func finishAll() {
      finished = true
      starts.continuation.finish()
      completions.continuation.finish()
      let continuations = pending.values.flatMap { $0 }
      pending.removeAll()
      for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
  }
}
