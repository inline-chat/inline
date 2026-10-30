import Foundation
import Testing
@testable import InlineKit

@Suite("Latest history page retry")
@MainActor
struct MessageHistoryLatestRetryTests {
  private actor Attempts {
    private(set) var count = 0

    func next() -> Int {
      count += 1
      return count
    }
  }

  private struct Failure: Error {}

  private func load(peer: Peer, attempts: Attempts, failures: Int) async {
    await MessageHistoryRepairCoordinator.shared.loadLatest(
      peer: peer,
      retryDelays: [.zero, .zero]
    ) {
      if await attempts.next() <= failures { throw Failure() }
    }
  }

  @Test("A successful page is not fetched again")
  func successStops() async {
    let attempts = Attempts()
    await load(peer: .thread(id: 9_001), attempts: attempts, failures: 0)
    #expect(await attempts.count == 1)
  }

  @Test("A failed page is asked for again")
  func failureRetries() async {
    let attempts = Attempts()
    await load(peer: .thread(id: 9_002), attempts: attempts, failures: 1)
    #expect(await attempts.count == 2)
  }

  @Test("Repeated failure stops at the retry limit")
  func repeatedFailureStops() async {
    let attempts = Attempts()
    await load(peer: .thread(id: 9_003), attempts: attempts, failures: .max)
    #expect(await attempts.count == 3)
  }

  @Test("Concurrent requests for a chat share one fetch")
  func concurrentRequestsShareOneFetch() async {
    let attempts = Attempts()
    let fetch: @Sendable () async throws -> Void = {
      _ = await attempts.next()
      try await Task.sleep(for: .milliseconds(200))
    }
    let coordinator = MessageHistoryRepairCoordinator.shared
    async let first: Void = coordinator.loadLatest(peer: .thread(id: 9_004), retryDelays: [], fetch: fetch)
    async let second: Void = coordinator.loadLatest(peer: .thread(id: 9_004), retryDelays: [], fetch: fetch)
    _ = await (first, second)
    #expect(await attempts.count == 1)
  }
}
