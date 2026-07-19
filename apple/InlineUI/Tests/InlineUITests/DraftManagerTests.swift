import Foundation
import InlineKit
import InlineProtocol
import Testing
@testable import TextProcessing

@Suite("DraftManager")
@MainActor
struct DraftManagerTests {
  @Test("plain text drafts do not persist empty entities")
  func plainTextDraftsDoNotPersistEmptyEntities() {
    let manager = DraftManager(debounceDelay: 0)
    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello")
    #expect(entities == nil)
  }

  @Test("empty drafts clear stored draft")
  func emptyDraftsClearStoredDraft() {
    let manager = DraftManager(debounceDelay: 0)
    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "  \n")
    )

    guard case .clear = payload else {
      Issue.record("Expected draft clear")
      return
    }
  }

  @Test("current attributed entities are saved")
  func currentAttributedEntitiesAreSaved() {
    let manager = DraftManager(debounceDelay: 0)
    let text = "hello mo"
    let attributedString = NSMutableAttributedString(string: text)
    attributedString.addAttribute(
      .mentionUserId,
      value: Int64(42),
      range: NSRange(location: 6, length: 2)
    )

    let payload = manager.makePayload(peerId: .user(id: 1), attributedString: attributedString)

    guard case let .update(_, _, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(entities?.entities.count == 1)
    #expect(entities?.entities.first?.offset == 6)
    #expect(entities?.entities.first?.length == 2)
  }

  @Test("loaded entities are preserved until edited")
  func loadedEntitiesArePreservedUntilEdited() {
    let manager = DraftManager(debounceDelay: 0)
    manager.markLoaded(text: "hello mo", entities: mentionEntities(offset: 6, length: 2))

    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello mo!")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello mo!")
    #expect(entities?.entities.count == 1)
  }

  @Test("overlapping loaded entity edits drop stale entities")
  func overlappingLoadedEntityEditsDropStaleEntities() {
    let manager = DraftManager(debounceDelay: 0)
    manager.markLoaded(text: "hello mo", entities: mentionEntities(offset: 6, length: 2))
    manager.invalidateLoadedEntities(overlapping: NSRange(location: 6, length: 2))

    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello xx")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello xx")
    #expect(entities == nil)
  }

  @Test("zero length edits inside loaded entity drop stale entities")
  func zeroLengthEditsInsideLoadedEntityDropStaleEntities() {
    let manager = DraftManager(debounceDelay: 0)
    manager.markLoaded(text: "hello mo", entities: mentionEntities(offset: 6, length: 2))
    manager.invalidateLoadedEntities(overlapping: NSRange(location: 7, length: 0))

    let payload = manager.makePayload(
      peerId: .user(id: 1),
      attributedString: NSAttributedString(string: "hello m!o")
    )

    guard case let .update(_, text, entities, _) = payload else {
      Issue.record("Expected draft update")
      return
    }

    #expect(text == "hello m!o")
    #expect(entities == nil)
  }

  @Test("clear cancels an immediate snapshot save")
  func clearCancelsImmediateSnapshotSave() async {
    let recorder = DraftPersistenceRecorder()
    let manager = DraftManager(
      debounceDelay: 0,
      persistence: recorder.client
    )
    let peer: InlineKit.Peer = .thread(id: 1001)
    let oldDraft = NSAttributedString(string: "old draft")

    manager.scheduleSave(peerId: peer, attributedString: oldDraft)
    manager.cancelPendingSave()
    manager.save(peerId: peer, attributedString: oldDraft)
    manager.clear(peerId: peer)

    await manager.waitForPendingPersistence()

    #expect(await recorder.updateCount == 0)
    #expect(await recorder.clearCount == 1)
  }

  @Test("retained composer cannot save content older than a clear")
  func retainedComposerCannotSaveContentOlderThanClear() async {
    let recorder = DraftPersistenceRecorder()
    let staleManager = DraftManager(
      debounceDelay: 60,
      persistence: recorder.client
    )
    let activeManager = DraftManager(
      debounceDelay: 60,
      persistence: recorder.client
    )
    let peer: InlineKit.Peer = .thread(id: 1002)
    let oldDraft = NSAttributedString(string: "old draft")

    staleManager.scheduleSave(peerId: peer, attributedString: oldDraft)
    staleManager.cancelPendingSave()
    activeManager.clear(peerId: peer)
    staleManager.save(peerId: peer, attributedString: oldDraft)

    await activeManager.waitForPendingPersistence()
    await staleManager.waitForPendingPersistence()

    #expect(await recorder.updateCount == 0)
    #expect(await recorder.clearCount == 1)
  }

  @Test("new edit after clear persists normally")
  func newEditAfterClearPersistsNormally() async {
    let recorder = DraftPersistenceRecorder()
    let manager = DraftManager(
      debounceDelay: 0,
      persistence: recorder.client
    )
    let peer: InlineKit.Peer = .thread(id: 1003)
    let newDraft = NSAttributedString(string: "new draft")

    manager.clear(peerId: peer)
    manager.scheduleSave(peerId: peer, attributedString: newDraft)

    await manager.waitForPendingPersistence()

    #expect(await recorder.updateCount == 1)
    #expect(await recorder.lastUpdatedText == "new draft")
  }

  @Test("retyping the same draft after clear persists again")
  func retypingSameDraftAfterClearPersistsAgain() async {
    let recorder = DraftPersistenceRecorder()
    let manager = DraftManager(
      debounceDelay: 0,
      persistence: recorder.client
    )
    let peer: InlineKit.Peer = .thread(id: 1004)
    let draft = NSAttributedString(string: "same draft")
    manager.markLoaded(text: draft.string, entities: nil)

    manager.clear(peerId: peer)
    manager.scheduleSave(peerId: peer, attributedString: draft)

    await manager.waitForPendingPersistence()

    #expect(await recorder.updateCount == 1)
    #expect(await recorder.lastUpdatedText == draft.string)
  }

  @Test("clear survives manager release")
  func clearSurvivesManagerRelease() async {
    let recorder = DraftPersistenceRecorder(pauseFirstClear: true)
    let peer: InlineKit.Peer = .thread(id: 1005)
    var manager: DraftManager? = DraftManager(
      debounceDelay: 0,
      persistence: recorder.client
    )

    manager?.clear(peerId: peer)
    await recorder.waitUntilClearStarted()
    manager = nil
    await recorder.resumeFirstClear()
    await recorder.waitForCommittedOperationCount(1)

    #expect(await recorder.clearCount == 1)
  }

  @Test("newer snapshot finishes last when an older snapshot is suspended")
  func newerSnapshotFinishesLastWhenOlderSnapshotIsSuspended() async {
    let recorder = DraftPersistenceRecorder(pauseFirstUpdate: true)
    let manager = DraftManager(debounceDelay: 60, persistence: recorder.client)
    let peer: InlineKit.Peer = .thread(id: 1006)

    manager.scheduleSave(
      peerId: peer,
      attributedString: NSAttributedString(string: "first")
    )
    manager.cancelPendingSave()
    manager.save(
      peerId: peer,
      attributedString: NSAttributedString(string: "first")
    )
    await recorder.waitUntilUpdateStarted()

    manager.save(
      peerId: peer,
      attributedString: NSAttributedString(string: "second")
    )
    await recorder.resumeFirstUpdate()
    await manager.waitForPendingPersistence()

    #expect(await recorder.updatedTexts == ["first", "second"])
    #expect(await recorder.lastUpdatedText == "second")
  }

  @Test("unchanged lifecycle snapshots coalesce with an in-flight write")
  func unchangedLifecycleSnapshotsCoalesce() async {
    let recorder = DraftPersistenceRecorder(pauseFirstUpdate: true)
    let manager = DraftManager(debounceDelay: 60, persistence: recorder.client)
    let peer: InlineKit.Peer = .thread(id: 1007)
    let draft = NSAttributedString(string: "one write")

    manager.scheduleSave(peerId: peer, attributedString: draft)
    manager.cancelPendingSave()
    manager.save(peerId: peer, attributedString: draft)
    await recorder.waitUntilUpdateStarted()
    manager.save(peerId: peer, attributedString: draft)
    manager.save(peerId: peer, attributedString: draft)
    await recorder.resumeFirstUpdate()
    await manager.waitForPendingPersistence()

    #expect(await recorder.updatedTexts == ["one write"])
  }

  @Test("returning to the in-flight snapshot replaces a different pending snapshot")
  func returningToInFlightSnapshotWins() async {
    let recorder = DraftPersistenceRecorder(pauseFirstUpdate: true)
    let manager = DraftManager(debounceDelay: 60, persistence: recorder.client)
    let peer: InlineKit.Peer = .thread(id: 1008)
    let first = NSAttributedString(string: "first")

    manager.scheduleSave(peerId: peer, attributedString: first)
    manager.cancelPendingSave()
    manager.save(peerId: peer, attributedString: first)
    await recorder.waitUntilUpdateStarted()

    manager.save(
      peerId: peer,
      attributedString: NSAttributedString(string: "second")
    )
    manager.save(peerId: peer, attributedString: first)

    await recorder.resumeFirstUpdate()
    await manager.waitForPendingPersistence()

    #expect(await recorder.updatedTexts == ["first"])
    #expect(await recorder.lastUpdatedText == "first")
  }

  @Test("clear registered while an update is suspended rejects the update")
  func clearRejectsSuspendedUpdate() async {
    let recorder = DraftPersistenceRecorder(pauseFirstUpdate: true)
    let manager = DraftManager(debounceDelay: 60, persistence: recorder.client)
    let peer: InlineKit.Peer = .thread(id: 1009)
    let draft = NSAttributedString(string: "stale")

    manager.scheduleSave(peerId: peer, attributedString: draft)
    manager.cancelPendingSave()
    manager.save(peerId: peer, attributedString: draft)
    await recorder.waitUntilUpdateStarted()
    manager.clear(peerId: peer)
    await recorder.resumeFirstUpdate()
    await manager.waitForPendingPersistence()

    #expect(await recorder.updatedTexts.isEmpty)
    #expect(await recorder.clearCount == 1)
  }

  @Test("stale update completion does not poison snapshot deduplication")
  func staleUpdateCompletionDoesNotPoisonSnapshotDeduplication() async {
    let recorder = DraftPersistenceRecorder(pauseFirstUpdateAfterCommit: true)
    let manager = DraftManager(debounceDelay: 60, persistence: recorder.client)
    let peer: InlineKit.Peer = .thread(id: 1010)
    let draft = NSAttributedString(string: "same content")

    manager.scheduleSave(peerId: peer, attributedString: draft)
    manager.cancelPendingSave()
    manager.save(peerId: peer, attributedString: draft)
    await recorder.waitUntilUpdateCommitted()

    manager.scheduleSave(peerId: peer, attributedString: draft)
    manager.cancelPendingSave()
    await recorder.resumeFirstUpdateAfterCommit()
    await manager.waitForPersistenceWorker()
    manager.save(peerId: peer, attributedString: draft)
    await manager.waitForPendingPersistence()

    #expect(await recorder.updatedTexts == ["same content", "same content"])
  }

  @Test("debounced and lifecycle saves share one serial persistence worker")
  func debouncedAndLifecycleSavesAreSerialized() async {
    let recorder = DraftPersistenceRecorder(pauseFirstUpdate: true)
    let manager = DraftManager(debounceDelay: 0, persistence: recorder.client)
    let peer: InlineKit.Peer = .thread(id: 1011)

    manager.scheduleSave(
      peerId: peer,
      attributedString: NSAttributedString(string: "debounced")
    )
    await recorder.waitUntilUpdateStarted()

    manager.save(
      peerId: peer,
      attributedString: NSAttributedString(string: "lifecycle")
    )
    await recorder.resumeFirstUpdate()
    await manager.waitForPendingPersistence()

    #expect(await recorder.updatedTexts == ["debounced", "lifecycle"])
    #expect(await recorder.lastUpdatedText == "lifecycle")
  }

  private func mentionEntities(offset: Int64, length: Int64) -> MessageEntities {
    var entity = MessageEntity()
    entity.type = .mention
    entity.offset = offset
    entity.length = length
    entity.mention = MessageEntity.MessageEntityMention.with {
      $0.userID = 42
    }

    return MessageEntities.with {
      $0.entities = [entity]
    }
  }
}

