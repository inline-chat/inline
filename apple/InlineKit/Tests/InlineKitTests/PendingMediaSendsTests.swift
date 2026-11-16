import Foundation
import Testing
@testable import InlineKit

@Suite("Pending media sends", .timeLimit(.minutes(1)))
struct PendingMediaSendsTests {
  @Test func aSendIsPendingFromAdmissionUntilItSucceedsFailsOrIsCancelled() async throws {
    let sends = PendingMediaSends()
    let actor = TransactionsActor(waitForConnection: {}, pendingMediaSends: sends)
    let run = UUID().uuidString
    let ok = "\(run)-ok", failing = "\(run)-fail", cancelled = "\(run)-cancel", rejected = "\(run)-rejected"

    await actor.queue(transaction: GatedMediaSend(id: ok))
    await actor.queue(transaction: GatedMediaSend(id: failing, fails: true))
    await actor.queue(transaction: GatedMediaSend(id: cancelled))
    // A text send (no attachments) is never tracked.
    await actor.queue(transaction: GatedMediaSend(id: "\(run)-text", hasMedia: false))
    #expect(Set(sends.current.map(\.transactionId)) == [ok, failing, cancelled])

    // A send cancelled before admission never shows up.
    await actor.cancel(transactionId: rejected)
    await actor.queue(transaction: GatedMediaSend(id: rejected))
    #expect(!sends.current.contains { $0.transactionId == rejected })

    await MediaSendGate.shared.release(ok)
    await MediaSendGate.shared.release(failing)
    await actor.cancel(transactionId: cancelled)
    try await waitUntil { sends.current.isEmpty }
    await MediaSendGate.shared.release("\(run)-text")
  }

  @Test func clearingTheQueueEmptiesTheSet() async throws {
    let sends = PendingMediaSends()
    let actor = TransactionsActor(waitForConnection: {}, pendingMediaSends: sends)
    let id = UUID().uuidString
    await actor.queue(transaction: GatedMediaSend(id: id))
    #expect(sends.current.count == 1)
    await actor.clearAll()
    #expect(sends.current.isEmpty)
  }

  @Test func aRetryAdmittedBeforeTheFailedRunLeftStaysPending() {
    let sends = PendingMediaSends()
    let send = PendingMediaSend(transactionId: "tx", chatId: 1, temporaryMessageId: -1, media: [])
    sends.insert(send)
    sends.insert(send)
    sends.remove(transactionId: "tx")
    #expect(sends.current.map(\.transactionId) == ["tx"])
    sends.remove(transactionId: "tx")
    #expect(sends.current.isEmpty)
  }

  @Test func progressOnlyMovesForwardAndCountsFinishedSendsAsDone() {
    var progress = PendingSendsProgress()
    progress.update(["a": 0.5, "b": 0])
    #expect(progress.units == (completed: 500, total: 2_000))
    // A retry restarts an upload: the bar doesn't go back.
    progress.update(["a": 0.1, "b": 0.25])
    #expect(progress.units == (completed: 750, total: 2_000))
    // "a" finished and left; "c" joined.
    progress.update(["b": 0.5, "c": 2])
    #expect(progress.units == (completed: 2_500, total: 3_000))
    #expect(PendingSendsProgress().units == (completed: 0, total: 1_000))
  }
}

private struct GatedMediaSend: Transaction {
  var id: String
  var date = Date()
  var config = TransactionConfig(maxRetries: 0, retryDelay: 0, executionTimeout: 0)
  var fails = false
  var hasMedia = true

  func execute() async throws {
    try await MediaSendGate.shared.wait(id)
    if fails { throw URLError(.badServerResponse) }
  }

  func optimistic() {}
  func didSucceed(result _: Void) async {}
  func shouldRetryOnFail(error _: Error) -> Bool { false }
  func didFail(error _: Error?) async {}
  func rollback() async {}

  var pendingMediaSend: PendingMediaSend? {
    hasMedia ? PendingMediaSend(transactionId: id, chatId: 1, temporaryMessageId: -1, media: []) : nil
  }
}

private actor MediaSendGate {
  static let shared = MediaSendGate()
  private var released: Set<String> = []

  func release(_ id: String) { released.insert(id) }

  /// Polls so a cancelled send stops waiting.
  func wait(_ id: String) async throws {
    while !released.contains(id) {
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
  for _ in 0 ..< 1_000 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("condition not met")
}
