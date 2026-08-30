import Foundation
import GRDB
import Testing

@testable import InlineKit

@Suite("Around-target history cache admission")
struct MessageHistoryAroundTests {
  @Test("a missing target or chat needs history even when an interval is covered")
  func missingTarget() throws {
    let queue = try makeDatabase(ids: [59, 61])
    try queue.write { db in
      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 1, upperId: 120)
      #expect(try needsHistory(db, anchor: 60))
      let missingChat = try MessageHistoryRepairCoordinator.aroundCache(db, chat: nil, anchorID: 60, limit: 60)
      #expect(!missingChat.hasTarget && missingChat.needsHistory)
    }
  }

  @Test("cached message rows alone do not establish surrounding history")
  func sparseOrUncertifiedRows() throws {
    for ids in [[60], Array(30 ... 89).map(Int64.init)] {
      let queue = try makeDatabase(ids: ids)
      let requiresHistory = try queue.read { db in try needsHistory(db, anchor: 60) }
      #expect(requiresHistory)
    }
  }

  @Test("a complete certified window stays local")
  func coveredWindow() throws {
    let queue = try makeDatabase(ids: Array(30 ... 89).map(Int64.init))
    try queue.write { db in
      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 30, upperId: 89)
      #expect(try needsHistory(db, anchor: 60) == false)
    }
  }

  @Test("a hole inside cached neighboring rows requires repair")
  func internalHole() throws {
    let queue = try makeDatabase(ids: Array(30 ... 89).map(Int64.init))
    try queue.write { db in
      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 30, upperId: 54)
      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 57, upperId: 89)
      #expect(try needsHistory(db, anchor: 60))
    }
  }

  @Test("short cached sides cannot hide missing context")
  func incompleteSides() throws {
    let queue = try makeDatabase(ids: Array(50 ... 70).map(Int64.init))
    try queue.write { db in
      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 50, upperId: 70)
      #expect(try needsHistory(db, anchor: 60))
    }
  }

  @Test("a fully covered short conversation needs no additional request")
  func shortConversation() throws {
    let queue = try makeDatabase(ids: [1, 2, 3, 4, 5], lastMessageID: 5)
    try queue.write { db in
      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 1, upperId: 5)
      #expect(try needsHistory(db, anchor: 3) == false)
    }
  }

  @Test("cached newer rows remain part of the window when chat metadata lags")
  func staleChatTail() throws {
    let queue = try makeDatabase(ids: Array(1 ... 60).map(Int64.init) + [70], lastMessageID: 60)
    try queue.write { db in
      try MessageHistoryCoverageStore.subtract(db, chatId: 7, lowerId: 1, upperId: 60)
      #expect(try needsHistory(db, anchor: 60))
    }
  }

  private func needsHistory(_ db: Database, anchor: Int64) throws -> Bool {
    try MessageHistoryRepairCoordinator.aroundCache(
      db,
      chat: Chat.fetchOne(db, id: 7),
      anchorID: anchor,
      limit: 60
    ).needsHistory
  }

  private func makeDatabase(ids: [Int64], lastMessageID: Int64 = 120) throws -> DatabaseQueue {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)
    try queue.write { db in
      try User(id: 1, email: "around@example.com", firstName: "Around").insert(db)
      try Chat(id: 7, date: Date(timeIntervalSince1970: 1), type: .thread, title: "Around", spaceId: nil,
               lastMsgId: lastMessageID).insert(db)
      // Chat.lastMsgId is a deferred foreign key to a real message row.
      for id in Set(ids + [lastMessageID]).sorted() {
        var message = Message(messageId: id, fromId: 1, date: Date(timeIntervalSince1970: Double(id)), text: "Message",
                              peerUserId: nil, peerThreadId: 7, chatId: 7)
        try message.saveMessage(db)
      }
    }
    return queue
  }
}