private actor DraftPersistenceRecorder {
  private let drafts = Drafts()
  private let firstUpdateGate: AsyncGate?
  private let firstUpdateReturnGate: AsyncGate?
  private let firstClearGate: AsyncGate?
  private var didPauseUpdate = false
  private var didPauseClear = false
  private var updates: [String] = []
  private var clears = 0
  private var committedOperationCount = 0
  private var operationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  init(
    pauseFirstUpdate: Bool = false,
    pauseFirstUpdateAfterCommit: Bool = false,
    pauseFirstClear: Bool = false
  ) {
    firstUpdateGate = pauseFirstUpdate ? AsyncGate() : nil
    firstUpdateReturnGate = pauseFirstUpdateAfterCommit ? AsyncGate() : nil
    firstClearGate = pauseFirstClear ? AsyncGate() : nil
  }

  nonisolated var client: DraftPersistenceClient {
    DraftPersistenceClient(
      registerIntent: { [drafts] peerId, kind in
        drafts.registerIntent(for: peerId, kind: kind)
      },
      isLatestIntent: { [drafts] intent in
        drafts.isLatestIntent(intent)
      },
      update: { [weak self] peerId, text, _, intent in
        guard let self else { return false }
        return await self.recordUpdate(
          peerId: peerId,
          text: text,
          intent: intent
        )
      },
      clear: { [weak self] peerId, intent in
        guard let self else { return false }
        return await self.recordClear(peerId: peerId, intent: intent)
      }
    )
  }

  var updateCount: Int {
    updates.count
  }

  var clearCount: Int {
    clears
  }

  var lastUpdatedText: String? {
    updates.last
  }

  var updatedTexts: [String] {
    updates
  }

  func waitUntilUpdateStarted() async {
    await firstUpdateGate?.waitUntilArrived()
  }

  func resumeFirstUpdate() async {
    await firstUpdateGate?.open()
  }

  func waitUntilUpdateCommitted() async {
    await firstUpdateReturnGate?.waitUntilArrived()
  }

  func resumeFirstUpdateAfterCommit() async {
    await firstUpdateReturnGate?.open()
  }

  func waitUntilClearStarted() async {
    await firstClearGate?.waitUntilArrived()
  }

  func resumeFirstClear() async {
    await firstClearGate?.open()
  }

  func waitForCommittedOperationCount(_ count: Int) async {
    guard committedOperationCount < count else { return }
    await withCheckedContinuation { continuation in
      operationWaiters.append((count, continuation))
    }
  }

  private func recordUpdate(
    peerId: InlineKit.Peer,
    text: String,
    intent: DraftWriteIntent
  ) async -> Bool {
    let gate = didPauseUpdate ? nil : firstUpdateGate
    didPauseUpdate = true
    await gate?.arriveAndWait()
    guard drafts.isLatestIntent(intent), intent.peerId == peerId else {
      return false
    }
    updates.append(text)
    didCommitOperation()
    await firstUpdateReturnGate?.arriveAndWait()
    return true
  }

  private func recordClear(
    peerId: InlineKit.Peer,
    intent: DraftWriteIntent
  ) async -> Bool {
    let gate = didPauseClear ? nil : firstClearGate
    didPauseClear = true
    await gate?.arriveAndWait()
    guard drafts.isLatestIntent(intent), intent.peerId == peerId else {
      return false
    }
    clears += 1
    didCommitOperation()
    return true
  }

  private func didCommitOperation() {
    committedOperationCount += 1
    let ready = operationWaiters.filter { $0.count <= committedOperationCount }
    operationWaiters.removeAll { $0.count <= committedOperationCount }
    ready.forEach { $0.continuation.resume() }
  }
}

private actor AsyncGate {
  private var hasArrived = false
  private var isOpen = false
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
  private var openWaiters: [CheckedContinuation<Void, Never>] = []

  func arriveAndWait() async {
    hasArrived = true
    arrivalWaiters.forEach { $0.resume() }
    arrivalWaiters.removeAll()
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      openWaiters.append(continuation)
    }
  }

  func waitUntilArrived() async {
    guard !hasArrived else { return }
    await withCheckedContinuation { continuation in
      arrivalWaiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    openWaiters.forEach { $0.resume() }
    openWaiters.removeAll()
  }
}
