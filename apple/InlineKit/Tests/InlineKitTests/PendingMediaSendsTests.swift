import Foundation
import GRDB
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

  @Test func sendsRunInTheirOwnLaneSoOtherWorkCannotHoldThemBack() async throws {
    let actor = TransactionsActor(waitForConnection: {}, pendingMediaSends: PendingMediaSends())
    let run = UUID().uuidString
    let general = (0 ..< 4).map { "\(run)-general-\($0)" }
    let waiting = "\(run)-general-waits"
    let sends = (0 ..< 6).map { "\(run)-send-\($0)" }
    for id in general + [waiting] { await actor.queue(transaction: GatedMediaSend(id: id, hasMedia: false)) }
    // Sends queued behind a full general lane start at once.
    for id in sends { await actor.queue(transaction: GatedMediaSend(id: id, inSendLane: true)) }
    try await waitUntil { await MediaSendGate.shared.startedAll(general + sends) }
    #expect(await !MediaSendGate.shared.startedAll([waiting]))
    for id in general + sends { await MediaSendGate.shared.release(id) }
    try await waitUntil { await MediaSendGate.shared.startedAll([waiting]) }
    await MediaSendGate.shared.release(waiting)
  }

  @Test func expiryDeletesMovingSendsWithTheRestOfTheirAlbumAndLeavesWaitingOnes() {
    let now = ContinuousClock.now
    func send(_ id: String, album: Int64? = nil) -> PendingMediaSend {
      PendingMediaSend(transactionId: id, chatId: 1, peerId: .thread(id: 1), temporaryMessageId: -1, media: [], groupedId: album)
    }
    let current = [
      send("moving"), send("waiting"), send("stalled"), send("uploaded"),
      send("albumMoving", album: 7), send("albumUploaded", album: 7), send("albumWaiting", album: 7),
      send("otherAlbum", album: 8), send("notInTask"),
      // Album 9 was released early (another item's upload failed): an uploaded item is on its way.
      send("releasedMoving", album: 9), send("releasedSending", album: 9),
    ]
    let fractions: [String: Double] = [
      "moving": 0.5, "waiting": 0, "stalled": 0.4, "uploaded": 1,
      "albumMoving": 0.3, "albumUploaded": 1, "albumWaiting": 0, "otherAlbum": 0, "notInTask": 0.5,
      "releasedMoving": 0.6, "releasedSending": 1,
    ]
    let lastMoved: [String: ContinuousClock.Instant] = [
      "moving": now - .seconds(2), "stalled": now - .seconds(60), "albumMoving": now - .seconds(1), "notInTask": now,
      "releasedMoving": now - .seconds(1),
    ]
    let held: Set<String> = ["albumMoving", "albumUploaded", "albumWaiting"]
    let deleted = PendingMediaSends.expiredSendsToDelete(
      current: current,
      taskSendIDs: Set(current.map(\.transactionId)).subtracting(["notInTask"]),
      fractions: fractions, lastMoved: lastMoved, now: now, movingWindow: .seconds(15),
      isHeldForAlbum: held.contains
    )
    #expect(Set(deleted.map(\.transactionId)) == ["moving", "albumMoving", "albumUploaded", "albumWaiting", "releasedMoving"])
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
    let send = PendingMediaSend(transactionId: "tx", chatId: 1, peerId: .thread(id: 1), temporaryMessageId: -1, media: [])
    sends.insert(send)
    sends.insert(send)
    sends.remove(transactionId: "tx")
    #expect(sends.current.map(\.transactionId) == ["tx"])
    sends.remove(transactionId: "tx")
    #expect(sends.current.isEmpty)
  }

  @Test @MainActor func deletingUnsentSendsRemovesOnlyRowsStillSending() throws {
    let database = try AppDatabase(DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123")))
    try database.dbWriter.write { db in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 1, date: Date(), type: .thread, title: "Test", spaceId: nil).insert(db)
      for (id, status) in [(Int64(-10), MessageSendingStatus.sending), (-11, .sent)] {
        try Message(
          messageId: id, fromId: 1, date: Date(), text: nil, peerUserId: nil,
          peerThreadId: 1, chatId: 1, out: true, status: status
        ).save(db)
      }
    }
    let sends = [-10, -11].map {
      PendingMediaSend(transactionId: "tx\($0)", chatId: 1, peerId: .thread(id: 1), temporaryMessageId: Int64($0), media: [])
    }
    PendingMediaSends.deleteUnsent(sends, database: database)
    let left = try database.dbWriter.read { db in try Int64.fetchAll(db, sql: "SELECT messageId FROM \(Message.databaseTableName) ORDER BY messageId") }
    #expect(left == [-11])
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
  var inSendLane = false

  var runsInSendLane: Bool { inSendLane }

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
    hasMedia ? PendingMediaSend(transactionId: id, chatId: 1, peerId: .thread(id: 1), temporaryMessageId: -1, media: []) : nil
  }
}

private actor MediaSendGate {
  static let shared = MediaSendGate()
  private var released: Set<String> = []
  private var started: Set<String> = []

  func release(_ id: String) { released.insert(id) }
  func startedAll(_ ids: [String]) -> Bool { started.isSuperset(of: ids) }

  /// Polls so a cancelled send stops waiting.
  func wait(_ id: String) async throws {
    started.insert(id)
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
