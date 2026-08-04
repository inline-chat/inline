@testable import InlineKit
import Testing

@Suite("Dialog mutation rollback tracking")
struct DialogMutationRollbackTrackerTests {
  @Test("Independent mutation kinds do not replace each other")
  func mutationKindsAreIndependent() async {
    let tracker = DialogMutationRollbackTracker()
    let peer = Peer.thread(id: 101)

    await tracker.record(intentID: "open", peer: peer, kind: .open, original: nil)
    await tracker.record(intentID: "read", peer: peer, kind: .read, original: nil)

    let openEntry = await tracker.takeForRollback(intentID: "open", peer: peer, kind: .open)
    let readEntry = await tracker.takeForRollback(intentID: "read", peer: peer, kind: .read)
    #expect(openEntry != nil)
    #expect(readEntry != nil)
  }

  @Test("Only the latest intent can roll back a mutation kind")
  func latestIntentWins() async {
    let tracker = DialogMutationRollbackTracker()
    let peer = Peer.thread(id: 102)

    await tracker.record(intentID: "older", peer: peer, kind: .open, original: nil)
    await tracker.record(intentID: "newer", peer: peer, kind: .open, original: nil)

    let staleEntry = await tracker.takeForRollback(intentID: "older", peer: peer, kind: .open)
    let currentEntry = await tracker.takeForRollback(intentID: "newer", peer: peer, kind: .open)
    #expect(staleEntry == nil)
    #expect(currentEntry != nil)
  }
}
