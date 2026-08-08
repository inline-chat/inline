import Foundation
import GRDB
import Testing
@testable import InlineKit

@Suite("Collapsed history marker")
struct CollapsedHistoryMarkerTests {
  private let collapsedAt = Date(timeIntervalSince1970: 1_786_212_000)

  @Test("server messages use the causal ID boundary")
  func serverMessageBoundary() {
    let marker = CollapsedHistoryMarker(maxId: 42, collapsedAt: collapsedAt)

    #expect(marker.contains(messageId: 42, date: collapsedAt.addingTimeInterval(10)))
    #expect(!marker.contains(messageId: 43, date: collapsedAt.addingTimeInterval(-10)))
  }

  @Test("failed and optimistic messages use their local creation time")
  func localMessageBoundary() {
    let marker = CollapsedHistoryMarker(maxId: 42, collapsedAt: collapsedAt)

    #expect(marker.contains(messageId: -100, date: collapsedAt.addingTimeInterval(-1)))
    #expect(!marker.contains(messageId: -101, date: collapsedAt.addingTimeInterval(1)))
  }

  @Test("legacy markers do not hide local messages without a timestamp")
  func legacyMarker() {
    let marker = CollapsedHistoryMarker(maxId: 42, collapsedAt: nil)

    #expect(!marker.contains(messageId: -100, date: collapsedAt))
  }

  @Test("clear cutoff ignores a negative optimistic chat pointer")
  func clearCutoffUsesLargestLocalServerMessage() throws {
    let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
    _ = try AppDatabase(queue)

    try queue.write { db in
      let chatId: Int64 = 9_901
      let userId: Int64 = 9_902
      try User(id: userId, email: "clear@example.com", firstName: "Clear", lastName: nil, username: nil)
        .insert(db)
      try Chat(
        id: chatId,
        date: collapsedAt.addingTimeInterval(-20),
        type: .thread,
        title: "Clear",
        spaceId: nil
      ).insert(db)

      var serverMessage = Message(
        messageId: 42,
        fromId: userId,
        date: collapsedAt.addingTimeInterval(-10),
        text: "sent",
        peerUserId: nil,
        peerThreadId: chatId,
        chatId: chatId,
        status: .sent
      )
      try serverMessage.saveMessage(db)

      var failedMessage = Message(
        messageId: -100,
        fromId: userId,
        date: collapsedAt.addingTimeInterval(-1),
        text: "failed",
        peerUserId: nil,
        peerThreadId: chatId,
        chatId: chatId,
        status: .failed
      )
      try failedMessage.saveMessage(db)
      try Chat.filter(id: chatId).updateAll(db, Chat.Columns.lastMsgId.set(to: -100))

      #expect(try CollapseHistoryTransaction.maxMessageIdForClear(db, chatId: chatId) == 42)
    }
  }
}
