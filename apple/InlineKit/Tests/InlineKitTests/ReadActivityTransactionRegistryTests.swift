import Foundation
import Testing

@testable import InlineKit
import RealtimeV2

@Suite("Read activity transaction persistence")
struct ReadActivityTransactionRegistryTests {
  /// The transaction is a persisted mutation, so an unregistered type made the
  /// loader treat a queued offline "clear mentions" as corrupt and delete it.
  @Test("a queued read-activity survives the persistence round trip")
  func readActivityRoundTrips() throws {
    let transaction = ReadActivityTransaction(
      allIn: .thread(id: 42),
      chatId: 42,
      kinds: [.mention, .reaction],
      maxId: 900
    )
    #expect(TransactionTypeRegistry.typeString(for: transaction) == "read_activity")

    let data = try JSONEncoder().encode(transaction)
    let decoded = try TransactionTypeRegistry.decodeTransaction(type: "read_activity", data: data)
    let restored = try #require(decoded as? ReadActivityTransaction)
    #expect(restored.context.chatId == 42)
    #expect(restored.context.allMentions)
    #expect(restored.context.allReactions)
    #expect(restored.context.maxId == 900)
  }
}
