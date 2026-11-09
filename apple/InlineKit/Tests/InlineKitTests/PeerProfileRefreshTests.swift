@testable import Auth
import Foundation
@testable import InlineKit
import Synchronization
import Testing

@Suite("Peer profile refresh")
struct PeerProfileRefreshTests {
  @Test("successful refreshes are bounded while another account generation starts fresh")
  func boundsRefreshesPerAccountGeneration() async throws {
    let refresh = PeerProfileRefresh()
    let calls = Mutex(0)
    let first = AuthAccountMutationToken(generation: 1, userID: 1)
    let replacement = AuthAccountMutationToken(generation: 2, userID: 1)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let operation: @Sendable () async throws -> Void = { calls.withLock { $0 += 1 } }

    try await refresh.refresh(account: first, now: now, operation: operation)
    try await refresh.refresh(account: first, now: now.addingTimeInterval(15), operation: operation)
    #expect(calls.withLock { $0 } == 1)
    try await refresh.refresh(account: first, now: now.addingTimeInterval(30), operation: operation)
    #expect(calls.withLock { $0 } == 2)
    try await refresh.refresh(account: replacement, now: now.addingTimeInterval(31), operation: operation)
    #expect(calls.withLock { $0 } == 3)
  }

  @Test("failed reads remain immediately retryable")
  func retriesFailedRefresh() async throws {
    let refresh = PeerProfileRefresh()
    let account = AuthAccountMutationToken(generation: 1, userID: 1)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    do {
      try await refresh.refresh(account: account, now: now) { throw CancellationError() }
      Issue.record("The failed refresh unexpectedly succeeded")
    } catch is CancellationError {} catch { throw error }

    let calls = Mutex(0)
    try await refresh.refresh(account: account, now: now) { calls.withLock { $0 += 1 } }
    #expect(calls.withLock { $0 } == 1)
  }
}
