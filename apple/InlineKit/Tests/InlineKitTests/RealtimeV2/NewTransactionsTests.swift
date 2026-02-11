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

  @Test("ack moves transaction into sent queue")
  func testAckMovesTransactionIntoSentQueue() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 11)
    await transactions.ack(rpcMsgId: 11)

    let inQueue = await transactions.isInQueue(transactionId: id)
    let inFlight = await transactions.isInFlight(transactionId: id)
    let inSent = await transactions.sent[id] != nil

    #expect(!inQueue)
    #expect(!inFlight)
    #expect(inSent)
  }

  @Test("ack before running registration is applied once running is set")
  func testAckBeforeRunningRegistration() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()

    await transactions.ack(rpcMsgId: 12)
    await transactions.running(transactionId: id, rpcMsgId: 12)

    let inQueue = await transactions.isInQueue(transactionId: id)
    let inFlight = await transactions.isInFlight(transactionId: id)
    let inSent = await transactions.sent[id] != nil

    #expect(!inQueue)
    #expect(!inFlight)
    #expect(inSent)
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

  @Test("requeueAll moves inflight transactions back to queue")
  func testRequeueAllMovesInflightTransactionsBackToQueue() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 22)
    await transactions.requeueAll()

    let inQueue = await transactions.isInQueue(transactionId: id)
    let inFlight = await transactions.isInFlight(transactionId: id)

    #expect(inQueue)
    #expect(!inFlight)
  }

  @Test("requeueAll drops acked sent transactions when retryAfterAck is disabled")
  func testRequeueAllDropsAckedSentTransactionsWhenRetryAfterAckDisabled() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction(type: .mutation(MutationConfig())))
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 33)
    await transactions.ack(rpcMsgId: 33)
    let dropped = await transactions.requeueAll()

    let inQueue = await transactions.isInQueue(transactionId: id)
    let inFlight = await transactions.isInFlight(transactionId: id)
    let inSent = await transactions.sent[id] != nil
    let mappedAfterReconnect = await transactions.transactionIdFrom(msgId: 33)
    let droppedContainsId = dropped.contains { $0.id == id }

    #expect(!inQueue)
    #expect(!inFlight)
    #expect(!inSent)
    #expect(mappedAfterReconnect == nil)
    #expect(droppedContainsId)
  }

  @Test("requeueAll requeues acked sent transactions when retryAfterAck is enabled")
  func testRequeueAllRequeuesAckedSentTransactionsWhenRetryAfterAckEnabled() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(
      transaction: MockTransaction(type: .mutation(MutationConfig(retryAfterAck: true)))
    )
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 44)
    await transactions.ack(rpcMsgId: 44)

    let mappedBeforeReconnect = await transactions.transactionIdFrom(msgId: 44)
    #expect(mappedBeforeReconnect == id)

    let dropped = await transactions.requeueAll()

    let inQueue = await transactions.isInQueue(transactionId: id)
    let inFlight = await transactions.isInFlight(transactionId: id)
    let inSent = await transactions.sent[id] != nil
    let mappedAfterReconnect = await transactions.transactionIdFrom(msgId: 44)

    #expect(inQueue)
    #expect(!inFlight)
    #expect(!inSent)
    #expect(mappedAfterReconnect == nil)
    #expect(dropped.isEmpty)
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

  @Test("connectionLost clears rpc message id mapping")
  func testConnectionLostClearsRpcMapping() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 55)

    let mappedBeforeLoss = await transactions.transactionIdFrom(msgId: 55)
    #expect(mappedBeforeLoss == id)

    await transactions.connectionLost()

    let mappedAfterLoss = await transactions.transactionIdFrom(msgId: 55)
    #expect(mappedAfterLoss == nil)
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

  init(type: TransactionKindType = .query()) {
    self.type = type
  }

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
