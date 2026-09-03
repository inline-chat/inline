@testable import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("User bucket repair")
struct UserRepairSnapshotTests {
  @Test("commits the snapshot checkpoint only after importing the account snapshot")
  func importsSnapshotBeforeAdvancingCursor() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )

    var user = InlineProtocol.User()
    user.id = 42
    user.firstName = "Recovered"
    var me = InlineProtocol.GetMeResult()
    me.user = user

    let chats = InlineProtocol.GetChatsResult()
    let target = BucketState(date: 200, seq: 50)
    let committed = await engine.applyUserRepair(UserRepairSnapshot(
      chats: chats,
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      targetState: target,
      mutationToken: accountToken(),
      reason: "test"
    ))

    guard let committed,
          case let .applied(state, seededStates, replayThroughState, retiredBucketKeys) = committed
    else {
      Issue.record("Expected the user repair to win admission")
      return
    }
    #expect(state.seq == 55)
    #expect(state.date == 220)
    #expect(seededStates.isEmpty)
    #expect(replayThroughState == nil)
    #expect(retiredBucketKeys.isEmpty)
    try await queue.read { (db: Database) throws in
      let recoveredUser = try User.fetchOne(db, id: 42)
      #expect(recoveredUser?.firstName == "Recovered")
      let state = try #require(try DbBucketState
        .filter(DbBucketState.Columns.bucketType == BucketKey.user.getBucket())
        .filter(DbBucketState.Columns.entityId == BucketKey.user.getEntityId())
        .fetchOne(db))
      #expect(state.seq == 55)
      #expect(state.date == 220)
    }
  }

  @Test("catalog replacement requires and preserves its post-projection replay bound")
  func catalogReplacementCarriesReplayBound() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 42 }

    let missingBound = await engine.applyUserRepair(UserRepairSnapshot(
      chats: .init(),
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      replacesActiveCatalog: true,
      reason: "missing-replay-bound"
    ))
    #expect(missingBound == nil)

    let outcome = await engine.applyUserRepair(UserRepairSnapshot(
      chats: .init(),
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      replayThroughState: BucketState(date: 230, seq: 57),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      replacesActiveCatalog: true,
      reason: "bounded-account-rebase"
    ))
    guard case let .applied(state, _, replayThroughState, retiredBucketKeys)? = outcome else {
      Issue.record("Expected the bounded account rebase to apply")
      return
    }
    #expect(state.seq == 55)
    #expect(replayThroughState?.date == 230)
    #expect(replayThroughState?.seq == 57)
    #expect(retiredBucketKeys.isEmpty)
  }

  @Test("child catch-up targets keep the user cursor pending until they are durable")
  func childTargetsGateUserCursorFinalization() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )
    let childKey = BucketKey.chat(peer: chatPeer(7))
    try await queue.write { (db: Database) throws in
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 10),
        type: .thread,
        title: "Cached",
        spaceId: nil
      ).insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: childKey,
        state: BucketState(date: 10, seq: 1),
        in: db
      )
    }

    var child = InlineProtocol.Chat()
    child.id = 7
    child.date = 20
    child.title = "Catalog Snapshot"
    child.peerID = chatPeer(7)
    child.seq = 5
    var chats = InlineProtocol.GetChatsResult()
    chats.chats = [child]
    var user = InlineProtocol.User()
    user.id = 42
    user.firstName = "Recovered"
    var me = InlineProtocol.GetMeResult()
    me.user = user

    let repair = UserRepairSnapshot(
      chats: chats,
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      reason: "pending-child-target"
    )
    let outcome = await engine.applyUserRepair(repair)
    guard let outcome,
          case let .pending(finalization, seededStates) = outcome
    else {
      Issue.record("Expected child catch-up to defer the user cursor")
      return
    }
    #expect(seededStates.isEmpty)
    #expect(finalization.expectedUserState.seq == 0)
    #expect(!finalization.expectedUserStateExists)
    #expect(finalization.proposedUserState.seq == 55)
    #expect(finalization.catchUpTargets[childKey] == 5)
    try await queue.read { (db: Database) throws -> Void in
      #expect(try DbBucketState
        .filter(DbBucketState.Columns.bucketType == BucketKey.user.getBucket())
        .fetchCount(db) == 0)
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Cached")
    }

    let repeated = await engine.applyUserRepair(repair)
    guard let repeated,
          case let .pending(repeatedFinalization, _) = repeated
    else {
      Issue.record("Expected a crash-style retry to recover the child demand")
      return
    }
    #expect(repeatedFinalization.catchUpTargets[childKey] == 5)

    let premature = await engine.finalizeUserRepair(
      finalization,
      resolvedTargets: [
        childKey: UserRepairTargetResolution(
          state: BucketState(date: 20, seq: 5),
          authoritative: false
        ),
      ]
    )
    #expect(premature == nil)

    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(
        for: childKey,
        state: BucketState(date: 20, seq: 5),
        in: db
      )
    }
    let finalized = await engine.finalizeUserRepair(
      finalization,
      resolvedTargets: [
        childKey: UserRepairTargetResolution(
          state: BucketState(date: 20, seq: 5),
          authoritative: false
        ),
      ]
    )
    #expect(finalized?.seq == 55)
    try await queue.read { (db: Database) throws in
      let userState = try #require(try DbBucketState
        .filter(DbBucketState.Columns.bucketType == BucketKey.user.getBucket())
        .fetchOne(db))
      #expect(userState.date == 220)
      #expect(userState.seq == 55)
    }
  }

  @Test("a latest child target requires authoritative resolution")
  func latestChildTargetRequiresAuthoritativeResolution() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )
    let childKey = BucketKey.space(id: 7)
    let childState = BucketState(date: 20, seq: 3)
    try await queue.write { (db: Database) throws in
      try User(
        id: 42,
        email: "restored@example.com",
        firstName: "Restored"
      ).insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: childKey,
        state: childState,
        in: db
      )
    }
    let finalization = UserRepairFinalization(
      expectedUserState: BucketState(date: 0, seq: 0),
      expectedUserStateExists: false,
      proposedUserState: BucketState(date: 220, seq: 55),
      catchUpTargets: [childKey: 0],
      mutationToken: accountToken()
    )

    let nonAuthoritative = await engine.finalizeUserRepair(
      finalization,
      resolvedTargets: [
        childKey: UserRepairTargetResolution(
          state: childState,
          authoritative: false
        ),
      ]
    )
    #expect(nonAuthoritative == nil)
    let authoritative = await engine.finalizeUserRepair(
      finalization,
      resolvedTargets: [
        childKey: UserRepairTargetResolution(
          state: childState,
          authoritative: true
        ),
      ]
    )
    #expect(authoritative?.seq == 55)
  }

  @Test("an equal-cursor regression audit still discovers child gaps without replaying settings")
  @MainActor
  func equalCursorProjectionAuditDiscoversChildTargets() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let settingsRecorder = UserRepairSettingsRecorder()
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in settingsRecorder.applyCount += 1 }
    )
    let childKey = BucketKey.chat(peer: chatPeer(7))
    try await queue.write { (db: Database) throws in
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 10),
        type: .thread,
        title: "Cached",
        spaceId: nil
      ).insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: childKey,
        state: BucketState(date: 10, seq: 1),
        in: db
      )
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .user,
        state: BucketState(date: 220, seq: 55),
        in: db
      )
    }

    var child = InlineProtocol.Chat()
    child.id = 7
    child.date = 20
    child.title = "Catalog Snapshot"
    child.peerID = chatPeer(7)
    child.seq = 5
    var chats = InlineProtocol.GetChatsResult()
    chats.chats = [child]
    var user = InlineProtocol.User()
    user.id = 42
    user.firstName = "Audited"
    var me = InlineProtocol.GetMeResult()
    me.user = user

    let outcome = await engine.applyUserRepair(UserRepairSnapshot(
      chats: chats,
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      targetState: BucketState(date: 220, seq: 55),
      mutationToken: accountToken(),
      requiresProjectionAudit: true,
      reason: "checkpoint_regression"
    ))

    guard let outcome,
          case let .pending(finalization, seededStates) = outcome
    else {
      Issue.record("Expected the regression audit to discover the child gap")
      return
    }
    #expect(settingsRecorder.applyCount == 0)
    #expect(seededStates.isEmpty)
    #expect(finalization.expectedUserStateExists)
    #expect(finalization.expectedUserState.seq == 55)
    #expect(finalization.proposedUserState.seq == 55)
    #expect(finalization.catchUpTargets[childKey] == 5)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Cached")
      #expect(try User.fetchOne(db, id: 42)?.firstName == "Audited")
      let userState = try #require(try DbBucketState
        .filter(DbBucketState.Columns.bucketType == BucketKey.user.getBucket())
        .fetchOne(db))
      #expect(userState.date == 220)
      #expect(userState.seq == 55)
    }
  }

  @Test("an interrupted fresh catalog replacement restores settings at an equal cursor")
  @MainActor
  func equalCursorCatalogReplacementRestoresSettings() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let settingsRecorder = UserRepairSettingsRecorder()
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in settingsRecorder.applyCount += 1 }
    )
    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .user,
        state: BucketState(date: 220, seq: 55),
        in: db
      )
    }
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 42; $0.firstName = "Recovered" }

    let outcome = await engine.applyUserRepair(UserRepairSnapshot(
      chats: .init(),
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      replayThroughState: BucketState(date: 220, seq: 55),
      targetState: BucketState(date: 220, seq: 55),
      mutationToken: accountToken(),
      replacesActiveCatalog: true,
      requiresProjectionAudit: true,
      reason: "fresh_account_bootstrap"
    ))

    guard case let .applied(state, _, replayThroughState, _)? = outcome else {
      Issue.record("Expected the interrupted fresh catalog replacement to reapply")
      return
    }
    #expect(state.seq == 55)
    #expect(replayThroughState?.seq == 55)
    #expect(settingsRecorder.applyCount == 1)
  }

  @Test("a stale repair cannot regress a newer durable cursor")
  @MainActor
  func staleRepairDoesNotRegressCursorOrApplySettings() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let settingsRecorder = UserRepairSettingsRecorder()
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in settingsRecorder.applyCount += 1 }
    )

    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .user,
        state: BucketState(date: 300, seq: 75),
        in: db
      )
    }

    var user = InlineProtocol.User()
    user.id = 42
    user.firstName = "Stale"
    var me = InlineProtocol.GetMeResult()
    me.user = user

    let committed = await engine.applyUserRepair(UserRepairSnapshot(
      chats: InlineProtocol.GetChatsResult(),
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 200, seq: 50),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      reason: "stale-test"
    ))

    guard let committed, case let .superseded(currentState, replayThroughState) = committed else {
      Issue.record("Expected the stale repair to lose admission")
      return
    }
    #expect(currentState.seq == 75)
    #expect(currentState.date == 300)
    #expect(replayThroughState == nil)
    #expect(settingsRecorder.applyCount == 0)
    try await queue.read { (db: Database) throws in
      let staleUser = try User.fetchOne(db, id: 42)
      #expect(staleUser == nil)
    }
  }

  @Test("a delayed regression audit preserves user projections newer than its checkpoint")
  func delayedProjectionAuditDoesNotClobberNewerUserState() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )
    try await queue.write { (db: Database) throws in
      try User(id: 42, email: "current@example.com", firstName: "Current").insert(db)
      try DialogFolder(id: 7, title: "Current folder", order: "a").insert(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: BucketState(date: 230, seq: 56), in: db)
    }
    var me = InlineProtocol.GetMeResult()
    me.user = .with { $0.id = 42; $0.firstName = "Stale" }
    var chats = InlineProtocol.GetChatsResult()
    chats.users = [me.user]
    chats.folders = [.with { $0.id = 7; $0.title = "Stale folder"; $0.order = "b" }]
    let outcome = await engine.applyUserRepair(UserRepairSnapshot(
      chats: chats,
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      targetState: BucketState(date: 220, seq: 55),
      mutationToken: accountToken(),
      requiresProjectionAudit: true,
      reason: "delayed-regression-audit"
    ))
    guard case let .applied(state, _, replayThroughState, retiredBucketKeys)? = outcome else {
      Issue.record("Expected a child-only audit to finish without rewriting the user projection")
      return
    }
    #expect(state.seq == 56)
    #expect(replayThroughState == nil)
    #expect(retiredBucketKeys.isEmpty)
    try await queue.read { (db: Database) throws -> Void in
      #expect(try User.fetchOne(db, id: 42)?.firstName == "Current")
      #expect(try DialogFolder.fetchOne(db, id: 7)?.title == "Current folder")
    }
  }

  @Test("incomplete snapshot import retains the durable cursor")
  func incompleteSnapshotDoesNotAdvance() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )

    var invalidChat = InlineProtocol.Chat()
    invalidChat.id = 7
    invalidChat.seq = 9
    var chats = InlineProtocol.GetChatsResult()
    chats.chats = [invalidChat]

    var user = InlineProtocol.User()
    user.id = 42
    user.firstName = "Recovered"
    var me = InlineProtocol.GetMeResult()
    me.user = user

    let committed = await engine.applyUserRepair(UserRepairSnapshot(
      chats: chats,
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 200, seq: 50),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      reason: "invalid-snapshot-test"
    ))

    #expect(committed == nil)
    try await queue.read { (db: Database) throws in
      let bucketCount = try DbBucketState.fetchCount(db)
      #expect(bucketCount == 0)
      let importedUser = try User.fetchOne(db, id: 42)
      #expect(importedUser == nil)
    }
  }

  @Test("snapshot user must match the authenticated account")
  func mismatchedUserDoesNotAdvance() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )

    var user = InlineProtocol.User()
    user.id = 99
    var me = InlineProtocol.GetMeResult()
    me.user = user

    let committed = await engine.applyUserRepair(UserRepairSnapshot(
      chats: InlineProtocol.GetChatsResult(),
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 200, seq: 50),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      reason: "wrong-user-test"
    ))

    #expect(committed == nil)
    try await queue.read { (db: Database) throws in
      let bucketCount = try DbBucketState.fetchCount(db)
      #expect(bucketCount == 0)
    }
  }

  @Test("checkpoint below the replacement target cannot advance")
  func staleCheckpointDoesNotAdvance() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, _, _ in }
    )

    var user = InlineProtocol.User()
    user.id = 42
    var me = InlineProtocol.GetMeResult()
    me.user = user

    let committed = await engine.applyUserRepair(UserRepairSnapshot(
      chats: InlineProtocol.GetChatsResult(),
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 210, seq: 49),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      reason: "checkpoint-behind-test"
    ))

    #expect(committed == nil)
    try await queue.read { (db: Database) throws in
      let bucketCount = try DbBucketState.fetchCount(db)
      let importedUser = try User.fetchOne(db, id: 42)
      #expect(bucketCount == 0)
      #expect(importedUser == nil)
    }
  }

  @Test("a suspended settings apply fences account generation and reentrant user batches")
  func suspendedSettingsApplyRejectsCursorAndGenerationRace() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let gate = UserRepairSettingsGate()
    let validator = UserRepairTokenValidator()
    let recorder = UserRepairApplyRecorder()
    let engine = UpdatesEngine(
      database: appDatabase,
      authenticatedUserID: { 42 },
      validateAccountMutation: { token in
        try validator.validate(token)
      },
      applyUserSettings: { _, _, token in
        await gate.suspendUntilReleased()
        try validator.validate(token)
        await recorder.record()
      }
    )

    var user = InlineProtocol.User()
    user.id = 42
    user.firstName = "Must Not Import"
    var me = InlineProtocol.GetMeResult()
    me.user = user
    let repair = UserRepairSnapshot(
      chats: InlineProtocol.GetChatsResult(),
      me: me,
      settings: userSettingsResult(),
      checkpointState: BucketState(date: 220, seq: 55),
      targetState: BucketState(date: 200, seq: 50),
      mutationToken: accountToken(),
      reason: "suspended-settings-race"
    )
    let repairTask = Task {
      await engine.applyUserRepair(repair)
    }

    await gate.waitUntilSuspended()
    var settings = InlineProtocol.UpdateUserSettings()
    settings.settings = .with {
      $0.notificationSettings = .with { $0.silent = true }
    }
    var settingsUpdate = InlineProtocol.Update()
    settingsUpdate.seq = 1
    settingsUpdate.date = 10
    settingsUpdate.update = .updateUserSettings(settings)
    let reentrant = await engine.applyBatch(
      updates: [settingsUpdate],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: BucketState(date: 10, seq: 1),
        expectedStartState: BucketState(date: 0, seq: 0)
      ),
      mutationToken: accountToken()
    )
    #expect(!reentrant.succeeded)

    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .user,
        state: BucketState(date: 230, seq: 60),
        in: db
      )
    }
    validator.invalidate()
    await gate.release()

    let outcome = await repairTask.value
    let applyCount = await recorder.count()
    #expect(outcome == nil)
    #expect(applyCount == 0)
    try await queue.read { (db: Database) throws in
      #expect(try User.fetchOne(db, id: 42) == nil)
      let state = try #require(try DbBucketState.fetchOne(db))
      #expect(state.date == 230)
      #expect(state.seq == 60)
    }
  }

  private func userSettingsResult() -> InlineProtocol.GetUserSettingsResult {
    var result = InlineProtocol.GetUserSettingsResult()
    result.userSettings = .init()
    return result
  }

  private func chatPeer(_ chatID: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatID }
  }

  private func accountToken() -> AuthAccountMutationToken {
    AuthAccountMutationToken(generation: 1, userID: 42)
  }
}

@MainActor
private final class UserRepairSettingsRecorder {
  var applyCount = 0
}

private enum UserRepairRaceError: Error {
  case staleToken
}

private final class UserRepairTokenValidator: @unchecked Sendable {
  private let lock = NSLock()
  private var isValid = true

  func validate(_: AuthAccountMutationToken) throws {
    lock.lock()
    defer { lock.unlock() }
    guard isValid else { throw UserRepairRaceError.staleToken }
  }

  func invalidate() {
    lock.lock()
    isValid = false
    lock.unlock()
  }
}

private actor UserRepairSettingsGate {
  private var isSuspended = false
  private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func suspendUntilReleased() async {
    isSuspended = true
    let waiters = suspensionWaiters
    suspensionWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilSuspended() async {
    guard !isSuspended else { return }
    await withCheckedContinuation { continuation in
      suspensionWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor UserRepairApplyRecorder {
  private var applyCount = 0

  func record() {
    applyCount += 1
  }

  func count() -> Int {
    applyCount
  }
}
