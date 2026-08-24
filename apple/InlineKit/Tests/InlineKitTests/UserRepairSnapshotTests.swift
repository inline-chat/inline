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
    let engine = UpdatesEngine(database: appDatabase, authenticatedUserID: { 42 })

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
      reason: "test"
    ))

    #expect(committed?.seq == 55)
    #expect(committed?.date == 220)
    try await queue.read { db in
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

  @Test("a stale repair cannot regress a newer durable cursor")
  func staleRepairDoesNotRegressCursor() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(database: appDatabase, authenticatedUserID: { 42 })

    try await queue.write { db in
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
      reason: "stale-test"
    ))

    #expect(committed?.seq == 75)
    #expect(committed?.date == 300)
    try await queue.read { db in
      let staleUser = try User.fetchOne(db, id: 42)
      #expect(staleUser == nil)
    }
  }

  @Test("incomplete snapshot import retains the durable cursor")
  func incompleteSnapshotDoesNotAdvance() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(database: appDatabase, authenticatedUserID: { 42 })

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
      reason: "invalid-snapshot-test"
    ))

    #expect(committed == nil)
    try await queue.read { db in
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
    let engine = UpdatesEngine(database: appDatabase, authenticatedUserID: { 42 })

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
      reason: "wrong-user-test"
    ))

    #expect(committed == nil)
    try await queue.read { db in
      let bucketCount = try DbBucketState.fetchCount(db)
      #expect(bucketCount == 0)
    }
  }

  @Test("checkpoint below the replacement target cannot advance")
  func staleCheckpointDoesNotAdvance() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(database: appDatabase, authenticatedUserID: { 42 })

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
      reason: "checkpoint-behind-test"
    ))

    #expect(committed == nil)
    try await queue.read { db in
      let bucketCount = try DbBucketState.fetchCount(db)
      let importedUser = try User.fetchOne(db, id: 42)
      #expect(bucketCount == 0)
      #expect(importedUser == nil)
    }
  }

  private func userSettingsResult() -> InlineProtocol.GetUserSettingsResult {
    var result = InlineProtocol.GetUserSettingsResult()
    result.userSettings = .init()
    return result
  }
}
