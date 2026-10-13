@testable import InlineKit
import Testing

@Suite("Dialog mutation rollback tracking")
struct DialogMutationRollbackTrackerTests {
  private let peer = Peer.user(id: 101)
  private let openFields: [DialogRollbackField] = [.open, .order, .archived]

  private func closedDialog() -> Dialog {
    Dialog(optimisticForUserId: 101)
  }

  private func opened(_ dialog: Dialog, order: String = "a") -> Dialog {
    var dialog = dialog
    dialog.open = true
    dialog.order = order
    return dialog
  }

  private func snapshot(from baseline: Dialog, to optimistic: Dialog, createdRow: Bool = false) -> DialogMutationSnapshot {
    DialogMutationSnapshot(baseline: baseline, optimistic: optimistic, createdRow: createdRow)
  }

  @Test("Independent mutation kinds do not replace each other")
  func mutationKindsAreIndependent() async {
    let tracker = DialogMutationRollbackTracker()
    let closed = closedDialog()
    var unread = closed
    unread.unreadMark = true

    await tracker.record(
      intentID: "open", peer: peer, kind: .open,
      snapshot: snapshot(from: closed, to: opened(closed)), fields: openFields
    )
    await tracker.record(
      intentID: "read", peer: peer, kind: .read,
      snapshot: snapshot(from: closed, to: unread), fields: [.unreadMark]
    )

    let openEntry = await tracker.takeForRollback(intentID: "open", peer: peer, kind: .open)
    let readEntry = await tracker.takeForRollback(intentID: "read", peer: peer, kind: .read)
    #expect(openEntry?.fields == openFields)
    #expect(readEntry?.fields == [.unreadMark])
  }

  @Test("A failed intent leaves fields a later intent owns and hands over its baseline")
  func laterIntentTakesOverSharedFields() async throws {
    let tracker = DialogMutationRollbackTracker()
    let closed = closedDialog()
    let open = opened(closed)

    await tracker.record(
      intentID: "older", peer: peer, kind: .open,
      snapshot: snapshot(from: closed, to: open), fields: openFields
    )
    await tracker.record(
      intentID: "newer", peer: peer, kind: .open,
      snapshot: snapshot(from: open, to: open), fields: openFields
    )

    let older = try #require(await tracker.takeForRollback(intentID: "older", peer: peer, kind: .open))
    #expect(older.fields.isEmpty)
    #expect(older.resolve(current: open) == .unchanged)

    // Both failed, so the newer intent restores the state before either ran.
    let newer = try #require(await tracker.takeForRollback(intentID: "newer", peer: peer, kind: .open))
    #expect(newer.resolve(current: open) == .save(closed))
  }

  @Test("A completed intent no longer participates in rollback")
  func completedIntentIsDropped() async {
    let tracker = DialogMutationRollbackTracker()
    let closed = closedDialog()

    await tracker.record(
      intentID: "open", peer: peer, kind: .open,
      snapshot: snapshot(from: closed, to: opened(closed)), fields: openFields
    )
    await tracker.complete(intentID: "open", peer: peer, kind: .open)

    #expect(await tracker.takeForRollback(intentID: "open", peer: peer, kind: .open) == nil)
  }

  @Test("Rollback keeps fields written since the optimistic change")
  func rollbackIsFieldWise() {
    let closed = closedDialog()
    let open = opened(closed)
    let entry = DialogMutationRollbackEntry(
      baseline: closed, optimistic: open, fields: openFields, deletesUntouchedRow: false
    )

    var movedByServer = open
    movedByServer.order = "m"
    movedByServer.unreadCount = 3

    var expected = movedByServer
    expected.open = false
    #expect(entry.resolve(current: movedByServer) == .save(expected))
  }

  @Test("An inserted row is deleted only while nothing else has written it")
  func insertedRowDeletion() {
    let closed = closedDialog()
    let open = opened(closed)
    let entry = DialogMutationRollbackEntry(
      baseline: closed, optimistic: open, fields: openFields, deletesUntouchedRow: true
    )

    #expect(entry.resolve(current: open) == .delete)

    var writtenByServer = open
    writtenByServer.unreadCount = 1
    var expected = writtenByServer
    expected.open = false
    expected.order = nil
    #expect(entry.resolve(current: writtenByServer) == .save(expected))
  }

  @Test("A later intent inherits removal of an untouched inserted row")
  func insertedRowInheritance() async throws {
    let tracker = DialogMutationRollbackTracker()
    let closed = closedDialog()
    let open = opened(closed)
    var unread = open
    unread.unreadMark = true

    await tracker.record(
      intentID: "open", peer: peer, kind: .open,
      snapshot: snapshot(from: closed, to: open, createdRow: true), fields: openFields
    )
    await tracker.record(
      intentID: "read", peer: peer, kind: .read,
      snapshot: snapshot(from: open, to: unread), fields: [.unreadMark]
    )

    let failedOpen = try #require(await tracker.takeForRollback(intentID: "open", peer: peer, kind: .open))
    #expect(failedOpen.deletesUntouchedRow == false)
    var closedUnread = unread
    closedUnread.open = false
    closedUnread.order = nil
    #expect(failedOpen.resolve(current: unread) == .save(closedUnread))

    let failedRead = try #require(await tracker.takeForRollback(intentID: "read", peer: peer, kind: .read))
    #expect(failedRead.deletesUntouchedRow)
  }
}
