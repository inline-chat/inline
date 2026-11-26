import Foundation
@testable import InlineKit
import Testing

@Suite("Catch-up reload coalescing")
struct CatchUpReloadCoalescerTests {
  @MainActor
  @Test("pages that land before the main actor runs merge into one reload per peer")
  func mergesPendingReloads() async throws {
    let recorder = ReloadRecorder()
    let coalescer = CatchUpReloadCoalescer { recorder.peers.append($0) }

    // The test holds the main actor, so the scheduled reload can't run between these.
    coalescer.enqueue([.thread(id: 1), .user(id: 2)])
    coalescer.enqueue([.user(id: 2), .thread(id: 3)])
    coalescer.enqueue([])
    #expect(recorder.peers.isEmpty)

    try await Self.waitUntil { recorder.peers.count >= 3 }
    #expect(recorder.peers.count == 3)
    #expect(Set(recorder.peers) == [.thread(id: 1), .user(id: 2), .thread(id: 3)])

    // After a reload ran, the next page schedules a new one.
    coalescer.enqueue([.thread(id: 1)])
    try await Self.waitUntil { recorder.peers.count >= 4 }
    #expect(recorder.peers.last == .thread(id: 1))
  }

  @Test("enqueueing from many threads at once delivers every peer")
  func concurrentEnqueues() async throws {
    let recorder = await ReloadRecorder()
    let coalescer = CatchUpReloadCoalescer { recorder.peers.append($0) }
    DispatchQueue.concurrentPerform(iterations: 50) { index in
      coalescer.enqueue([.thread(id: Int64(index))])
    }
    try await Self.waitUntil { Set(recorder.peers).count == 50 }
    // A peer is reloaded again only when it was enqueued after a reload took it.
    #expect(await recorder.peers.count >= 50)
  }

  private static func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("condition not met in time")
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

@MainActor
private final class ReloadRecorder {
  var peers: [Peer] = []
}
