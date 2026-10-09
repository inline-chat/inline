import Foundation
@testable import InlineKit
import InlineProtocol
@testable import RealtimeV2
import Testing

private struct FailedHistoryCreationResolver: TransactionBlockerResolver {
  func state(for blocker: TransactionBlocker) async -> TransactionBlockerState { .failed }
}

@Suite("RealtimeV2 transaction execution ordering", .serialized)
struct TransactionExecutionOrderingTests {
  @Test("Reserved thread history waits for creation while unrelated history drains")
  func historyWaitsForReservedCreation() async throws {
    let transactions = Transactions()
    let historyID = await transactions.queue(transaction: GetChatHistoryTransaction(peer: .thread(id: 70)))
    let create = CreateChatTransaction(
      title: nil, emoji: nil, isPublic: false, spaceId: nil, participants: [1], reservedChatId: 70
    )
    let createID = await transactions.queue(transaction: create)
    let unrelatedID = await transactions.queue(transaction: GetChatHistoryTransaction(peer: .user(id: 2)))

    let creation = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(creation.id == createID)
    let unrelated = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(unrelated.id == unrelatedID)
    #expect(await transactions.dequeue() == nil)

    await transactions.satisfy(blockers: create.satisfiedBlockersOnSuccess)
    await transactions.finishExecution(for: creation)
    let history = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(history.id == historyID)
  }

  @Test("History cannot dispatch for a thread whose creation failed")
  func historyFailsWithCreationDependency() async throws {
    let transactions = Transactions(blockerResolver: FailedHistoryCreationResolver())
    let historyID = await transactions.queue(transaction: GetChatHistoryTransaction(peer: .thread(id: 70)))
    guard case let .failed(wrapper)? = await transactions.dequeue() else {
      Issue.record("Expected history to fail its creation dependency")
      return
    }
    #expect(wrapper.id == historyID)
    #expect(!(await transactions.isInQueue(transactionId: historyID)))
  }

  @Test("history invalidation can enter the existing owner while persisted work loads")
  func historySubmissionDuringActivation() async throws {
    let owner = TransactionOwner(accountID: 45, generation: 1)
    let persistence = OrderingPersistence(gateLoad: true)
    let transactions = Transactions(persistenceHandler: persistence)
    let activation = Task { await transactions.activate(owner: owner) }
    await persistence.waitUntilLoadStarts()

    #expect(await transactions.beginHistoryMutationSubmission(owner: owner))
    let submission = Task {
      await transactions.queue(
        transaction: DeleteMessageTransaction(messageIds: [1], peerId: .thread(id: 70), chatId: 70),
        owner: owner
      )
    }
    await persistence.releaseLoad()
    await activation.value
    let mutationID = try #require(await submission.value)
    await transactions.endHistoryMutationSubmission(owner: owner)
    let dispatched = try #require(await readyWrapper(from: transactions.dequeue(owner: owner)))
    #expect(dispatched.id == mutationID)
  }

