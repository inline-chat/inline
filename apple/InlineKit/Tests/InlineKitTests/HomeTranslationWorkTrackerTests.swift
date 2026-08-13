import Foundation
@testable import InlineKit
import Testing

@Suite("Home translation work tracking")
struct HomeTranslationWorkTrackerTests {
  @Test("Cancellation returns the same signature to the next pass")
  func cancellationDoesNotPoisonSignature() {
    var tracker = HomeTranslationWorkTracker()
    let item = snapshot(1)
    let first = reserve(&tracker, item: item, generation: 1)

    tracker.finish(first, outcome: .cancelled)
    let retry = reserve(&tracker, item: item, generation: 2)

    #expect(first.count == 1)
    #expect(retry.first?.signature == first.first?.signature)
    #expect(retry.first?.attempt == 1)
  }

  @Test("A replacement pass can claim work before the cancelled pass finishes")
  func replacementPassRejectsLateCompletion() {
    var tracker = HomeTranslationWorkTracker()
    let item = snapshot(1)
    let first = reserve(&tracker, item: item, generation: 1)

    tracker.beginGeneration(2)
    let replacement = reserve(&tracker, item: item, generation: 2)
    tracker.finish(first, outcome: .failed, now: Date(timeIntervalSince1970: 1_000))

    #expect(replacement.count == 1)
    tracker.finish(replacement, outcome: .cancelled)
    #expect(reserve(&tracker, item: item, generation: 3).count == 1)
  }

  @Test("Read and dispatch failures remain retryable with capped backoff")
  func failuresNeverPermanentlyPoisonSignature() {
    let start = Date(timeIntervalSince1970: 1_000)
    var tracker = HomeTranslationWorkTracker(baseRetryDelay: 2, maximumRetryDelay: 4)
    let item = snapshot(1)

    for attempt in 1 ... 8 {
      let now = start.addingTimeInterval(Double(max(0, attempt - 1) * 4))
      let candidates = tracker.reserve(
        snapshots: [item],
        prioritizedPeers: [],
        enabledPeers: [item.peer],
        excluding: [],
        generation: UInt64(attempt),
        limit: 1,
        now: now
      )
      #expect(candidates.first?.attempt == attempt)
      tracker.finish(candidates, outcome: .failed, now: now)
    }

    let ninth = tracker.reserve(
      snapshots: [item],
      prioritizedPeers: [],
      enabledPeers: [item.peer],
      excluding: [],
      generation: 9,
      limit: 1,
      now: start.addingTimeInterval(32)
    )
    #expect(ninth.first?.attempt == 9)
  }

  @Test("A completed processing result suppresses the exact signature")
  func processingAcknowledgesCompletion() {
    let start = Date(timeIntervalSince1970: 2_000)
    var tracker = HomeTranslationWorkTracker(baseRetryDelay: 2)
    let item = snapshot(1)
    let first = reserve(&tracker, item: item, generation: 1, now: start)
    tracker.finish(first, outcome: .completed, now: start)

    #expect(reserve(
      &tracker,
      item: item,
      generation: 2,
      now: start.addingTimeInterval(1)
    ).isEmpty)
    let changed = ChatListItemSnapshot(
      peer: .thread(id: 1),
      chatID: 1,
      title: "Chat 1",
      contentSignature: ChatListContentSignature(messageID: 10, messageRevision: 2)
    )
    #expect(reserve(
      &tracker,
      item: changed,
      generation: 3,
      now: start.addingTimeInterval(2)
    ).count == 1)
  }

  @Test("Draft previews and current chats are never scheduled")
  func exclusions() {
    var tracker = HomeTranslationWorkTracker()
    let draft = snapshot(1, draftRevision: 9)
    let current = snapshot(2)
    let candidates = tracker.reserve(
      snapshots: [draft, current],
      prioritizedPeers: [],
      enabledPeers: [draft.peer, current.peer],
      excluding: [current.peer],
      generation: 1,
      limit: 10
    )

    #expect(candidates.isEmpty)
  }

  @Test("A completed bounded page exposes the next eligible page")
  func boundedPagesDrain() {
    var tracker = HomeTranslationWorkTracker()
    let firstItem = snapshot(1)
    let secondItem = snapshot(2)
    let firstPage = tracker.reserve(
      snapshots: [firstItem, secondItem],
      prioritizedPeers: [],
      enabledPeers: [firstItem.peer, secondItem.peer],
      excluding: [],
      generation: 1,
      limit: 1
    )
    tracker.finish(firstPage, outcome: .completed)

    let secondPage = tracker.reserve(
      snapshots: [firstItem, secondItem],
      prioritizedPeers: [],
      enabledPeers: [firstItem.peer, secondItem.peer],
      excluding: [],
      generation: 2,
      limit: 1
    )

    #expect(firstPage.map(\.peer) == [firstItem.peer])
    #expect(secondPage.map(\.peer) == [secondItem.peer])
  }

  private func reserve(
    _ tracker: inout HomeTranslationWorkTracker,
    item: ChatListItemSnapshot,
    generation: UInt64,
    now: Date = Date(timeIntervalSince1970: 0)
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
