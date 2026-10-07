@testable import Auth
import Foundation
import GRDB
@testable import InlineKit
import InlineProtocol
import RealtimeV2
import Testing

@Suite("Chat repair history admission")
struct ChatRepairHistoryAdmissionTests {
  @Test(
    "pending intent or changed local revision withholds bodies while committing recovery cursor",
    arguments: ["pending", "changed", "safe"]
  )
  func repairBodyAdmission(mode: String) async throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    let database = try AppDatabase(queue)
    let engine = UpdatesEngine(database: database, authenticatedUserID: { 42 }, validateAccountMutation: { _ in })
    try await queue.write { (db: Database) throws in
      try User(id: 1, email: nil, firstName: "Sender").insert(db)
      try Chat(id: 7, date: Date(), type: .thread, title: "Before", spaceId: nil).insert(db)
      if mode == "changed" {
        try Message.deleteMessages(db, messageIds: [10], chatId: 7)
      }
    }
    let peer = InlineProtocol.Peer.with { $0.chat.chatID = 7 }
    let snapshot = InlineProtocol.GetChatResult.with {
      $0.chat = .with { $0.id = 7
        $0.title = "Repaired"
        $0.peerID = peer
        $0.seq = 5
        $0.lastMsgID = 10
      }
      $0.dialog = .with { $0.chatID = 7
        $0.peer = peer
      }
      $0.messages = [.with {
        $0.id = 10
        $0.chatID = 7
        $0.peerID = peer
        $0.fromID = 1
        $0.date = 1
        $0.rev = 1
        $0.message = "Snapshot body"
      }]
      $0.pinnedMessageIds = [10]
    }
    let committed = await engine.applyChatRepair(ChatRepairSnapshot(
      peer: peer, chat: snapshot, pinnedMessages: snapshot.messages,
      targetState: BucketState(date: 5, seq: 5), mutationToken: AuthAccountMutationToken(generation: 1, userID: 42),
      reason: "history-admission-test", expectedHistoryRevision: 0, allowsHistoryRows: mode != "pending"
    ))
    #expect(committed?.seq == 5)
    try await queue.read { (db: Database) throws in
      #expect(try Chat.fetchOne(db, id: 7)?.title == "Repaired")
      #expect(try Message.fetchCount(db) == (mode == "safe" ? 1 : 0))
      #expect(try PinnedMessage.fetchCount(db) == 1)
      for scope in MessageHistoryScope.allCases {
        #expect(try MessageHistoryCoverageStore.holes(db, chatId: 7, scope: scope) == [
          MessageHistoryHole(chatId: 7, scope: scope, lowerId: 1, upperId: MessageHistoryHole.positiveMessageIDMax),
        ])
      }
    }
  }
}
