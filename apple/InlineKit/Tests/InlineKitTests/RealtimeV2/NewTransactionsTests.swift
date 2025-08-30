import Testing
import Foundation

@testable import InlineProtocol
@testable import RealtimeV2

@Suite("TransactionTests")
class NewTransactionsTests {
  @Test("returns nil when no transactions in queue")
  func testEmptyQueue() async throws {
    let transactions = Transactions()
    let result = await transactions.dequeue()
    #expect(result == nil)
  }

  @Test("adds to queue and returns in dequeue")
  func testQueueDequeue() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    let result = await transactions.dequeue()
    #expect(result?.id == id)
  }

  @Test("adds to inflight on dequeue")
  func testDequeueInflight() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    let result = await transactions.inFlight.contains { (key: TransactionId, _: TransactionWrapper) in
      key == id
    }
    #expect(result)
  }

  @Test("removes from inflight on complete")
  func testRemoveFromInflightOnComplete() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    _ = await transactions.running(transactionId: id, rpcMsgId: 1)
    await transactions.ack(rpcMsgId: 1)
    let result = await transactions.inFlight.contains { (key: TransactionId, _: TransactionWrapper) in
      key == id
    }
    #expect(!result)
  }

  @Test("requeues transaction from inflight to queue")
  func testRequeue() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    await transactions.requeue(transactionId: id)
    
    let inQueue = await transactions.isInQueue(transactionId: id)
    let inFlight = await transactions.isInFlight(transactionId: id)
    
    #expect(inQueue)
    #expect(!inFlight)
  }

  @Test("maps rpc message id to transaction id")
  func testRpcMapping() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 42)
    
    let mappedId = await transactions.transactionIdFrom(msgId: 42)
    #expect(mappedId == id)
  }

  @Test("completes transaction and removes it completely")
  func testComplete() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 42)
    _ = await transactions.complete(rpcMsgId: 42)
    
    let inQueue = await transactions.isInQueue(transactionId: id)
    let inFlight = await transactions.isInFlight(transactionId: id)
    
    #expect(!inQueue)
    #expect(!inFlight)
  }

  @Test("transaction wrapper generates unique id and date")
  func testTransactionWrapper() {
    let transaction1 = TransactionWrapper(transaction: MockTransaction())
    let transaction2 = TransactionWrapper(transaction: MockTransaction())
    
    #expect(transaction1.id != transaction2.id)
    #expect(transaction1.date <= Date())
  }
}

// MARK: - Helpers

private struct MockTransaction: Transaction, Codable {
  typealias Result = Void
  
  struct Context: Sendable, Codable {
    init() {}
  }
  
  public enum CodingKeys: String, CodingKey {
    case context
  }
  
  var method: InlineProtocol.Method = .UNRECOGNIZED(0)
  var type: TransactionKindType = .query()
  var context: Context = Context()

  init() {}

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    return nil
  }

  /// Apply the result of the query to database
  /// Error propagated to the caller of the query
  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    // Mock implementation that does nothing
  }

  func optimistic() async {}
  func failed(error: TransactionError) async {}
}
