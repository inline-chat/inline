import Foundation
import Synchronization
import Testing

@testable import InlineObjectCache

@Suite("Object remote loader")
@MainActor
struct ObjectRemoteLoaderTests {
  private final class Remote: Sendable {
    private struct State {
      var known: Set<Int> = []
      var batches: [[Int]] = []
      var failing = false
    }

    private let state = Mutex(State())

    init(known: Set<Int>) {
      state.withLock { $0.known = known }
    }

    var batches: [[Int]] { state.withLock { $0.batches } }

    func setFailing(_ failing: Bool) {
      state.withLock { $0.failing = failing }
    }

    func fetch(_ ids: [Int]) async throws -> ObjectFetchOutcome<Int> {
      let (known, failing) = state.withLock { state in
        state.batches.append(ids)
        return (state.known, state.failing)
      }
      try await Task.sleep(for: .milliseconds(5))
      if failing { throw CancellationError() }
      // Negative IDs stand for records the remote could not be asked about this time.
      return ObjectFetchOutcome(resolved: known.intersection(ids), failed: Set(ids.filter { $0 < 0 }))
    }
  }

  private final class TestClock {
    var now = ContinuousClock.now
  }

  private func makeLoader(
    _ remote: Remote, clock: TestClock = TestClock(), batchSize: Int = 100, maxAttempts: Int = 3
  ) -> ObjectRemoteLoader<Int> {
    ObjectRemoteLoader(
      policy: .init(
        coalesceWindow: .milliseconds(10), batchSize: batchSize, maxAttempts: maxAttempts,
        retryAfter: .seconds(60)
      ),
      now: { clock.now },
      fetch: { try await remote.fetch($0) }
    )
  }

  @Test("requests made close together share one fetch and report what resolved")
  func coalescesRequests() async {
    let remote = Remote(known: [1, 2, 3])
    let loader = makeLoader(remote)
    async let first = loader.ensure([1, 2])
    async let second = loader.ensure([2, 3, 9])
    #expect(await first == [1, 2])
    #expect(await second == [2, 3])
    #expect(remote.batches.map { $0.sorted() } == [[1, 2, 3, 9]])
  }

  @Test("large requests are split into batches")
  func splitsBatches() async {
    let remote = Remote(known: Set(1 ... 5))
    let loader = makeLoader(remote, batchSize: 2)
    #expect(await loader.ensure([1, 2, 3, 4, 5]) == [1, 2, 3, 4, 5])
    #expect(remote.batches == [[1, 2], [3, 4], [5]])
  }

  @Test("an ID the remote does not have is left alone until the quiet period passes")
  func absentIsLeftAlone() async {
    let remote = Remote(known: [])
    let clock = TestClock()
    let loader = makeLoader(remote, clock: clock)
    #expect(await loader.ensure([7]).isEmpty)
    #expect(await loader.ensure([7]).isEmpty)
    #expect(remote.batches == [[7]])

    clock.now = clock.now.advanced(by: .seconds(61))
    #expect(await loader.ensure([7]).isEmpty)
    #expect(remote.batches == [[7], [7]])
  }

  @Test("failures are retried on later requests only up to the attempt limit")
  func failuresAreBounded() async {
    let remote = Remote(known: [1])
    remote.setFailing(true)
    let clock = TestClock()
    let loader = makeLoader(remote, clock: clock, maxAttempts: 2)
    for _ in 0 ..< 5 {
      #expect(await loader.ensure([1]).isEmpty)
    }
    #expect(remote.batches.count == 2)

    remote.setFailing(false)
    #expect(await loader.ensure([1]).isEmpty)
    clock.now = clock.now.advanced(by: .seconds(61))
    #expect(await loader.ensure([1]) == [1])
    #expect(remote.batches.count == 3)
  }

  @Test("an ID reported as failed is retried, unlike one reported absent")
  func failedIsRetried() async {
    let remote = Remote(known: [])
    let loader = makeLoader(remote, maxAttempts: 3)
    for _ in 0 ..< 5 {
      #expect(await loader.ensure([-1, 8]).isEmpty)
    }
    // 8 was absent after one fetch; -1 failed and was retried up to the limit.
    #expect(remote.batches == [[-1, 8], [-1], [-1]])
  }

  @Test("reset releases waiters and forgets attempt history")
  func resetReleasesWaiters() async {
    let remote = Remote(known: [])
    let loader = makeLoader(remote)
    #expect(await loader.ensure([4]).isEmpty)
    let waiting = Task { await loader.ensure([5]) }
    await Task.yield()
    loader.reset()
    #expect(await waiting.value.isEmpty)
    // 4 was quiet; after a reset it may be asked for again.
    #expect(await loader.ensure([4]).isEmpty)
    #expect(remote.batches.filter { $0 == [4] }.count == 2)
  }
}
