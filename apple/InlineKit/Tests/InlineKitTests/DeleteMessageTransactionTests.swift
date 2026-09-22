import Foundation
import InlineKit
import Testing

@Suite("Bulk message deletion")
struct DeleteMessageTransactionTests {
  @Test("Deferred local deletion survives transaction persistence")
  func deferredDeletionRoundTrip() throws {
    let transaction = DeleteMessageTransaction(
      messageIds: [2, 5, 9], peerId: .thread(id: 12), chatId: 12, deferLocalDeletion: true
    )
    let restored = try JSONDecoder().decode(
      DeleteMessageTransaction.self, from: JSONEncoder().encode(transaction)
    )
    #expect(restored.context.deferLocalDeletion == true)
    #expect(restored.messageIds == [2, 5, 9])
    #expect(restored.peerId == .thread(id: 12))
    #expect(restored.input(from: restored.context) == transaction.input(from: transaction.context))
  }

  @Test("Previously persisted deletions retain optimistic behavior")
  func legacyDeletionRoundTrip() throws {
    let transaction = DeleteMessageTransaction(messageIds: [4], peerId: .thread(id: 12), chatId: 12)
    let encoded = try JSONEncoder().encode(transaction)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let context = try #require(object["context"] as? [String: Any])
    #expect(context["deferLocalDeletion"] == nil)
    let restored = try JSONDecoder().decode(DeleteMessageTransaction.self, from: encoded)
    #expect(restored.context.deferLocalDeletion == nil)
    #expect(restored.messageIds == [4])
  }

  @Test("Waiting for confirmation does not change the delete RPC")
  func sameRPC() {
    let ordinary = DeleteMessageTransaction(messageIds: [2, 5], peerId: .thread(id: 12), chatId: 12)
    let deferred = DeleteMessageTransaction(
      messageIds: [2, 5], peerId: .thread(id: 12), chatId: 12, deferLocalDeletion: true
    )
    #expect(ordinary.input(from: ordinary.context) == deferred.input(from: deferred.context))
    #expect(ordinary.executionKey == deferred.executionKey)
  }
}
