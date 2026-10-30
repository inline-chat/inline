@testable import ChatListCore
import Testing

struct TimelinePreparationQueueTests {
  private enum Context: Equatable {
    case width(Int)
  }

  private struct Snapshot {
    var label: String
  }

  @Test func `continuous same context requests finish active before newest pending`() {
    var queue = TimelinePreparationQueue<Context, Snapshot>()
    let first = TimelinePreparationQueue<Context, Snapshot>.Request(
      revision: 1,
      context: .width(600),
      snapshot: .init(label: "first")
    )
    let second = TimelinePreparationQueue<Context, Snapshot>.Request(
      revision: 2,
      context: .width(600),
      snapshot: .init(label: "intermediate")
    )
    let newest = TimelinePreparationQueue<Context, Snapshot>.Request(
      revision: 3,
      context: .width(600),
      snapshot: .init(label: "newest")
    )

    if case let .start(request) = queue.submit(first) {
      #expect(request.revision == 1)
    } else {
      #expect(Bool(false))
    }
    if case .coalesced = queue.submit(second) {} else {
      #expect(Bool(false))
    }
    if case .coalesced = queue.submit(newest) {} else {
      #expect(Bool(false))
    }

    #expect(queue.active?.revision == 1)
    #expect(queue.active?.snapshot.label == "first")
    #expect(queue.pending?.revision == 3)
    #expect(queue.pending?.snapshot.label == "newest")

    if case let .accepted(next) = queue.finish(revision: 1) {
      #expect(next?.revision == 3)
      #expect(next?.snapshot.label == "newest")
    } else {
      #expect(Bool(false))
    }
    #expect(queue.active?.revision == 3)
    #expect(queue.pending == nil)

    if case let .accepted(next) = queue.finish(revision: 3) {
      #expect(next == nil)
    } else {
      #expect(Bool(false))
    }
    #expect(queue.active == nil)
  }

  @Test func `context replacement rejects old active and discards pending`() {
    var queue = TimelinePreparationQueue<Context, Snapshot>()
    _ = queue.submit(.init(revision: 10, context: .width(600), snapshot: .init(label: "old")))
    _ = queue.submit(.init(revision: 11, context: .width(600), snapshot: .init(label: "old pending")))

    let replacement = TimelinePreparationQueue<Context, Snapshot>.Request(
      revision: 12,
      context: .width(400),
      snapshot: .init(label: "new width")
    )
    if case let .start(request) = queue.submit(replacement) {
      #expect(request.revision == 12)
    } else {
      #expect(Bool(false))
    }

    #expect(queue.active?.revision == 12)
    #expect(queue.pending == nil)
    if case .rejected = queue.finish(revision: 10) {} else {
      #expect(Bool(false))
    }
    if case .rejected = queue.finish(revision: 11) {} else {
      #expect(Bool(false))
    }
    #expect(queue.active?.revision == 12)

    if case let .accepted(next) = queue.finish(revision: 12) {
      #expect(next == nil)
    } else {
      #expect(Bool(false))
    }
  }

  @Test func `cancel clears queue and fresh revision fences late completion`() {
    var queue = TimelinePreparationQueue<Context, Snapshot>()
    _ = queue.submit(.init(revision: 20, context: .width(600), snapshot: .init(label: "active")))
    _ = queue.submit(.init(revision: 21, context: .width(600), snapshot: .init(label: "pending")))
    queue.cancel()

    #expect(queue.active == nil)
    #expect(queue.pending == nil)
    if case .rejected = queue.finish(revision: 20) {} else {
      #expect(Bool(false))
    }

    if case .start = queue.submit(.init(revision: 22, context: .width(600), snapshot: .init(label: "reused"))) {
    } else {
      #expect(Bool(false))
    }
    if case .rejected = queue.finish(revision: 20) {} else {
      #expect(Bool(false))
    }
    #expect(queue.active?.revision == 22)
    if case .rejected = queue.finish(revision: 21) {} else {
      #expect(Bool(false))
    }
    #expect(queue.active?.revision == 22)
  }

  @Test func `wrong completion revision leaves active and pending unchanged`() {
    var queue = TimelinePreparationQueue<Context, Snapshot>()
    _ = queue.submit(.init(revision: 30, context: .width(600), snapshot: .init(label: "active")))
    _ = queue.submit(.init(revision: 31, context: .width(600), snapshot: .init(label: "pending")))

    if case .rejected = queue.finish(revision: 29) {} else {
      #expect(Bool(false))
    }
    #expect(queue.active?.revision == 30)
    #expect(queue.pending?.revision == 31)
  }

  @Test func `slow preparation keeps installing during an uninterrupted producer`() {
    var queue = TimelinePreparationQueue<Context, Snapshot>()
    var installed: [UInt64] = []
    // Seven publications arrive during each preparation. Finishing never waits
    // for a producer gap and each next job uses the newest coalesced snapshot.
    for revision in UInt64(1) ... 70 {
      _ = queue.submit(.init(
        revision: revision, context: .width(600), snapshot: .init(label: "revision \(revision)")
      ))
      if revision.isMultiple(of: 7), let active = queue.active {
        if case .accepted = queue.finish(revision: active.revision) {
          installed.append(active.revision)
        } else {
          #expect(Bool(false))
        }
      }
    }
    #expect(installed == [1, 7, 14, 21, 28, 35, 42, 49, 56, 63])
    #expect(queue.active?.revision == 70)
    #expect(queue.pending == nil)
    if case let .accepted(next) = queue.finish(revision: 70) {
      #expect(next == nil)
    } else {
      #expect(Bool(false))
    }
  }
}
