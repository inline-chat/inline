@testable import Auth
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("Durable update apply")
struct DurableUpdateApplyTests {
  @Test("a known reducer failure rolls back sidecars and the bucket cursor")
  func reducerFailureRollsBackWholeBucketBatch() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let engine = UpdatesEngine(database: database)

    var sidecarUser = InlineProtocol.User()
    sidecarUser.id = 55
    sidecarUser.firstName = "Must Roll Back"
    var sidecars = InlineProtocol.UpdateSidecars()
    sidecars.users = [sidecarUser]

    var deletion = InlineProtocol.UpdateDeleteMessages()
    deletion.peerID = chatPeer(7)
    deletion.messageIds = [1]
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 10
    update.update = .deleteMessages(deletion)

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: 1)
      )
    )

    #expect(!result.succeeded)
    #expect(result.committedBucketState == nil)
    try await queue.read { (db: Database) throws in
      #expect(try User.fetchOne(db, id: 55) == nil)
      #expect(try DbBucketState.fetchCount(db) == 0)
    }
  }

  @Test("a stale starting cursor rejects sidecars and reducers before they mutate")
  func cursorCASRejectsRacingBucketApply() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let engine = UpdatesEngine(database: database)
    let key = BucketKey.chat(peer: chatPeer(7))
    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(
        for: key,
        state: BucketState(date: 20, seq: 2),
        in: db
      )
    }

    var sidecarUser = InlineProtocol.User()
    sidecarUser.id = 55
    sidecarUser.firstName = "Must Not Apply"
    var sidecars = InlineProtocol.UpdateSidecars()
    sidecars.users = [sidecarUser]
    var accountedNoOp = InlineProtocol.Update()
    accountedNoOp.seq = 1
    accountedNoOp.date = 10

    let result = await engine.applyBatch(
      updates: [accountedNoOp],
      source: .syncCatchup,
      sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(
        key: key,
        state: BucketState(date: 10, seq: 1),
        expectedStartState: BucketState(date: 0, seq: 0)
      )
    )

    #expect(!result.succeeded)
    #expect(result.committedBucketState == nil)
    try await queue.read { (db: Database) throws in
      #expect(try User.fetchOne(db, id: 55) == nil)
      let state = try #require(try DbBucketState.fetchOne(db))
      #expect(state.date == 20)
      #expect(state.seq == 2)
    }
  }

  @Test("a later reducer failure cannot leak an earlier non-database effect")
  func reducerFailureDoesNotLeakDeferredEffects() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let recorder = DeferredEffectRecorder()
    let engine = UpdatesEngine(
      database: database,
      applyDeferredEffects: { effects in
        await recorder.record(effects.count)
      }
    )

    var presence = InlineProtocol.Update()
    presence.seq = 1
    presence.date = 10
    presence.update = .botPresence(InlineProtocol.UpdateBotPresence())
    var deletion = InlineProtocol.UpdateDeleteMessages()
    deletion.peerID = chatPeer(7)
    deletion.messageIds = [1]
    var failingReducer = InlineProtocol.Update()
    failingReducer.seq = 2
    failingReducer.date = 10
    failingReducer.update = .deleteMessages(deletion)

    let result = await engine.applyBatch(
      updates: [presence, failingReducer],
      source: .realtime,
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: 2),
        expectedStartState: BucketState(date: 0, seq: 0)
      )
    )

    #expect(!result.succeeded)
    let effectCount = await recorder.recordedCount()
    #expect(effectCount == 0)
    try await queue.read { (db: Database) throws in
      #expect(try DbBucketState.fetchCount(db) == 0)
    }
  }

  @Test("a non-database effect is delivered after its bucket cursor commits")
  func committedBatchDeliversDeferredEffect() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let recorder = DeferredEffectRecorder()
    let engine = UpdatesEngine(
      database: database,
      applyDeferredEffects: { effects in
        await recorder.record(effects.count)
      }
    )
    var presence = InlineProtocol.Update()
    presence.seq = 1
    presence.date = 10
    presence.update = .botPresence(InlineProtocol.UpdateBotPresence())

    let result = await engine.applyBatch(
      updates: [presence],
      source: .realtime,
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: 1),
        expectedStartState: BucketState(date: 0, seq: 0)
      )
    )

    let effectCount = await recorder.recordedCount()
    #expect(result.succeeded)
    #expect(result.committedBucketState?.seq == 1)
    #expect(effectCount == 1)
  }

  @Test("catch-up accounts for ephemeral effects without replaying stale UI state")
  func catchUpDoesNotReplayEphemeralEffects() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let recorder = DeferredEffectRecorder()
    let engine = UpdatesEngine(
      database: database,
      applyDeferredEffects: { effects in
        await recorder.record(effects.count)
      }
    )
    var presence = InlineProtocol.Update()
    presence.seq = 1
    presence.date = 10
    presence.update = .botPresence(InlineProtocol.UpdateBotPresence())

    let result = await engine.applyBatch(
      updates: [presence],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: 1),
        expectedStartState: BucketState(date: 0, seq: 0)
      )
    )

    let effectCount = await recorder.recordedCount()
    #expect(result.succeeded)
    #expect(result.committedBucketState?.seq == 1)
    #expect(effectCount == 0)
  }

  @Test("a required sidecar failure leaves replacement settings ahead but never the cursor")
  @MainActor
  func sidecarFailureNeverLeavesCursorAheadOfSettings() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let recorder = DurableSettingsRecorder()
    let engine = UpdatesEngine(
      database: database,
      authenticatedUserID: { 42 },
      validateAccountMutation: { _ in },
      applyUserSettings: { _, userID, _ in
        recorder.userIDs.append(userID)
      }
    )

    var invalidGroup = InlineProtocol.UserGroup()
    invalidGroup.id = 88
    invalidGroup.spaceID = 999
    invalidGroup.name = "Missing space"
    invalidGroup.date = 10
    var sidecars = InlineProtocol.UpdateSidecars()
    sidecars.userGroups = [invalidGroup]

    var settings = InlineProtocol.UpdateUserSettings()
    settings.settings = .with {
      $0.notificationSettings = .with { $0.silent = true }
    }
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 10
    update.update = .updateUserSettings(settings)

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: BucketState(date: 10, seq: 1)
      ),
      mutationToken: accountToken()
    )

    #expect(!result.succeeded)
    #expect(recorder.userIDs == [42])
    try await queue.read { (db: Database) throws in
      #expect(try UserGroup.fetchCount(db) == 0)
      #expect(try DbBucketState.fetchCount(db) == 0)
    }
  }

  @Test("an unknown accounted constructor remains a no-op and commits its sequence")
  func unknownConstructorIsAccounted() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let engine = UpdatesEngine(database: database)
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 10

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: BucketState(date: 10, seq: 1)
      )
    )

    #expect(result.succeeded)
    #expect(result.committedBucketState?.seq == 1)
    try await queue.read { (db: Database) throws in
      #expect(try DbBucketState.fetchOne(db)?.seq == 1)
    }
  }

  private func chatPeer(_ chatID: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatID }
  }

  private func accountToken() -> AuthAccountMutationToken {
    AuthAccountMutationToken(generation: 1, userID: 42)
  }
}

@MainActor
private final class DurableSettingsRecorder {
  var userIDs: [Int64] = []
}

private actor DeferredEffectRecorder {
  private var count = 0

  func record(_ value: Int) {
    count += value
  }

  func recordedCount() -> Int {
    count
  }
}
