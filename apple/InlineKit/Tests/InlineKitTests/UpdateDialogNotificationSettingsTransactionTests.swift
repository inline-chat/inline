@testable import InlineKit
import Foundation
import InlineProtocol
import Testing

@Suite("Dialog notification settings transaction")
struct DialogNotificationTransactionTests {
  @Test("Transactions receive distinct rollback intents")
  func transactionsHaveDistinctIntents() throws {
    let first = UpdateDialogNotificationSettingsTransaction(peerId: .user(id: 104), selection: .all)
    let second = UpdateDialogNotificationSettingsTransaction(peerId: .user(id: 104), selection: .none)

    let firstIntent = try #require(first.context.intentId)
    let secondIntent = try #require(second.context.intentId)
    #expect(firstIntent != secondIntent)
  }

  @Test("Notification mutations share only their peer execution lane")
  func notificationExecutionKeysArePeerScoped() throws {
    let first = UpdateDialogNotificationSettingsTransaction(peerId: .user(id: 104), selection: .all)
    let samePeer = UpdateDialogNotificationSettingsTransaction(peerId: .user(id: 104), selection: .none)
    let otherUser = UpdateDialogNotificationSettingsTransaction(peerId: .user(id: 105), selection: .none)
    let sameNumericThread = UpdateDialogNotificationSettingsTransaction(peerId: .thread(id: 104), selection: .none)

    #expect(first.executionKey == samePeer.executionKey)
    #expect(first.executionKey != otherUser.executionKey)
    #expect(first.executionKey != sameNumericThread.executionKey)
  }

  @Test("Notification mutations do not automatically replay after ACK")
  func notificationMutationDoesNotReplayAfterAck() {
    let transaction = UpdateDialogNotificationSettingsTransaction(peerId: .user(id: 104), selection: .all)

    guard case .mutation = transaction.type else {
      Issue.record("Expected a mutation transaction")
      return
    }
    #expect(transaction.reconnectReplayPolicy == nil)
  }

  @Test("Previously queued transactions decode without a rollback intent")
  func legacyTransactionDecoding() throws {
    let payload = LegacyNotificationTransaction(
      context: LegacyNotificationContext(
        peerId: .thread(id: 105),
        selection: .mentions
      )
    )

    let data = try JSONEncoder().encode(payload)
    let transaction = try JSONDecoder().decode(
      UpdateDialogNotificationSettingsTransaction.self,
      from: data
    )

    #expect(transaction.context.peerId == .thread(id: 105))
    #expect(transaction.context.selection == .mentions)
    #expect(transaction.context.intentId == nil)
  }

  @Test("Rollback restores only notification settings")
  func rollbackPreservesUnrelatedDialogState() {
    var current = Dialog(optimisticForUserId: 105)
    current.notificationSettings = .with { $0.mode = .none }
    current.open = true
    current.pinned = true
    current.unreadCount = 42

    let didRestore = UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(
      &current,
      using: DialogNotificationMutationResolution(
        token: 1,
        expectedCurrentSelection: .none,
        targetSelection: .all,
        targetSettings: .with { $0.mode = .all }
      )
    )

    #expect(didRestore)
    #expect(current.notificationSelection == .all)
    #expect(current.open)
    #expect(current.pinned == true)
    #expect(current.unreadCount == 42)
  }

  @Test("Rollback does not replace a newer notification selection")
  func rollbackPreservesNewerNotificationSelection() {
    var current = Dialog(optimisticForUserId: 106)
    current.notificationSettings = .with { $0.mode = .mentions }

    let didRestore = UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(
      &current,
      using: DialogNotificationMutationResolution(
        token: 1,
        expectedCurrentSelection: .none,
        targetSelection: .all,
        targetSettings: .with { $0.mode = .all }
      )
    )

    #expect(!didRestore)
    #expect(current.notificationSelection == .mentions)
  }

