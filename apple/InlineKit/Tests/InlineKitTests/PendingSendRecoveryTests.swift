import Foundation
import Testing
@testable import InlineKit

@Suite("Pending send recovery")
struct PendingSendRecoveryTests {
  private func outgoing(
    id: Int64,
    age: TimeInterval,
    randomId: Int64? = 42,
    transactionId: String? = "tx",
    now: Date
  ) -> InlineKit.Message {
    InlineKit.Message(
      messageId: id,
      randomId: randomId,
      fromId: 1,
      date: now.addingTimeInterval(-age),
      text: nil,
      peerUserId: 2,
      peerThreadId: nil,
      chatId: 10,
      out: true,
      status: .sending,
      transactionId: transactionId
    )
  }

  @Test("recent interrupted sends resume in send order; stale or unidentifiable ones fail")
  @MainActor
  func plansResumeAndFailure() {
    let now = Date()
    let plan = PendingSendRecovery.plan(
      for: [
        outgoing(id: -3, age: 60, now: now),
        outgoing(id: -1, age: 600, now: now),
        outgoing(id: -2, age: 2 * 24 * 3600, now: now),
        outgoing(id: -4, age: 30, randomId: nil, now: now),
        outgoing(id: -5, age: 30, transactionId: "", now: now),
      ],
      now: now
    )
    #expect(plan.resume == [-1, -3])
    #expect(plan.fail == [-2, -4, -5])
  }

  @Test("recovered send reuses the interrupted row's identity")
  @MainActor
  func recoveredTransactionKeepsIdentity() throws {
    let now = Date()
    let message = outgoing(id: -77, age: 10, randomId: 77, transactionId: "original-tx", now: now)
    let transaction = try #require(TransactionSendMessage(recovering: message, mediaItems: []))
    #expect(transaction.id == "original-tx")
    #expect(transaction.randomId == 77)
    #expect(transaction.temporaryMessageId == -77)
    #expect(transaction.date == message.date)
    #expect(transaction.chatId == 10)

    let photoWithoutRow = outgoing(id: -78, age: 10, now: now)
    var missingPhoto = photoWithoutRow
    missingPhoto.photoId = 9
    #expect(PendingSendRecovery.recoverableMedia(for: FullMessage(senderInfo: nil, message: missingPhoto, reactions: [], repliedToMessage: nil, attachments: [])) == nil)
    #expect(PendingSendRecovery.recoverableMedia(for: FullMessage(senderInfo: nil, message: photoWithoutRow, reactions: [], repliedToMessage: nil, attachments: []))?.isEmpty == true)

    var sent = message
    sent.messageId = 5
    #expect(TransactionSendMessage(recovering: sent, mediaItems: []) == nil)
  }
}

@Suite("Native upload staging prune")
struct NativeUploadStagingPruneTests {
  @Test("removes abandoned copies and expired uploads, keeps live files and cancellations")
  func prunesStaleFiles() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("staging-prune-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    func make(_ name: String, age: TimeInterval) throws {
      let url = root.appendingPathComponent(name)
      try Data("x".utf8).write(to: url)
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-age)],
        ofItemAtPath: url.path
      )
    }
    try make("staging-old", age: 2 * 3600)
    try make("staging-fresh", age: 60)
    try make("expired.body", age: 8 * 24 * 3600)
    try make("expired.identity", age: 8 * 24 * 3600)
    try make("live.body", age: 2 * 24 * 3600)
    try make("cancel-old.json", age: 30 * 24 * 3600)
    // A copy in progress keeps the source's old date; its name carries the real start time.
    try make("staging-\(Int64(now.timeIntervalSince1970))-copying", age: 30 * 24 * 3600)

    let store = FileNativeUploadStagingStore(root: root)
    let removed = await store.pruneStale(now: now)

    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    #expect(removed == 3)
    #expect(remaining == [
      "staging-fresh", "live.body", "cancel-old.json", "staging-\(Int64(now.timeIntervalSince1970))-copying",
    ])
  }
}

@Suite("Outgoing send order")
struct OutgoingSendOrderTests {
  private actor Log {
    var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
  }

  @Test("later sends in a chat wait for earlier ones; other chats do not")
  func ordersPerLane() async throws {
    let order = OutgoingSendOrder()
    order.register(transactionId: "a", lane: "chat:1")
    order.register(transactionId: "b", lane: "chat:1")
    order.register(transactionId: "c", lane: "chat:1")
    order.register(transactionId: "x", lane: "chat:2")
    let log = Log()

    let c = Task { await order.waitForTurn(transactionId: "c"); await log.append("c") }
    let b = Task { await order.waitForTurn(transactionId: "b"); await log.append("b") }
    await order.waitForTurn(transactionId: "x")
    await order.waitForTurn(transactionId: "a")
    await log.append("a")
    try await Task.sleep(for: .milliseconds(20))
    #expect(await log.entries == ["a"])

    order.finish(transactionId: "a")
    await b.value
    #expect(await log.entries == ["a", "b"])
    order.finish(transactionId: "b")
    await c.value
    #expect(await log.entries == ["a", "b", "c"])
    order.finish(transactionId: "c")
    order.finish(transactionId: "x")
    #expect(!order.isRegistered(transactionId: "c"))
  }

  @Test("a failed middle send unblocks later sends once the head settles; cancellation never hangs")
  func failedAndCancelled() async {
    let order = OutgoingSendOrder()
    for id in ["a", "b", "c"] { order.register(transactionId: id, lane: "chat:1") }
    let c = Task { await order.waitForTurn(transactionId: "c") }
    order.finish(transactionId: "b")
    order.finish(transactionId: "a")
    await c.value

    order.register(transactionId: "d", lane: "chat:3")
    order.register(transactionId: "e", lane: "chat:3")
    let e = Task { await order.waitForTurn(transactionId: "e") }
    e.cancel()
    await e.value
    await order.waitForTurn(transactionId: "unregistered")
  }
}

@Suite("Native upload staging age")
struct NativeUploadStagingAgeTests {
  @Test("a freshly staged copy of an old file is not pruned")
  func stagedCopyUsesStagingTime() async throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("staging-age-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("NativeUploads", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    let source = base.appendingPathComponent("old-photo.jpg")
    try Data("photo".utf8).write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)],
      ofItemAtPath: source.path
    )

    let store = FileNativeUploadStagingStore(root: root)
    let staged = try await store.stage(logicalID: "1:photo_1", sourceURL: source)
    #expect(await store.pruneStale(now: Date()) == 0)
    #expect(FileManager.default.fileExists(atPath: staged.path))
  }
}
