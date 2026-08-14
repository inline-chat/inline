import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("GetChats snapshot")
struct GetChatsSnapshotTests {
  private func makeInMemoryDB() throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    return queue
  }

  @Test("snapshot data and bucket cursors roll back together")
  func snapshotRollsBackAtomically() throws {
    let queue = try makeInMemoryDB()
    let result = makeSnapshot(chatSpaceID: 999)

    #expect(throws: (any Error).self) {
      try queue.write { db in
        try GetChatsTransaction.applySnapshot(result, in: db)
      }
    }

    try queue.read { db in
      let savedSpace = try Space.fetchOne(db, key: 1)
      let cursorCount = try DbBucketState.fetchCount(db)
      #expect(savedSpace == nil)
      #expect(cursorCount == 0)
    }
  }

  @Test("snapshot installs resource cursors without regressing newer state")
  func snapshotSeedsMonotonicCursors() throws {
    let queue = try makeInMemoryDB()

    try queue.write { db in
      _ = try GetChatsTransaction.applySnapshot(makeSnapshot(chatSpaceID: 1), in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: .space(id: 1), seq: 6, in: db)
      _ = try GRDBSyncStorage.seedSnapshotBucketState(for: .chat(peer: makeChatPeer()), seq: 8, in: db)

      let cursors = try DbBucketState.fetchAll(db)
      #expect(cursors.count == 2)
      #expect(cursors.first(where: { $0.bucketType == 3 })?.seq == 7)
      #expect(cursors.first(where: { $0.bucketType == 1 })?.seq == 9)
    }
  }

  private func makeSnapshot(chatSpaceID: Int64) -> InlineProtocol.GetChatsResult {
    var space = InlineProtocol.Space()
    space.id = 1
    space.name = "Bootstrap"
    space.date = 100
    space.seq = 7

    var chat = InlineProtocol.Chat()
    chat.id = 2
    chat.title = "Current"
    chat.date = 100
    chat.spaceID = chatSpaceID
    chat.peerID = makeChatPeer()
    chat.seq = 9

    var result = InlineProtocol.GetChatsResult()
    result.spaces = [space]
    result.chats = [chat]
    return result
  }

  private func makeChatPeer() -> InlineProtocol.Peer {
    .with { $0.chat.chatID = 2 }
  }
}