  @Test("history waits for matching pending and applying mutations while other chats drain")
  func historyDoesNotOvertakeMutation() async throws {
    let owner = TransactionOwner(accountID: 46, generation: 1)
    let transactions = Transactions()
    await transactions.activate(owner: owner)
    await transactions.satisfy(blockers: [.chatCreated(chatId: 70), .chatCreated(chatId: 71)])
    let historyID = try #require(await transactions.queue(
      transaction: GetChatHistoryTransaction(peer: .thread(id: 70)), owner: owner
    ))
    let mutationID = try #require(await transactions.queue(
      transaction: DeleteMessageTransaction(messageIds: [1], peerId: .thread(id: 70), chatId: 70), owner: owner
    ))
    let unrelatedID = try #require(await transactions.queue(
      transaction: GetChatHistoryTransaction(peer: .thread(id: 71)), owner: owner
    ))

    let mutation = try #require(await readyWrapper(from: transactions.dequeue(owner: owner)))
    #expect(mutation.id == mutationID)
    let unrelated = try #require(await readyWrapper(from: transactions.dequeue(owner: owner)))
    #expect(unrelated.id == unrelatedID)
    #expect(await transactions.dequeue(owner: owner) == nil)
    await transactions.running(transactionId: mutationID, rpcMsgId: 12)
    let applying = try #require(await transactions.complete(rpcMsgId: 12, owner: owner))
    #expect(await transactions.dequeue(owner: owner) == nil)
    await transactions.finishExecution(for: applying)
    let history = try #require(await readyWrapper(from: transactions.dequeue(owner: owner)))
    #expect(history.id == historyID)
  }

  @Test("same-key work is serialized while unrelated keys bypass it")
  func serializesOnlyMatchingKeys() async throws {
    let transactions = Transactions()
    let firstID = await transactions.queue(transaction: OrderedMutation(marker: 1, key: "peer-a"))
    let secondID = await transactions.queue(transaction: OrderedMutation(marker: 2, key: "peer-a"))
    let unrelatedID = await transactions.queue(transaction: OrderedMutation(marker: 3, key: "peer-b"))

    let first = try #require(await readyWrapper(from: transactions.dequeue()))
    let unrelated = try #require(await readyWrapper(from: transactions.dequeue()))

    #expect(first.id == firstID)
    #expect(unrelated.id == unrelatedID)
    #expect(await transactions.dequeue() == nil)

    await transactions.finishExecution(for: first)
    let second = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(second.id == secondID)
  }

  @Test("dispatch requeue and cancellation retain lane ownership for the original transaction")
  func requeueRetainsLaneOwnership() async throws {
    let transactions = Transactions()
    let firstID = await transactions.queue(transaction: OrderedMutation(marker: 1, key: "peer-a"))
    _ = await transactions.queue(transaction: OrderedMutation(marker: 2, key: "peer-a"))

    let first = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(first.id == firstID)
    await transactions.requeue(transactionId: firstID)
    await transactions.cancel(transactionId: firstID)

    // Requeue appends the original transaction behind its successor. Lane
    // ownership must make cancellation detach and keep the original as the
    // only eligible same-key item.
    let retried = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(retried.id == firstID)
  }

  @Test("reconnect requeue and cancellation retain ACKed lane ownership")
  func reconnectRequeueRetainsLaneOwnership() async throws {
    let transactions = Transactions()
    let firstID = await transactions.queue(transaction: OrderedMutation(marker: 1, key: "peer-a"))
    _ = await transactions.queue(transaction: OrderedMutation(marker: 2, key: "peer-a"))

    _ = try #require(await readyWrapper(from: transactions.dequeue()))
    await transactions.running(transactionId: firstID, rpcMsgId: 8)
    await transactions.ack(rpcMsgId: 8)
    let dropped = await transactions.requeueAll()
    await transactions.cancel(transactionId: firstID)

    #expect(dropped.isEmpty)
    let retried = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(retried.id == firstID)
  }

  @Test("cancelling an active keyed transaction detaches without releasing its successor")
  func activeCancellationRetainsMutationAndLane() async throws {
    let owner = TransactionOwner(accountID: 41, generation: 1)
    let transactions = Transactions()
    await transactions.activate(owner: owner)

    let firstID = try #require(
      await transactions.queue(transaction: OrderedMutation(marker: 1, key: "peer-a"), owner: owner)
    )
    let secondID = try #require(
      await transactions.queue(transaction: OrderedMutation(marker: 2, key: "peer-a"), owner: owner)
    )
    let first = try #require(await readyWrapper(from: transactions.dequeue()))
    await transactions.running(transactionId: firstID, rpcMsgId: 9)

    await transactions.cancel(transactionId: firstID)

    #expect(await transactions.isInFlight(transactionId: firstID))
    #expect(await transactions.dequeue() == nil)

    let completed = try #require(await transactions.complete(rpcMsgId: 9, owner: owner))
    await transactions.finishExecution(for: completed)
    let second = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(second.id == secondID)
    #expect(first.id == completed.id)
  }

  @Test("retry-after-ACK mutations remain durable until their result")
  func ackRetainsDurableMutationUntilResult() async throws {
    let owner = TransactionOwner(accountID: 42, generation: 1)
    let persistence = OrderingPersistence()
    let transactions = Transactions(persistenceHandler: persistence)
    await transactions.activate(owner: owner)

    let transactionID = try #require(
      await transactions.queue(transaction: OrderedMutation(marker: 1, key: "peer-a"), owner: owner)
    )
    await transactions.waitForPersistence()
    _ = try #require(await readyWrapper(from: transactions.dequeue()))
    await transactions.running(transactionId: transactionID, rpcMsgId: 10)
    await transactions.ack(rpcMsgId: 10)
    await transactions.waitForPersistence()

    #expect(await persistence.contains(transactionID, owner: owner))

    _ = try #require(await transactions.complete(rpcMsgId: 10, owner: owner))
    await transactions.waitForPersistence()
    #expect(await persistence.contains(transactionID, owner: owner) == false)
  }

  @Test("terminal completion releases the lane for its successor")
  func terminalCompletionReleasesLane() async throws {
    let owner = TransactionOwner(accountID: 44, generation: 1)
    let transactions = Transactions()
    await transactions.activate(owner: owner)

    let firstID = try #require(
      await transactions.queue(transaction: OrderedMutation(marker: 1, key: "peer-a"), owner: owner)
    )
    let secondID = try #require(
      await transactions.queue(transaction: OrderedMutation(marker: 2, key: "peer-a"), owner: owner)
    )
    _ = try #require(await readyWrapper(from: transactions.dequeue()))
    await transactions.running(transactionId: firstID, rpcMsgId: 11)
    let terminal = try #require(await transactions.complete(rpcMsgId: 11, owner: owner))

    #expect(await transactions.dequeue() == nil)
    await transactions.finishExecution(for: terminal)
    let second = try #require(await readyWrapper(from: transactions.dequeue()))
    #expect(second.id == secondID)
  }

  @Test("chat mutations share only their conversation lane")
  func chatMutationKeysMatchWithinOneChat() {
    let first = SendMessageTransaction(
      text: "first",
      peerId: .thread(id: 70),
      chatId: 70
    )
    let second = SendMessageTransaction(
      text: "second",
      peerId: .thread(id: 70),
      chatId: 70
    )
    let deletion = DeleteMessageTransaction(
      messageIds: [1],
      peerId: .thread(id: 70),
      chatId: 70
    )
    let unrelated = SendMessageTransaction(
      text: "other",
      peerId: .thread(id: 71),
      chatId: 71
    )

    #expect(first.context.randomId != 0)
    #expect(first.executionKey == second.executionKey)
    #expect(first.executionKey == deletion.executionKey)
    #expect(first.executionKey != unrelated.executionKey)
  }

  private func readyWrapper(from result: TransactionDequeueResult?) -> TransactionWrapper? {
    guard case let .ready(wrapper)? = result else { return nil }
    return wrapper
  }
}

