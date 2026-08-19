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
    switch result {
      case nil:
        #expect(Bool(true))
      default:
        Issue.record("Expected empty queue to return nil")
    }
  }

  @Test("adds to queue and returns in dequeue")
  func testQueueDequeue() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction())
    let result = await transactions.dequeue()
    if case let .ready(wrapper)? = result {
      #expect(wrapper.id == id)
    } else {
      Issue.record("Expected queued transaction to dequeue as ready")
    }
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

  @Test("pre-dispatch transport rejection restores queued durable state")
  func testRequeueBeforeDispatchRestoresQueuedState() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction(type: .mutation()))
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 23)
    await transactions.requeueBeforeDispatch(transactionId: id)

    guard case let .ready(wrapper)? = await transactions.dequeue() else {
      Issue.record("Expected pre-dispatch rejection to restore the queued transaction")
      return
    }
    #expect(wrapper.id == id)
    #expect(wrapper.dispatchPhase == .queued)
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

  @Test("requeueAll keeps a non-replayable mutation that was dequeued but never attempted")
  func testRequeueAllKeepsUnattemptedMutation() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction(type: .mutation()))
    _ = await transactions.dequeue()

    let dropped = await transactions.requeueAll()

    #expect(await transactions.isInQueue(transactionId: id))
    #expect(dropped.isEmpty)
  }

  @Test("requeueAll fails an attempted non-replayable mutation even when its ACK was lost")
  func testRequeueAllDropsAttemptedUnackedMutation() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction(type: .mutation()))
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 32)

    let dropped = await transactions.requeueAll()

    #expect(await transactions.isInQueue(transactionId: id) == false)
    #expect(dropped.map(\.id) == [id])
    #expect(await transactions.transactionIdFrom(msgId: 32) == nil)
  }

  @Test("requeueAll drops an acked non-replayable mutation")
  func testRequeueAllDropsAckedNonReplayableMutation() async throws {
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

  @Test("requeueAll requeues an acked application-idempotent mutation")
  func testRequeueAllRequeuesAckedApplicationIdempotentMutation() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(
      transaction: MockTransaction(type: .mutation(), reconnectReplayPolicy: .replaySafe)
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

  @Test("requeueAll requeues an ACKed query")
  func testRequeueAllRequeuesAckedQuery() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction(type: .query()))
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 45)
    await transactions.ack(rpcMsgId: 45)

    let dropped = await transactions.requeueAll()

    #expect(await transactions.isInQueue(transactionId: id))
    #expect(dropped.isEmpty)
  }

  @Test("explicit never-replay overrides the query compatibility default")
  func testExplicitNeverReplayOverridesQueryDefault() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(
      transaction: MockTransaction(type: .query(), reconnectReplayPolicy: .neverReplay)
    )
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 451)

    let dropped = await transactions.requeueAll()

    #expect(dropped.map(\.id) == [id])
    #expect(await transactions.isInQueue(transactionId: id) == false)
  }

  @Test("reconnect replay defaults from classification and honors per-transaction overrides")
  func testEffectiveReconnectReplayPolicy() {
    #expect(
      MockTransaction(type: .query()).effectiveReconnectReplayPolicy == .replaySafe
    )
    #expect(
      MockTransaction(type: .mutation()).effectiveReconnectReplayPolicy == .neverReplay
    )
    #expect(
      MockTransaction(type: .mutation(), reconnectReplayPolicy: .replaySafe)
        .effectiveReconnectReplayPolicy == .replaySafe
    )
    #expect(
      MockTransaction(type: .query(), reconnectReplayPolicy: .neverReplay)
        .effectiveReconnectReplayPolicy == .neverReplay
    )
  }

  @Test("connection loss keeps durable attempted state after rpc mappings are cleared")
  func testConnectionLossDoesNotMakeAttemptedMutationLookUnsent() async throws {
    let transactions = Transactions()
    let id = await transactions.queue(transaction: MockTransaction(type: .mutation()))
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 452)

    await transactions.connectionLost()
    let dropped = await transactions.requeueAll()

    #expect(dropped.map(\.id) == [id])
    #expect(await transactions.isInQueue(transactionId: id) == false)
  }

  @Test("uncertain dispatch only requeues application-idempotent work")
  func testRecoverAfterUncertainDispatchUsesSemanticPolicy() async throws {
    let transactions = Transactions()
    let unsafeID = await transactions.queue(transaction: MockTransaction(type: .mutation()))
    let safeID = await transactions.queue(transaction: MockTransaction(
      type: .mutation(),
      reconnectReplayPolicy: .replaySafe
    ))
    _ = await transactions.dequeue()
    _ = await transactions.dequeue()
    await transactions.running(transactionId: unsafeID, rpcMsgId: 46)
    await transactions.running(transactionId: safeID, rpcMsgId: 47)

    let unresolved = await transactions.recoverAfterUncertainDispatch(transactionId: unsafeID)
    let replayed = await transactions.recoverAfterUncertainDispatch(transactionId: safeID)

    #expect(unresolved?.id == unsafeID)
    #expect(replayed == nil)
    #expect(await transactions.isInQueue(transactionId: safeID))
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
    let owner = TransactionOwner(accountID: 1, generation: 1)
    await transactions.activate(owner: owner)
    let queuedID = await transactions.queue(transaction: MockTransaction(), owner: owner)
    let id = try #require(queuedID)
    _ = await transactions.dequeue()
    await transactions.running(transactionId: id, rpcMsgId: 42)
    _ = await transactions.complete(rpcMsgId: 42, owner: owner)

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

  @Test("dequeue skips blocked transactions and runs later ready work")
  func testDequeueSkipsBlockedTransactions() async throws {
    let resolver = MockBlockerResolver()
    let transactions = Transactions(blockerResolver: resolver)

    let blockedID = await transactions.queue(
      transaction: BlockedTransaction(blockers: [.chatCreated(chatId: 1)])
    )
    let readyID = await transactions.queue(transaction: MockTransaction())

    let first = await transactions.dequeue()
    if case let .ready(wrapper)? = first {
      #expect(wrapper.id == readyID)
    } else {
      Issue.record("Expected ready transaction to bypass blocked head-of-line work")
    }

    let blockedStillQueued = await transactions.isInQueue(transactionId: blockedID)
    #expect(blockedStillQueued)
  }

  @Test("dequeue returns failed for transactions with failed blockers")
  func testDequeueFailsTransactionsWithFailedBlockers() async throws {
    let resolver = MockBlockerResolver()
    await resolver.setState(.failed, for: .chatCreated(chatId: 9))

    let transactions = Transactions(blockerResolver: resolver)
    let id = await transactions.queue(
      transaction: BlockedTransaction(blockers: [.chatCreated(chatId: 9)])
    )

    let result = await transactions.dequeue()
    if case let .failed(wrapper)? = result {
      #expect(wrapper.id == id)
    } else {
      Issue.record("Expected failed blocker to drop queued transaction")
    }

    let stillQueued = await transactions.isInQueue(transactionId: id)
    #expect(!stillQueued)
  }

  @Test("satisfied blockers unblock queued transactions")
  func testSatisfiedBlockersUnblockQueuedTransactions() async throws {
    let resolver = MockBlockerResolver()
    let transactions = Transactions(blockerResolver: resolver)
    let blocker = TransactionBlocker.chatCreated(chatId: 7)
    let id = await transactions.queue(transaction: BlockedTransaction(blockers: [blocker]))

    let initial = await transactions.dequeue()
    switch initial {
      case nil:
        #expect(Bool(true))
      default:
        Issue.record("Expected blocked transaction to stay queued")
    }

    await transactions.satisfy(blockers: [blocker])

    let result = await transactions.dequeue()
    if case let .ready(wrapper)? = result {
      #expect(wrapper.id == id)
    } else {
      Issue.record("Expected satisfied blocker to release queued transaction")
    }
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
  var reconnectReplayPolicy: TransactionReconnectPolicy?

  init(
    type: TransactionKindType = .query(),
    reconnectReplayPolicy: TransactionReconnectPolicy? = nil
  ) {
    self.type = type
    self.reconnectReplayPolicy = reconnectReplayPolicy
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

private actor MockBlockerResolver: TransactionBlockerResolver {
  private var states: [TransactionBlocker: TransactionBlockerState] = [:]

  func setState(_ state: TransactionBlockerState, for blocker: TransactionBlocker) {
    states[blocker] = state
  }

  func state(for blocker: TransactionBlocker) async -> TransactionBlockerState {
    states[blocker] ?? .blocked
  }
}

private struct BlockedTransaction: Transaction, Codable {
  struct Context: Sendable, Codable {
    let blockers: [TransactionBlocker]
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = .UNRECOGNIZED(0)
  var type: TransactionKindType = .query()
  var context: Context

  init(blockers: [TransactionBlocker]) {
    context = Context(blockers: blockers)
  }

  var blockers: [TransactionBlocker] {
    context.blockers
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}