  @Test("Two failed optimistic choices restore the original baseline")
  func chainedFailuresRestoreOriginalBaseline() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 107)
    let original = Dialog(optimisticForUserId: 107)

    await tracker.recordNotification(
      intentID: "all",
      peer: peer,
      original: original,
      selection: .all
    )
    var afterFirst = original
    afterFirst.notificationSettings = .with { $0.mode = .all }
    await tracker.recordNotification(
      intentID: "none",
      peer: peer,
      original: afterFirst,
      selection: .none
    )

    let staleFailure = try #require(await tracker.beginNotificationFailure(intentID: "all", peer: peer))
    #expect(staleFailure.expectedCurrentSelection == .none)
    #expect(staleFailure.targetSelection == .none)
    await tracker.finalizeNotificationResolution(token: staleFailure.token, peer: peer)

    let latestFailure = try #require(await tracker.beginNotificationFailure(intentID: "none", peer: peer))
    #expect(latestFailure.expectedCurrentSelection == .none)
    #expect(latestFailure.targetSelection == .global)
    #expect(latestFailure.targetSettings == nil)
    await tracker.finalizeNotificationResolution(token: latestFailure.token, peer: peer)
  }

  @Test("Commit-unknown abandons rollback ownership without changing optimistic state")
  func commitUnknownDoesNotBecomeFailure() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 114)
    let original = Dialog(optimisticForUserId: 114)

    await tracker.recordNotification(
      intentID: "unknown",
      peer: peer,
      original: original,
      selection: .all
    )
    await tracker.abandonNotificationIntent(intentID: "unknown", peer: peer)
    if case .some = await tracker.beginNotificationFailure(intentID: "unknown", peer: peer) {
      Issue.record("An abandoned commit-unknown intent must not retain rollback ownership")
    }

    var optimistic = original
    optimistic.notificationSettings = .with { $0.mode = .all }
    await tracker.recordNotification(
      intentID: "next",
      peer: peer,
      original: optimistic,
      selection: .none
    )
    let nextFailure = try #require(await tracker.beginNotificationFailure(intentID: "next", peer: peer))
    #expect(nextFailure.targetSelection == .all)
  }

  @Test("A successful predecessor becomes the next failure baseline")
  func successfulPredecessorAdvancesRollbackBaseline() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 108)
    let original = Dialog(optimisticForUserId: 108)

    await tracker.recordNotification(
      intentID: "all",
      peer: peer,
      original: original,
      selection: .all
    )
    var afterFirst = original
    afterFirst.notificationSettings = .with { $0.mode = .all }
    await tracker.recordNotification(
      intentID: "none",
      peer: peer,
      original: afterFirst,
      selection: .none
    )

    let success = try #require(await tracker.beginNotificationSuccess(intentID: "all", peer: peer))
    #expect(success.expectedCurrentSelection == .all)
    #expect(success.targetSelection == .none)
    await tracker.finalizeNotificationResolution(token: success.token, peer: peer)

    let failure = try #require(await tracker.beginNotificationFailure(intentID: "none", peer: peer))

    #expect(failure.expectedCurrentSelection == .none)
    #expect(failure.targetSelection == .all)
    #expect(failure.targetSettings?.mode == .all)
    await tracker.finalizeNotificationResolution(token: failure.token, peer: peer)
  }

  @Test("Out-of-order failures still converge on the original baseline")
  func outOfOrderFailuresRestoreOriginalBaseline() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 109)
    let original = Dialog(optimisticForUserId: 109)

    await tracker.recordNotification(
      intentID: "all",
      peer: peer,
      original: original,
      selection: .all
    )
    await tracker.recordNotification(
      intentID: "none",
      peer: peer,
      original: original,
      selection: .none
    )

    let latestFailure = try #require(await tracker.beginNotificationFailure(intentID: "none", peer: peer))
    #expect(latestFailure.targetSelection == .all)
    await tracker.finalizeNotificationResolution(token: latestFailure.token, peer: peer)

    let earlierFailure = try #require(await tracker.beginNotificationFailure(intentID: "all", peer: peer))
    #expect(earlierFailure.expectedCurrentSelection == .all)
    #expect(earlierFailure.targetSelection == .global)
    await tracker.finalizeNotificationResolution(token: earlierFailure.token, peer: peer)
  }

  @Test("Reverse successes converge on the latest intent")
  func reverseSuccessesConvergeOnLatestIntent() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 110)
    let original = Dialog(optimisticForUserId: 110)

    await tracker.recordNotification(
      intentID: "all",
      peer: peer,
      original: original,
      selection: .all
    )
    await tracker.recordNotification(
      intentID: "none",
      peer: peer,
      original: original,
      selection: .none
    )

    var current = original
    current.notificationSettings = .with { $0.mode = .none }
    let latestSuccess = try #require(await tracker.beginNotificationSuccess(intentID: "none", peer: peer))
    #expect(latestSuccess.expectedCurrentSelection == .none)
    #expect(latestSuccess.targetSelection == .none)
    #expect(UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(&current, using: latestSuccess))
    await tracker.finalizeNotificationResolution(token: latestSuccess.token, peer: peer)

    current.notificationSettings = .with { $0.mode = .all }
    let earlierSuccess = try #require(await tracker.beginNotificationSuccess(intentID: "all", peer: peer))
    #expect(earlierSuccess.expectedCurrentSelection == .all)
    #expect(earlierSuccess.targetSelection == .none)
    #expect(UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(&current, using: earlierSuccess))
    #expect(current.notificationSelection == .none)
    await tracker.finalizeNotificationResolution(token: earlierSuccess.token, peer: peer)
  }

  @Test("A new intent recorded during reconciliation keeps the original baseline")
  func intentRecordedBeforeFinalizeKeepsOriginalBaseline() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 111)
    let original = Dialog(optimisticForUserId: 111)

    await tracker.recordNotification(
      intentID: "all",
      peer: peer,
      original: original,
      selection: .all
    )
    var current = original
    current.notificationSettings = .with { $0.mode = .all }
    let earlierFailure = try #require(await tracker.beginNotificationFailure(intentID: "all", peer: peer))

    await tracker.recordNotification(
      intentID: "none",
      peer: peer,
      original: current,
      selection: .none
    )
    current.notificationSettings = .with { $0.mode = .none }
    #expect(!UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(&current, using: earlierFailure))
    await tracker.finalizeNotificationResolution(token: earlierFailure.token, peer: peer)

    let latestFailure = try #require(await tracker.beginNotificationFailure(intentID: "none", peer: peer))
    #expect(latestFailure.expectedCurrentSelection == .none)
    #expect(latestFailure.targetSelection == .global)
    #expect(UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(&current, using: latestFailure))
    #expect(current.notificationSelection == .global)
    await tracker.finalizeNotificationResolution(token: latestFailure.token, peer: peer)
  }

  @Test("A failed local reconciliation does not become a newer intent's baseline")
  func unresolvedFailureDoesNotBecomeRollbackBaseline() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 113)
    let original = Dialog(optimisticForUserId: 113)

    await tracker.recordNotification(
      intentID: "all",
      peer: peer,
      original: original,
      selection: .all
    )
    let unresolvedFailure = try #require(
      await tracker.beginNotificationFailure(intentID: "all", peer: peer)
    )

    var staleLocalDialog = original
    staleLocalDialog.notificationSettings = .with { $0.mode = .all }
    await tracker.recordNotification(
      intentID: "none",
      peer: peer,
      original: staleLocalDialog,
      selection: .none
    )

    let newerFailure = try #require(
      await tracker.beginNotificationFailure(intentID: "none", peer: peer)
    )
    #expect(newerFailure.expectedCurrentSelection == .none)
    #expect(newerFailure.targetSelection == .global)
    #expect(newerFailure.targetSettings == nil)

    await tracker.finalizeNotificationResolution(token: newerFailure.token, peer: peer)
    await tracker.finalizeNotificationResolution(token: unresolvedFailure.token, peer: peer)
  }

  @Test("A reserved read keeps the baseline until its intent is recorded")
  func reservedReadKeepsBaselineAcrossFinalize() async throws {
    let tracker = DialogMutationRollbackTracker()
    let peer = InlineKit.Peer.user(id: 112)
    let original = Dialog(optimisticForUserId: 112)

    await tracker.recordNotification(
      intentID: "all",
      peer: peer,
      original: original,
      selection: .all
    )
    var current = original
    current.notificationSettings = .with { $0.mode = .all }
    let earlierFailure = try #require(await tracker.beginNotificationFailure(intentID: "all", peer: peer))

    await tracker.reserveNotificationRecord(intentID: "none", peer: peer)
    let staleRead = current
    #expect(UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(&current, using: earlierFailure))
    await tracker.finalizeNotificationResolution(token: earlierFailure.token, peer: peer)

    await tracker.recordNotification(
      intentID: "none",
      peer: peer,
      original: staleRead,
      selection: .none
    )
    current.notificationSettings = .with { $0.mode = .none }
    let latestFailure = try #require(await tracker.beginNotificationFailure(intentID: "none", peer: peer))
    #expect(latestFailure.targetSelection == .global)
    #expect(UpdateDialogNotificationSettingsTransaction.restoreNotificationSettings(&current, using: latestFailure))
    #expect(current.notificationSelection == .global)
    await tracker.finalizeNotificationResolution(token: latestFailure.token, peer: peer)
  }
}

private struct LegacyNotificationTransaction: Encodable {
  let context: LegacyNotificationContext
}

private struct LegacyNotificationContext: Encodable {
  let peerId: InlineKit.Peer
  let selection: DialogNotificationSettingSelection
}