private struct OrderedMutation: Transaction2, Codable {
  struct Context: Sendable, Codable {
    let marker: Int
    let key: String
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var method: InlineProtocol.Method = .UNRECOGNIZED(9_999_981)
  var type: TransactionKindType = .mutation()
  var reconnectReplayPolicy: TransactionReconnectPolicy? {
    .replaySafe
  }

  var context: Context

  init(marker: Int, key: String) {
    context = Context(marker: marker, key: key)
  }

  var executionKey: TransactionExecutionKey? {
    TransactionExecutionKey(namespace: "ordering-test", value: context.key)
  }

  func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    nil
  }

  func apply(_ rpcResult: InlineProtocol.RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {}
}

private actor OrderingPersistence: TransactionPersistenceHandler {
  private var storage: [TransactionOwner: [TransactionWrapper]] = [:]
  private let gateLoad: Bool
  private var loadStarted = false
  private var loadReleased = false
  private var loadArrival: CheckedContinuation<Void, Never>?
  private var loadGate: CheckedContinuation<Void, Never>?

  init(gateLoad: Bool = false) {
    self.gateLoad = gateLoad
  }

  func waitUntilLoadStarts() async {
    if loadStarted {
      return
    }
    await withCheckedContinuation { loadArrival = $0 }
  }

  func releaseLoad() {
    loadReleased = true
    loadGate?.resume()
    loadGate = nil
  }

  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws {
    var transactions = storage[owner] ?? []
    transactions.removeAll { $0.id == transaction.id }
    transactions.append(transaction)
    storage[owner] = transactions
  }

  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws {
    storage[owner]?.removeAll { $0.id == transactionId }
  }

  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper] {
    loadStarted = true
    loadArrival?.resume()
    loadArrival = nil
    if gateLoad, !loadReleased {
      await withCheckedContinuation { loadGate = $0 }
    }
    return storage[owner] ?? []
  }

  func deleteAllTransactions(for owner: TransactionOwner) async throws {
    storage[owner] = nil
  }

  func contains(_ transactionID: TransactionId, owner: TransactionOwner) -> Bool {
    storage[owner]?.contains { $0.id == transactionID } == true
  }
}
