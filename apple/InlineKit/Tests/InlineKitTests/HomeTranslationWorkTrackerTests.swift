import Foundation
@testable import InlineKit
import Testing

@Suite("Home translation work tracking")
struct HomeTranslationWorkTrackerTests {
  @Test("Visible peers are reserved before bounded background work")
  func visibleFirst() {
    var tracker = HomeTranslationWorkTracker()
    let snapshots = [snapshot(1), snapshot(2), snapshot(3)]

    let candidates = tracker.reserve(
      snapshots: snapshots,
      prioritizedPeers: [.thread(id: 3)],
      enabledPeers: Set(snapshots.map(\.peer)),
      excluding: [],
      generation: 1,
      limit: 2
    )

    #expect(candidates.map(\.peer) == [.thread(id: 3), .thread(id: 1)])
  }

  @Test("Cancellation returns the same signature to the next generation")
  func cancellationDoesNotPoisonSignature() {
    var tracker = HomeTranslationWorkTracker()
    let item = snapshot(1)
    let first = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 1,
      limit: 1
    )

    tracker.finish(first, outcome: .cancelled)
    let retry = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 2,
      limit: 1
    )

    #expect(first.count == 1)
    #expect(retry.count == 1)
    #expect(retry.first?.signature == first.first?.signature)
    #expect(retry.first?.attempt == 1)
  }

  @Test("A replacement generation releases stale in-flight reservations")
  func replacementGeneration() {
    var tracker = HomeTranslationWorkTracker()
    let item = snapshot(1)
    let first = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 1,
      limit: 1
    )

    tracker.beginGeneration(2)
    let replacement = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 2,
      limit: 1
    )

    #expect(first.count == 1)
    #expect(replacement.count == 1)
    #expect(replacement.first?.generation == 2)
  }

  @Test("Dispatch waits for persistence and retries with backoff")
  func persistenceAcknowledgement() {
    let start = Date(timeIntervalSince1970: 1_000)
    var tracker = HomeTranslationWorkTracker(
      maximumAttempts: 3,
      baseRetryDelay: 2,
      maximumRetryDelay: 30
    )
    let item = snapshot(1)
    let first = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 1,
      limit: 1,
      now: start
    )
    tracker.finish(first, outcome: .dispatched, now: start)

    let tooEarly = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 2,
      limit: 1,
      now: start.addingTimeInterval(1)
    )
    let retry = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 3,
      limit: 1,
      now: start.addingTimeInterval(2)
    )

    #expect(tooEarly.isEmpty)
    #expect(retry.first?.attempt == 2)

    let translated = snapshot(1, translatedPreviewText: "Hello")
    let afterPersistence = tracker.reserve(
      snapshots: [translated],
      prioritizedPeers: [],
      enabledPeers: [translated.peer],
      excluding: [],
      generation: 4,
      limit: 1,
      now: start.addingTimeInterval(10)
    )
    #expect(afterPersistence.isEmpty)
  }

  @Test("Draft previews and current chats are never scheduled")
  func exclusions() {
    var tracker = HomeTranslationWorkTracker()
    let draft = snapshot(1, draftRevision: 9)
    let current = snapshot(2)
    let candidates = tracker.reserve(
      snapshots: [draft, current],
      prioritizedPeers: [draft.peer, current.peer],
      enabledPeers: [draft.peer, current.peer],
      excluding: [current.peer],
      generation: 1,
      limit: 10
    )

    #expect(candidates.isEmpty)
  }

  @Test("Repeated failures stop at the configured attempt bound")
  func boundedFailureRetries() {
    let start = Date(timeIntervalSince1970: 2_000)
    var tracker = HomeTranslationWorkTracker(maximumAttempts: 3, baseRetryDelay: 2)
    let item = snapshot(1)

    let first = reserve(&tracker, item: item, generation: 1, now: start)
    tracker.finish(first, outcome: .failed, now: start)
    let second = reserve(
      &tracker,
      item: item,
      generation: 2,
      now: start.addingTimeInterval(2)
    )
    tracker.finish(second, outcome: .failed, now: start.addingTimeInterval(2))
    let third = reserve(
      &tracker,
      item: item,
      generation: 3,
      now: start.addingTimeInterval(6)
    )
    tracker.finish(third, outcome: .failed, now: start.addingTimeInterval(6))
    let exhausted = reserve(
      &tracker,
      item: item,
      generation: 4,
      now: start.addingTimeInterval(100)
    )

    #expect(first.first?.attempt == 1)
    #expect(second.first?.attempt == 2)
    #expect(third.first?.attempt == 3)
    #expect(exhausted.isEmpty)
  }

  private func reserve(
    _ tracker: inout HomeTranslationWorkTracker,
    item: ChatListItemSnapshot,
    generation: UInt64,
    now: Date
  ) -> [HomeTranslationCandidate] {
    tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: generation,
      limit: 1,
      now: now
    )
  }

  private func snapshot(
    _ id: Int64,
    translatedPreviewText: String? = nil,
    draftRevision: Int64? = nil
  ) -> ChatListItemSnapshot {
    ChatListItemSnapshot(
      peer: .thread(id: id),
      chatID: id,
      title: "Chat \(id)",
      translatedPreviewText: translatedPreviewText,
      contentSignature: ChatListContentSignature(
        messageID: id * 10,
        messageRevision: 1,
        draftRevision: draftRevision
      )
    )
  }
}
