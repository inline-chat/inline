import Foundation
import GRDB
import InlineProtocol
import RealtimeV2
import Testing

@testable import InlineKit

@Suite("Chat bucket repair")
struct ChatRepairReplacementTests {
  @Test("replaces stale chat projections and cursor in one database write")
  func replacesStaleChatBucket() async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let appDatabase = try AppDatabase(queue)
    let engine = UpdatesEngine(database: appDatabase)

    try await queue.write { db in
      try User(
        id: 1,
        email: "repair@example.com",
        firstName: "Repair",
        lastName: nil,
        username: "repair"
      ).insert(db)
      try Chat(
        id: 7,
        date: Date(timeIntervalSince1970: 10),
        type: .thread,
        title: "Stale",
        spaceId: nil,
        lastMsgId: 10
      ).insert(db)
      var stale = Message(
        messageId: 10,
        fromId: 1,
        date: Date(timeIntervalSince1970: 10),
        text: "stale",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7
      )
      try stale.saveMessage(db)
      _ = try GRDBSyncStorage.advanceBucketState(
        for: .chat(peer: chatPeer(7)),
        state: BucketState(date: 10, seq: 1),
        in: db
      )
    }

    let target = BucketState(date: 20, seq: 5)
    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: repairedChatResult(),
      participants: InlineProtocol.GetChatParticipantsResult(),
      history: InlineProtocol.GetChatHistoryResult(),
      targetState: target,
      reason: "test"
    ))

    #expect(committed?.seq == target.seq)
    #expect(committed?.date == target.date)
    try await queue.read { db in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Repaired")
      #expect(try Message.filter(Message.Columns.chatId == 7).fetchCount(db) == 0)
      let state = try #require(try DbBucketState.fetchOne(db))
      #expect(state.seq == 5)
      #expect(state.date == 20)
    }

    try await queue.write { db in
      var newer = Message(
        messageId: 11,
        fromId: 1,
        date: Date(timeIntervalSince1970: 21),
        text: "newer",
        peerUserId: nil,
        peerThreadId: 7,
        chatId: 7
      )
      try newer.saveMessage(db)
    }
    _ = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: chatPeer(7),
      chat: repairedChatResult(),
      participants: InlineProtocol.GetChatParticipantsResult(),
      history: InlineProtocol.GetChatHistoryResult(),
      targetState: target,
      reason: "stale-repeat"
    ))
    try await queue.read { db in
      let preserved = try Message
        .filter(Message.Columns.chatId == 7 && Message.Columns.messageId == 11)
        .fetchOne(db)
      #expect(preserved != nil)
    }
  }

  private func chatPeer(_ chatID: Int64) -> InlineProtocol.Peer {
    .with { $0.chat.chatID = chatID }
  }

  private func repairedChatResult() -> InlineProtocol.GetChatResult {
    let peer = chatPeer(7)
    var chat = InlineProtocol.Chat()
    chat.id = 7
    chat.title = "Repaired"
    chat.peerID = peer

    var dialog = InlineProtocol.Dialog()
    dialog.chatID = 7
    dialog.peer = peer

    var result = InlineProtocol.GetChatResult()
    result.chat = chat
    result.dialog = dialog
    return result
  }
}
