import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

/// A sync page replays a chat's grant history in order. Removals that the same
/// page later reverses, and grants whose parents are not local, must still let
/// the page and its cursor commit; otherwise the bucket retries forever.
@Suite("Chat access page apply", .serialized)
struct ChatAccessPageApplyTests {
  private let chatID: Int64 = 987_001
  private let userID: Int64 = 987_002
  private let otherUserID: Int64 = 987_004
  private let groupID: Int64 = 987_003

  @Test("complete sidecars let an access grant commit")
  func completeGrantCommits() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [grant(seq: 1)], source: .syncCatchup, sidecars: sidecars(),
      bucketCommit: commit(key: .user, end: 1)
    )
    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try ChatParticipant.fetchCount(db) == 1)
      #expect(try DbBucketState.fetchCount(db) == 1)
    }
  }

  @Test("a removal then regrant in one user page restores the chat and commits")
  func removalThenRegrantCommits() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [removal(seq: 1), grant(seq: 2)], source: .syncCatchup, sidecars: sidecars(),
      bucketCommit: commit(key: .user, end: 2)
    )
    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) != nil)
      #expect(try Dialog.filter(Column("peerThreadId") == chatID).fetchCount(db) == 1)
      #expect(try ChatParticipant.fetchCount(db) == 1)
      #expect(try userCursor(db)?.seq == 2)
    }
  }

  @Test("a grant then removal in one user page leaves the chat removed")
  func grantThenRemovalStaysRemoved() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [grant(seq: 1), removal(seq: 2)], source: .syncCatchup, sidecars: sidecars(),
      bucketCommit: commit(key: .user, end: 2)
    )
    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
      #expect(try ChatParticipant.fetchCount(db) == 0)
      #expect(try userCursor(db)?.seq == 2)
    }
  }

  @Test("an unknown group's removal does not delete a chat before a later participant add")
  func unknownGroupRemovalKeepsChat() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [groupRemoval(seq: 1), participantAdd(seq: 2, user: userID)],
      source: .syncCatchup, sidecars: sidecars(),
      bucketCommit: commit(key: .chat(peer: peer()), end: 2)
    )
    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) != nil)
      #expect(try ChatParticipant.fetchCount(db) == 1)
      #expect(try DbBucketState.fetchCount(db) == 1)
    }
  }

  @Test("a chat page that removes then re-adds the current user keeps the chat")
  func selfRemovalThenReAddKeepsChat() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [
        participantAdd(seq: 1, user: userID),
        participantDelete(seq: 2, user: userID),
        participantAdd(seq: 3, user: userID),
      ],
      source: .syncCatchup, sidecars: sidecars(),
      bucketCommit: commit(key: .chat(peer: peer()), end: 3)
    )
    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) != nil)
      #expect(try ChatParticipant.fetchCount(db) == 1)
      #expect(try DbBucketState.fetchCount(db) == 1)
    }
  }

  @Test("another participant's add never resurrects a chat the current user lost")
  func otherParticipantAddDoesNotResurrectChat() async throws {
    let (queue, engine) = try makeEngine()
    let result = await engine.applyBatch(
      updates: [participantDelete(seq: 1, user: userID), participantAdd(seq: 2, user: otherUserID)],
      source: .syncCatchup, sidecars: sidecars(),
      bucketCommit: commit(key: .chat(peer: peer()), end: 2)
    )
    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: chatID) == nil)
      #expect(try ChatParticipant.fetchCount(db) == 0)
    }
  }

  @Test("a grant for a user that is not local commits and marks the roster incomplete")
  func grantForMissingUserCommits() async throws {
    let (queue, engine) = try makeEngine()
    let seeded = await engine.applyBatch(
      updates: [participantAdd(seq: 1, user: userID)], source: .syncCatchup, sidecars: sidecars(),
      bucketCommit: commit(key: .chat(peer: peer()), end: 1)
    )
    #expect(seeded.succeeded)
    try await queue.write { db in
      try Chat.filter(Chat.Columns.id == chatID)
        .updateAll(db, [Chat.Columns.participantRosterComplete.set(to: true)])
    }

    let result = await engine.applyBatch(
      updates: [participantAdd(seq: 2, user: 987_099)], source: .syncCatchup,
      bucketCommit: UpdateBucketCommit(
        key: .chat(peer: peer()), state: .init(date: 2, seq: 2), expectedStartState: .init(date: 1, seq: 1)
      )
    )
    #expect(result.succeeded)
    try await queue.read { (db: Database) throws in
      #expect(try ChatParticipant.fetchCount(db) == 1)
      #expect(try Chat.fetchOne(db, id: chatID)?.participantRosterComplete == false)
    }
  }

  private func makeEngine() throws -> (DatabaseQueue, UpdatesEngine) {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "chat-access-page"))
    return (queue, UpdatesEngine(
      database: try AppDatabase(queue), authenticatedUserID: { userID },
      validateAccountMutation: { _ in }, applyDeferredEffects: { _ in }
    ))
  }

  private func userCursor(_ db: Database) throws -> DbBucketState? {
    try DbBucketState
      .filter(DbBucketState.Columns.bucketType == BucketKey.user.getBucket())
      .fetchOne(db)
  }

  private func peer() -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatID }
  }

  private func participant(_ id: Int64) -> InlineProtocol.ChatParticipant {
    .with { $0.userID = id; $0.date = 1 }
  }

  private func update(seq: Int32, _ body: InlineProtocol.Update.OneOf_Update) -> InlineProtocol.Update {
    .with { $0.seq = seq; $0.date = Int64(seq); $0.update = body }
  }

  private func grant(seq: Int32) -> InlineProtocol.Update {
    update(seq: seq, .userAddedToChat(.with { $0.chatID = chatID; $0.participant = participant(userID) }))
  }

  private func removal(seq: Int32) -> InlineProtocol.Update {
    update(seq: seq, .userRemovedFromChat(.with { $0.chatID = chatID }))
  }

  private func groupRemoval(seq: Int32) -> InlineProtocol.Update {
    update(seq: seq, .participantGroupDelete(.with { $0.chatID = chatID; $0.groupID = groupID }))
  }

  private func participantAdd(seq: Int32, user: Int64) -> InlineProtocol.Update {
    update(seq: seq, .participantAdd(.with { $0.chatID = chatID; $0.participant = participant(user) }))
  }

  private func participantDelete(seq: Int32, user: Int64) -> InlineProtocol.Update {
    update(seq: seq, .participantDelete(.with { $0.chatID = chatID; $0.userID = user }))
  }

  private func sidecars() -> InlineProtocol.UpdateSidecars {
    .with {
      $0.users = [
        .with { $0.id = userID; $0.firstName = "Synthetic" },
        .with { $0.id = otherUserID; $0.firstName = "Other" },
      ]
      $0.chats = [.with {
        $0.id = chatID
        $0.peerID = peer()
        $0.date = 1
        $0.seq = 3
        $0.isPublic = false
      }]
      $0.dialogs = [.with {
        $0.peer = peer()
        $0.chatID = chatID
      }]
    }
  }

  private func commit(key: BucketKey, end: Int64) -> UpdateBucketCommit {
    .init(key: key, state: .init(date: end, seq: end), expectedStartState: .init(date: 0, seq: 0))
  }
}
