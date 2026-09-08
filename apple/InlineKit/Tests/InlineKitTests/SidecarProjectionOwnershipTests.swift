@testable import Auth
import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("Sidecar projection ownership")
struct SidecarProjectionOwnershipTests {
  private let chatID: Int64 = 700
  private let spaceID: Int64 = 70

  @Test("durable apply failures expose bounded privacy-safe Sentry categories")
  func durableApplyFailureCategories() {
    let foreignKey = durableUpdateFailure(
      DatabaseError(resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY),
      updateKind: "chatOpen"
    )
    #expect(foreignKey.privacySafeErrorCategory == "sync_apply:chatOpen:foreign_key")

    let busy = durableUpdateFailure(
      DatabaseError(resultCode: .SQLITE_BUSY_SNAPSHOT),
      updateKind: "sidecars"
    )
    #expect(busy.privacySafeErrorCategory == "sync_apply:sidecars:database_busy")
    let corrupt = durableUpdateFailure(
      DatabaseError(resultCode: .SQLITE_CORRUPT_VTAB),
      updateKind: "batch"
    )
    #expect(corrupt.privacySafeErrorCategory == "sync_apply:batch:database_corrupt")
    let missing = durableUpdateFailure(
      RealtimeUpdateApplyError.missingChat(.thread(id: 7)),
      updateKind: "deleteMessages"
    )
    #expect(missing.privacySafeErrorCategory == "sync_apply:deleteMessages:missing_entity")
    let missingAcknowledgementChat = durableUpdateFailure(
      AcknowledgementPersistenceError.missingChat(7),
      updateKind: "acknowledgement"
    )
    #expect(
      missingAcknowledgementChat.privacySafeErrorCategory ==
        "sync_apply:acknowledgement:missing_entity"
    )
    #expect(
      DurableUpdateApplyError.reducerFailed(kind: "chatOpen", batchIndex: 16)
        .privacySafeErrorCategory == "sync_apply:reducer_failed:chatOpen"
    )
  }

  @Test("a delayed Chat sidecar cannot undo a newer User projection")
  func delayedChatSidecarPreservesUserProjection() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try seedExistingProjection(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: .init(date: 20, seq: 20), in: db)
    }
    var dialog = makeDialog()
    dialog.readMaxID = 9
    dialog.unreadCount = 99
    let result = await apply(sidecars: makeSidecars(dialog: dialog), engine: engine)

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      let dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      expectPreservedUserProjection(dialog)
      #expect(dialog.unreadCount == 2)
      #expect(try cursor(.user, db: db)?.seq == 20)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 8)
    }
  }

  @Test("matching read and Chat frontiers refresh unread counts without replacing User fields")
  func certifiedUnreadCountStillRefreshes() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in try seedExistingProjection(db) }
    var dialog = makeDialog()
    dialog.unreadCount = 4
    let result = await apply(sidecars: makeSidecars(dialog: dialog), engine: engine)

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      let dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      expectPreservedUserProjection(dialog)
      #expect(dialog.unreadCount == 4)
    }
  }

  @Test("uncertified or mismatched Chat snapshots cannot replace unread counts", arguments: CountAdmissionScenario.allCases)
  func rejectsUncertifiedUnreadCount(_ scenario: CountAdmissionScenario) async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in try seedExistingProjection(db) }
    var sidecars = makeSidecars(dialog: makeDialog())
    sidecars.dialogs[0].unreadCount = 99
    switch scenario {
      case .olderChatSequence: sidecars.chats[0].seq = 6
      case .newerChatSequence: sidecars.chats[0].seq = 9
      case .missingChatSequence: sidecars.chats[0].clearSeq()
      case .differentPeer: sidecars.chats[0].peerID = .with { $0.user.userID = 99 }
      case .differentChat: sidecars.dialogs[0].chatID = chatID + 1
      case .missingReadFrontier: sidecars.dialogs[0].clearReadMaxID()
      case .differentReadFrontier: sidecars.dialogs[0].readMaxID = 11
    }
    let result = await apply(sidecars: sidecars, engine: engine)

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      let dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      expectPreservedUserProjection(dialog)
      #expect(dialog.unreadCount == 2)
    }
  }

  @Test(
    "User reducers recheck sidecar counts only at their resulting read and covered Chat frontiers",
    arguments: [10, 20], [7, 8]
  )
  func userReadReducerAdmitsMatchingSidecarCount(
    readMaxID: Int64,
    chatSnapshotSequence: Int32
  ) async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try seedExistingProjection(db)
      var dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      dialog.readInboxMaxId = 0
      dialog.unreadCount = 0
      try dialog.update(db)
    }
    var sidecars = makeSidecars(dialog: makeDialog())
    sidecars.chats[0].seq = chatSnapshotSequence
    var sidecarDialog = sidecars.dialogs[0]
    sidecarDialog.readMaxID = 10
    sidecarDialog.unreadCount = 2
    sidecars.dialogs[0] = sidecarDialog
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .updateReadMaxID(.with {
      $0.peerID = chatPeer()
      $0.readMaxID = readMaxID
      $0.unreadCount = 0
    })
    let result = await engine.applyBatch(
      updates: [update], source: .syncCatchup,
      sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(
        key: .user, state: .init(date: 1, seq: 1), expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      let dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      #expect(dialog.readInboxMaxId == readMaxID)
      #expect(dialog.unreadCount == (readMaxID == 10 && chatSnapshotSequence == 7 ? 2 : 0))
      #expect(dialog.unreadMark == false)
      #expect(dialog.readOutboxMaxId == 12)
      #expect(dialog.archived == true)
      #expect(dialog.pinned == true)
      #expect(dialog.open == true)
      #expect(dialog.order == "owned-order")
      #expect(dialog.pinnedOrder == "owned-pin")
      #expect(dialog.chatListHidden == true)
      #expect(dialog.collapsedMaxId == 5)
      #expect(try cursor(.user, db: db)?.seq == 1)
    }
  }

  @Test("foreign sidecars never replace existing child projections, even with ahead snapshots", arguments: [3, 12])
  func existingChildrenRemainOwnedByTheirBuckets(snapshotSequence: Int32) async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in try seedExistingProjection(db) }
    var sidecars = makeSidecars(dialog: makeDialog())
    sidecars.chats[0].seq = snapshotSequence
    sidecars.spaces[0].seq = snapshotSequence
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(key: .user, state: .init(date: 1, seq: 1))
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      try expectPreservedChildProjections(db)
      #expect(try cursor(.space(id: spaceID), db: db)?.seq == 7)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 7)
    }
  }

  @Test("post-reducer count failure rolls back the User read and cursor together")
  func postReducerCountFailureRollsBackUserPage() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try seedExistingProjection(db)
      var dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      dialog.readInboxMaxId = 0
      dialog.unreadCount = 0
      try dialog.update(db)
      try db.execute(sql: """
        CREATE TRIGGER reject_post_reducer_count BEFORE UPDATE ON dialog
        WHEN NEW.unreadCount = 2
        BEGIN SELECT RAISE(ABORT, 'rejected post-reducer count'); END
        """)
    }
    var sidecarDialog = makeDialog()
    sidecarDialog.unreadCount = 2
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .updateReadMaxID(.with {
      $0.peerID = chatPeer()
      $0.readMaxID = 10
      $0.unreadCount = 0
    })
    var sidecars = makeSidecars(dialog: sidecarDialog)
    sidecars.chats[0].seq = 7
    let result = await engine.applyBatch(
      updates: [update], source: .syncCatchup, sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(
        key: .user, state: .init(date: 1, seq: 1), expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(!result.succeeded)
    #expect(result.committedBucketState == nil)
    try await queue.read { (db: Database) throws in
      let dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      #expect(dialog.readInboxMaxId == 0)
      #expect(dialog.unreadCount == 0)
      #expect(dialog.unreadMark == true)
      #expect(try cursor(.user, db: db) == nil)
    }
  }

  @Test("post-reducer counts never recreate a Dialog removed by the User page")
  func postReducerCountDoesNotResurrectRemovedDialog() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in try seedExistingProjection(db) }
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .userRemovedFromChat(.with { $0.chatID = chatID })
    let result = await engine.applyBatch(
      updates: [update], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .user, state: .init(date: 1, seq: 1), expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db) == nil)
      #expect(try cursor(.user, db: db)?.seq == 1)
    }
  }

  @Test("sidecars still seed missing FK projections without advancing their cursors")
  func pristineDependenciesStillMaterialize() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(key: .user, state: .init(date: 1, seq: 1))
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Space.fetchOne(db, id: spaceID)?.name == "Sidecar space")
      #expect(try Chat.fetchOne(db, id: chatID)?.spaceId == spaceID)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db)?.chatId == chatID)
      #expect(try cursor(.space(id: spaceID), db: db) == nil)
      #expect(try cursor(.chat(peer: chatPeer()), db: db) == nil)
    }
  }

  @Test("a missing child model is never reconstructed behind its retained cursor")
  func cursorOnlyChildrenRejectStaleModels() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: spaceID), state: .init(date: 9, seq: 9), in: db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .chat(peer: chatPeer()), state: .init(date: 9, seq: 9), in: db)
    }
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(key: .user, state: .init(date: 1, seq: 1))
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Space.fetchOne(db, id: spaceID) == nil)
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db) == nil)
      #expect(try cursor(.space(id: spaceID), db: db)?.seq == 9)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 9)
    }
  }

  @Test("a sequenced User chatOpen restores its exact missing dependency closure")
  func chatOpenRestoresCursorOnlyChildProjection() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: spaceID), state: .init(date: 9, seq: 9), in: db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .chat(peer: chatPeer()), state: .init(date: 9, seq: 9), in: db)
    }
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .chatOpen(.with {
      $0.chat = makeChat()
      $0.dialog = makeDialog()
    })

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: .init(date: 1, seq: 1),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Space.fetchOne(db, id: spaceID)?.name == "Sidecar space")
      #expect(try Chat.fetchOne(db, id: chatID)?.spaceId == spaceID)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db)?.chatId == chatID)
      #expect(try cursor(.user, db: db)?.seq == 1)
      #expect(try cursor(.space(id: spaceID), db: db)?.seq == 9)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 9)
    }
  }

  @Test("an embedded User chatOpen can restore a missing home Chat without sidecars")
  func chatOpenEmbeddedSnapshotRestoresHomeChat() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(for: .chat(peer: chatPeer()), state: .init(date: 9, seq: 9), in: db)
    }
    var chat = makeChat()
    chat.clearSpaceID()
    var dialog = makeDialog()
    dialog.clearSpaceID()
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .chatOpen(.with {
      $0.chat = chat
      $0.dialog = dialog
    })

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: .init(date: 1, seq: 1),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID)?.spaceId == nil)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db)?.chatId == chatID)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 9)
      #expect(try cursor(.user, db: db)?.seq == 1)
    }
  }

  @Test("a malformed User chatOpen is accounted atomically and cannot pin later updates")
  func malformedChatOpenAdvancesPastEnvelope() async throws {
    let (queue, engine) = try makeEngine()
    var malformedChat = makeChat()
    malformedChat.peerID = .with { $0.chat.chatID = chatID + 1 }
    malformedChat.acknowledgements.cursors = [.with {
      $0.chatID = chatID
      $0.userID = 42
      $0.maxID = 5
      $0.revision = 1
    }]
    var malformed = InlineProtocol.Update()
    malformed.seq = 1
    malformed.date = 1
    malformed.update = .chatOpen(.with {
      $0.chat = malformedChat
      $0.dialog = makeDialog()
    })
    var removal = InlineProtocol.Update()
    removal.seq = 2
    removal.date = 2
    removal.update = .userRemovedFromChat(.with { $0.chatID = chatID })

    let result = await engine.applyBatch(
      updates: [malformed, removal],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: .init(date: 2, seq: 2),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    #expect(result.appliedCount == 2)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db) == nil)
      #expect(try Acknowledgement
        .filter(Acknowledgement.Columns.chatId == chatID)
        .fetchCount(db) == 0)
      #expect(try cursor(.user, db: db)?.seq == 2)
    }
  }

  @Test("a sequenced User dialog update restores its exact missing projection")
  func dialogUpdateRestoresCursorOnlyProjection() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: spaceID), state: .init(date: 9, seq: 9), in: db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .chat(peer: chatPeer()), state: .init(date: 9, seq: 9), in: db)
    }
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .dialogArchived(.with {
      $0.peerID = chatPeer()
      $0.archived = true
    })

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: .init(date: 1, seq: 1),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID)?.spaceId == spaceID)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db)?.archived == true)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 9)
      #expect(try cursor(.user, db: db)?.seq == 1)
    }
  }

  @Test("a sequenced User access grant restores its missing Chat sidecar")
  func userAccessGrantRestoresCursorOnlyChat() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try Space(from: makeSpace()).save(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .chat(peer: chatPeer()), state: .init(date: 9, seq: 9), in: db)
    }
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .userAddedToChat(.with { $0.chatID = chatID })

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: .init(date: 1, seq: 1),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID)?.spaceId == spaceID)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 9)
      #expect(try cursor(.user, db: db)?.seq == 1)
    }
  }

  @Test("a sequenced User join restores missing Space and membership behind its cursor")
  func joinSpaceRestoresCursorOnlySpace() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try User(id: 42, email: nil, firstName: "Member").save(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: spaceID), state: .init(date: 9, seq: 9), in: db)
    }
    var update = InlineProtocol.Update()
    update.seq = 1
    update.date = 1
    update.update = .joinSpace(.with {
      $0.space = makeSpace()
      $0.member = .with {
        $0.id = 420
        $0.userID = 42
        $0.spaceID = spaceID
        $0.role = .member
        $0.canAccessPublicChats = true
      }
    })

    let result = await engine.applyBatch(
      updates: [update],
      source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .user,
        state: .init(date: 1, seq: 1),
        expectedStartState: .init(date: 0, seq: 0)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Space.fetchOne(db, id: spaceID)?.name == "Sidecar space")
      #expect(try Member.fetchOne(db, id: 420)?.spaceId == spaceID)
      #expect(try cursor(.space(id: spaceID), db: db)?.seq == 9)
      #expect(try cursor(.user, db: db)?.seq == 1)
    }
  }

  @Test("the owning Chat reducer still applies after seed-only sidecars")
  func owningReducerStillUpdatesChat() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in try seedExistingProjection(db) }
    var update = InlineProtocol.Update()
    update.seq = 8
    update.date = 8
    update.update = .chatInfo(.with {
      $0.chatID = chatID
      $0.title = "Owned update"
    })
    let result = await engine.applyBatch(
      updates: [update], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer()), state: .init(date: 8, seq: 8),
        expectedStartState: .init(date: 7, seq: 7)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID)?.title == "Owned update")
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 8)
    }
  }

  @Test("the owning Chat page restores a missing root behind its retained cursor")
  func owningChatPageRestoresCursorOnlyRoot() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try Space(from: makeSpace()).save(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .chat(peer: chatPeer()), state: .init(date: 9, seq: 9), in: db)
    }
    var update = InlineProtocol.Update()
    update.seq = 10
    update.date = 10
    update.update = .chatInfo(.with {
      $0.chatID = chatID
      $0.title = "Owned recovery"
    })

    let result = await engine.applyBatch(
      updates: [update], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer()), state: .init(date: 10, seq: 10),
        expectedStartState: .init(date: 9, seq: 9)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID)?.title == "Owned recovery")
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 10)
    }
  }

  @Test("the owning Space page restores a missing root behind its retained cursor")
  func owningSpacePageRestoresCursorOnlyRoot() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: spaceID), state: .init(date: 9, seq: 9), in: db)
    }
    let memberUser = InlineProtocol.User.with {
      $0.id = 42
      $0.firstName = "Member"
    }
    var update = InlineProtocol.Update()
    update.seq = 10
    update.date = 10
    update.update = .spaceMemberAdd(.with {
      $0.user = memberUser
      $0.member = .with {
        $0.id = 420
        $0.userID = 42
        $0.spaceID = spaceID
        $0.role = .member
        $0.canAccessPublicChats = true
      }
    })
    var sidecars = InlineProtocol.UpdateSidecars()
    sidecars.spaces = [makeSpace()]
    sidecars.users = [memberUser]

    let result = await engine.applyBatch(
      updates: [update], source: .syncCatchup, sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(
        key: .space(id: spaceID), state: .init(date: 10, seq: 10),
        expectedStartState: .init(date: 9, seq: 9)
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Space.fetchOne(db, id: spaceID)?.name == "Sidecar space")
      #expect(try Member.fetchOne(db, id: 420)?.spaceId == spaceID)
      #expect(try cursor(.space(id: spaceID), db: db)?.seq == 10)
    }
  }

  @Test("ordinary User progress permits a delayed missing-child page", arguments: [true, false])
  func userProgressDoesNotInvalidateMissingChild(isChat: Bool) async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { db in
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: .init(date: 11, seq: 11), in: db)
    }
    let key: BucketKey = isChat ? .chat(peer: chatPeer()) : .space(id: spaceID)
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: key, state: .init(date: 8, seq: 8), expectedStartState: .init(date: 0, seq: 0),
        expectedRemovalRevision: 0
      )
    )
    #expect(result.succeeded)
    #expect(result.committedBucketState?.seq == 8)
    #expect(result.failure == nil)
  }

  @Test("Space removal fences an absent child without a User cursor change")
  func spaceRemovalRejectsDelayedChild() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { db in
      // No Chat row existed when the request started. The Space deletion must
      // still invalidate its delayed zero-cursor sidecars.
      try InlineProtocol.UpdateSpaceMemberDelete.with {
        $0.spaceID = spaceID
        $0.userID = 42
      }.apply(db, currentUserID: 42)
    }
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: .init(
        key: .chat(peer: chatPeer()),
        state: .init(date: 8, seq: 8),
        expectedStartState: .init(date: 0, seq: 0),
        expectedRemovalRevision: 0
      )
    )
    #expect(!result.succeeded)
    guard case .removalRevisionChanged? = result.failure else {
      Issue.record("Space removal must invalidate delayed child admission")
      return
    }
    try await queue.read { (db: Database) throws in
      #expect(try cursor(.user, db: db) == nil)
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
    }
  }

  @Test("removal revision rolls back with its transaction and survives regrant")
  func removalRevisionRollbackAndRegrant() async throws {
    let (queue, engine) = try makeEngine()
    try queue.inTransaction { db in
      try deleteChatSyncBucket(db, chatId: chatID)
      return .rollback
    }
    #expect(try await queue.read { try SyncRemovalRevision.read($0) } == 0)
    try await queue.write { db in
      try deleteLocalChatData(db, chatId: chatID)
      try Space(from: makeSpace()).save(db)
      try Chat(from: makeChat()).save(db)
    }
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: .init(
        key: .chat(peer: chatPeer()),
        state: .init(date: 8, seq: 8),
        expectedStartState: .init(date: 0, seq: 0),
        expectedRemovalRevision: 0
      )
    )
    #expect(!result.succeeded)
    guard case .removalRevisionChanged? = result.failure else {
      Issue.record("Regrant must not erase removal evidence")
      return
    }
    #expect(try await queue.read { try cursor(.chat(peer: chatPeer()), db: $0) } == nil)
  }

  @Test("unchanged removal revision still permits a pristine child bootstrap")
  func unchangedUserAdmissionPermitsBootstrap() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer()), state: .init(date: 8, seq: 8), expectedStartState: .init(date: 0, seq: 0),
        expectedRemovalRevision: 0
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) != nil)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 8)
    }
  }

  @Test("User removal prevents an already-requested first Chat page from recreating local access")
  func removalRejectsDelayedFirstPage() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try Space(from: makeSpace()).save(db)
      try Chat(from: makeChat()).save(db)
      try Dialog(from: makeDialog()).save(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: .init(date: 10, seq: 10), in: db)
    }
    // The first Chat request observed seq=0 and User seq=10. Its response is
    // delayed until this sequenced removal commits and leaves no Chat cursor.
    var removal = InlineProtocol.Update()
    removal.seq = 11
    removal.date = 11
    removal.update = .userRemovedFromChat(.with { $0.chatID = chatID })
    let removed = await engine.applyBatch(
      updates: [removal], source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .user, state: .init(date: 11, seq: 11), expectedStartState: .init(date: 10, seq: 10)
      )
    )
    #expect(removed.succeeded)

    let delayed = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer()), state: .init(date: 8, seq: 8), expectedStartState: .init(date: 0, seq: 0),
        expectedRemovalRevision: 0
      )
    )
    #expect(!delayed.succeeded)
    guard case let .removalRevisionChanged(expected, actual)? = delayed.failure else {
      Issue.record("Expected destructive-change conflict")
      return
    }
    #expect(expected == 0)
    #expect(actual > expected)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
      #expect(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db) == nil)
      #expect(try cursor(.chat(peer: chatPeer()), db: db) == nil)
      #expect(try cursor(.user, db: db)?.seq == 11)
    }
  }

  @Test("unrelated User progress does not reject a still-present child")
  func existingChildDoesNotRequireUserCursorCAS() async throws {
    let (queue, engine) = try makeEngine()
    try await queue.write { (db: Database) throws in
      try seedExistingProjection(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: .init(date: 11, seq: 11), in: db)
    }
    let result = await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: makeSidecars(dialog: makeDialog()),
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer()), state: .init(date: 8, seq: 8), expectedStartState: .init(date: 7, seq: 7),
        expectedRemovalRevision: 0
      )
    )

    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      try expectPreservedChildProjections(db)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 8)
    }
  }

  @Test("User chatOpen changes its dialog without replacing an existing Chat")
  func chatOpenPreservesChildProjection() throws {
    let (queue, _) = try makeEngine()
    try queue.write { (db: Database) throws in
      try seedExistingProjection(db)
      var update = InlineProtocol.UpdateChatOpen()
      update.chat = makeChat()
      update.dialog = makeDialog()
      try update.apply(db)

      try expectPreservedChildProjections(db)
      let dialog = try #require(try Dialog.get(peerId: .thread(id: chatID)).fetchOne(db))
      #expect(dialog.open == false)
      #expect(dialog.archived == false)
      #expect(try cursor(.chat(peer: chatPeer()), db: db)?.seq == 7)
    }
  }

  @Test("missing child repair checks destructive changes", arguments: [true, false], [true, false])
  func missingChildRepairRequiresRemovalAdmission(isChat: Bool, userAdvanced: Bool) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let engine = UpdatesEngine(
      database: try AppDatabase(queue), authenticatedUserID: { 42 }, validateAccountMutation: { _ in }
    )
    try await queue.write { (db: Database) throws in
      try User(id: 42, email: nil, firstName: "Member").save(db)
      if isChat { try Space(from: makeSpace()).save(db) }
      _ = try GRDBSyncStorage.advanceBucketState(for: .user, state: .init(date: 11, seq: 11), in: db)
    }
    if userAdvanced {
      try await queue.write { try SyncRemovalRevision.advance($0) }
    }
    let token = AuthAccountMutationToken(generation: 1, userID: 42)
    let committed: BucketState?
    if isChat {
      var snapshot = InlineProtocol.GetChatResult()
      snapshot.chat = makeChat()
      snapshot.dialog = makeDialog()
      committed = await engine.applyChatRepair(ChatRepairSnapshot(
        peer: chatPeer(), chat: snapshot, pinnedMessages: [], targetState: .init(date: 8, seq: 8),
        mutationToken: token, reason: "missing-child-admission",
        expectedRemovalRevision: 0
      ))
    } else {
      var snapshot = InlineProtocol.GetSpaceResult()
      snapshot.space = makeSpace()
      snapshot.membership = .with {
        $0.id = 420
        $0.userID = 42
        $0.spaceID = spaceID
        $0.role = .member
        $0.canAccessPublicChats = true
      }
      committed = await engine.applySpaceRepair(SpaceRepairSnapshot(
        spaceID: spaceID, snapshot: snapshot, targetState: .init(date: 8, seq: 8),
        mutationToken: token, reason: "missing-child-admission",
        expectedRemovalRevision: 0
      ))
    }
    #expect(committed?.seq == (userAdvanced ? nil : 8))
    try await queue.read { (db: Database) throws in
      let childExists = try isChat
        ? Chat.fetchOne(db, id: chatID) != nil
        : Space.fetchOne(db, id: spaceID) != nil
      #expect(childExists == !userAdvanced)
      #expect(try cursor(.user, db: db)?.seq == 11)
    }
  }

  @Test("User joinSpace changes membership without replacing an existing Space")
  func joinSpacePreservesChildProjection() throws {
    let (queue, _) = try makeEngine()
    try queue.write { (db: Database) throws in
      try seedExistingProjection(db)
      try User(id: 42, email: nil, firstName: "Member").save(db)
      var update = InlineProtocol.UpdateJoinSpace()
      update.space = makeSpace()
      update.member = .with {
        $0.id = 420
        $0.userID = 42
        $0.spaceID = spaceID
        $0.role = .member
        $0.canAccessPublicChats = true
      }
      try update.apply(db)

      try expectPreservedChildProjections(db)
      #expect(try Member.fetchOne(db, id: 420)?.spaceId == spaceID)
      #expect(try cursor(.space(id: spaceID), db: db)?.seq == 7)
    }
  }

  @Test("cursor-only repair requires an exact or newer projection snapshot", arguments: [true, false], [8, 9])
  func cursorOnlyRepairDoesNotFalselyComplete(isChat: Bool, cursorSequence: Int64) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let engine = UpdatesEngine(
      database: try AppDatabase(queue), authenticatedUserID: { 42 }, validateAccountMutation: { _ in }
    )
    let key: BucketKey = isChat ? .chat(peer: chatPeer()) : .space(id: spaceID)
    try await queue.write { (db: Database) throws in
      try User(id: 42, email: nil, firstName: "Member").save(db)
      if isChat { try Space(from: makeSpace()).save(db) }
      _ = try GRDBSyncStorage.advanceBucketState(for: key, state: .init(date: cursorSequence, seq: cursorSequence), in: db)
    }
    let token = AuthAccountMutationToken(generation: 1, userID: 42)
    let committed: BucketState?
    if isChat {
      var snapshot = InlineProtocol.GetChatResult()
      snapshot.chat = makeChat()
      snapshot.dialog = makeDialog()
      committed = await engine.applyChatRepair(ChatRepairSnapshot(
        peer: chatPeer(), chat: snapshot, pinnedMessages: [], targetState: .init(date: 8, seq: 8),
        mutationToken: token, reason: "cursor-only-projection",
        expectedRemovalRevision: 0
      ))
    } else {
      var snapshot = InlineProtocol.GetSpaceResult()
      snapshot.space = makeSpace()
      snapshot.membership = .with {
        $0.id = 420
        $0.userID = 42
        $0.spaceID = spaceID
        $0.role = .member
      }
      committed = await engine.applySpaceRepair(SpaceRepairSnapshot(
        spaceID: spaceID, snapshot: snapshot, targetState: .init(date: 8, seq: 8),
        mutationToken: token, reason: "cursor-only-projection",
        expectedRemovalRevision: 0
      ))
    }
    #expect(committed?.seq == (cursorSequence == 8 ? 8 : nil))
    try await queue.read { (db: Database) throws in
      let childExists = try isChat
        ? Chat.fetchOne(db, id: chatID) != nil
        : Space.fetchOne(db, id: spaceID) != nil
      #expect(childExists == (cursorSequence == 8))
      #expect(try cursor(key, db: db)?.seq == cursorSequence)
    }
  }

  @Test("a delayed User join cannot regress newer Space-owned membership access")
  func joinSpacePreservesNewerMembership() throws {
    let (queue, _) = try makeEngine()
    try queue.write { (db: Database) throws in
      try seedExistingProjection(db)
      try User(id: 42, email: nil, firstName: "Member").save(db)
      try Member(
        id: 420, date: .init(timeIntervalSince1970: 9), userId: 42,
        spaceId: spaceID, role: .admin, canAccessPublicChats: false
      ).save(db)
      _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: spaceID), state: .init(date: 9, seq: 9), in: db)
      var update = InlineProtocol.UpdateJoinSpace()
      update.space = makeSpace()
      update.member = .with {
        $0.id = 420
        $0.userID = 42
        $0.spaceID = spaceID
        $0.role = .member
        $0.canAccessPublicChats = true
      }
      try update.apply(db)

      let member = try #require(try Member.fetchOne(db, id: 420))
      #expect(member.role == .admin)
      #expect(member.canAccessPublicChats == false)
      #expect(try cursor(.space(id: spaceID), db: db)?.seq == 9)
    }
  }

  private func makeEngine() throws -> (DatabaseQueue, UpdatesEngine) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    return (queue, UpdatesEngine(database: try AppDatabase(queue)))
  }

  private func seedExistingProjection(_ db: Database) throws {
    var space = Space(from: makeSpace())
    space.name = "Owned space"
    space.memberRosterComplete = true
    try space.save(db)
    var chat = Chat(from: makeChat())
    chat.title = "Owned chat"
    chat.participantRosterComplete = true
    chat.canUpdateInfo = true
    try chat.save(db)
    var dialog = Dialog(from: makeDialog())
    dialog.readInboxMaxId = 10
    dialog.readOutboxMaxId = 12
    dialog.unreadCount = 2
    dialog.archived = true
    dialog.unreadMark = true
    dialog.pinned = true
    dialog.open = true
    dialog.order = "owned-order"
    dialog.pinnedOrder = "owned-pin"
    dialog.chatListHidden = true
    dialog.collapsedMaxId = 5
    try dialog.save(db)
    _ = try GRDBSyncStorage.advanceBucketState(for: .space(id: spaceID), state: .init(date: 7, seq: 7), in: db)
    _ = try GRDBSyncStorage.advanceBucketState(for: .chat(peer: chatPeer()), state: .init(date: 7, seq: 7), in: db)
  }

  private func expectPreservedUserProjection(_ dialog: InlineKit.Dialog) {
    #expect(dialog.readInboxMaxId == 10)
    #expect(dialog.readOutboxMaxId == 12)
    #expect(dialog.archived == true)
    #expect(dialog.unreadMark == true)
    #expect(dialog.pinned == true)
    #expect(dialog.open == true)
    #expect(dialog.order == "owned-order")
    #expect(dialog.pinnedOrder == "owned-pin")
    #expect(dialog.chatListHidden == true)
    #expect(dialog.collapsedMaxId == 5)
  }

  private func expectPreservedChildProjections(_ db: Database) throws {
    let chat = try #require(try Chat.fetchOne(db, id: chatID))
    #expect(chat.title == "Owned chat")
    #expect(chat.canUpdateInfo == true)
    #expect(chat.participantRosterComplete == true)
    let space = try #require(try Space.fetchOne(db, id: spaceID))
    #expect(space.name == "Owned space")
    #expect(space.memberRosterComplete == true)
  }

  private func apply(sidecars: InlineProtocol.UpdateSidecars, engine: UpdatesEngine) async -> UpdateApplyResult {
    await engine.applyBatch(
      updates: [], source: .syncCatchup, sidecars: sidecars,
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: chatPeer()), state: .init(date: 8, seq: 8),
        expectedStartState: .init(date: 7, seq: 7)
      )
    )
  }

  private func makeSidecars(dialog: InlineProtocol.Dialog) -> InlineProtocol.UpdateSidecars {
    .with {
      $0.spaces = [makeSpace()]
      $0.chats = [makeChat()]
      $0.dialogs = [dialog]
    }
  }

  private func makeSpace() -> InlineProtocol.Space {
    .with {
      $0.id = spaceID
      $0.name = "Sidecar space"
      $0.seq = 8
      $0.date = 1
    }
  }

  private func makeChat() -> InlineProtocol.Chat {
    .with {
      $0.id = chatID
      $0.peerID = chatPeer()
      $0.spaceID = spaceID
      $0.title = "Sidecar chat"
      $0.seq = 8
      $0.date = 1
    }
  }

  private func makeDialog() -> InlineProtocol.Dialog {
    .with {
      $0.peer = chatPeer()
      $0.chatID = chatID
      $0.spaceID = spaceID
      $0.readMaxID = 10
      $0.unreadCount = 1
      $0.open = false
      $0.archived = false
      $0.pinned = false
      $0.unreadMark = false
    }
  }

  private func chatPeer() -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatID }
  }

  private func cursor(_ key: BucketKey, db: Database) throws -> DbBucketState? {
    try DbBucketState
      .filter(DbBucketState.Columns.bucketType == key.getBucket() && DbBucketState.Columns.entityId == key.getEntityId())
      .fetchOne(db)
  }

  enum CountAdmissionScenario: CaseIterable, Sendable {
    case olderChatSequence, newerChatSequence, missingChatSequence, differentPeer, differentChat, missingReadFrontier, differentReadFrontier
  }
}
