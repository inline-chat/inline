import Collections
import Foundation
import Logger

enum TransactionDequeueResult {
  case ready(TransactionWrapper)
  case failed(TransactionWrapper)
  case expired(TransactionWrapper)
  case capacityLimited(TransactionQueuePressure)
}

struct TransactionQueuePressure: Sendable {
  let queued: Int
  let outstanding: Int
  let oldestQueueAgeMilliseconds: Int
}

enum TransactionAdmissionResult {
  case accepted(superseded: [TransactionWrapper])
  case ownerUnavailable
  case persistenceFailed
}

enum TransactionDispatchPreparationResult: Equatable {
  case prepared
  case ownerUnavailable
  case persistenceUnavailable
}

public struct TransactionOwner: Sendable, Hashable {
  public let accountID: Int64
  public let generation: UInt64

  public init(accountID: Int64, generation: UInt64) {
    self.accountID = accountID
    self.generation = generation
  }
}

actor Transactions {
  /// Transactions that are queued to be run
  var _queue: OrderedDictionary<TransactionId, TransactionWrapper> = [:]

  /// Transactions that have an RPC call in progress
  var inFlight: [TransactionId: TransactionWrapper] = [:]

  /// Transactions that have been sent but not yet completed
  var sent: [TransactionId: TransactionWrapper] = [:]

  /// Make of transport RPC msgId to transactionId
  var transactionRpcMap: [UInt64: TransactionId] = [:]
  private var pendingAckMsgIds: Set<UInt64> = []

  /// Async stream to signal run loop to check the transaction queue
  let queueStream: AsyncStream<Void>
  private let queueContinuation: AsyncStream<Void>.Continuation

  // Private
  private let log = Log.scoped("RealtimeV2.Transactions")
  private let persistenceHandler: TransactionPersistenceHandler?
  private let blockerResolver: (any TransactionBlockerResolver)?
  private var satisfiedBlockers: Set<TransactionBlocker> = []
  private var executionOwners: [TransactionExecutionKey: TransactionId] = [:]
  private var owner: TransactionOwner?
  private var acceptsTransactions = false
  private var activationWaiters: [CheckedContinuation<Bool, Never>] = []
  private var persistenceTail: Task<Void, Never>?
  private var ephemeralExpiryTask: Task<Void, Never>?
  private var ephemeralExpiryDeadline: Date?

  init(
    persistenceHandler: TransactionPersistenceHandler? = nil,
    blockerResolver: (any TransactionBlockerResolver)? = nil
  ) {
    self.persistenceHandler = persistenceHandler
    self.blockerResolver = blockerResolver
    let stream = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    queueStream = stream.stream
    queueContinuation = stream.continuation
  }

  func activate(owner newOwner: TransactionOwner) async {
    if owner == newOwner, acceptsTransactions { return }

    guard owner == nil else {
      log.error("Refusing transaction owner replacement without an explicit reset")
      return
    }

    owner = newOwner
    acceptsTransactions = false
    let loaded = await loadAllFromDisk(owner: newOwner)
    guard owner == newOwner else { return }

    var combined: OrderedDictionary<TransactionId, TransactionWrapper> = [:]
    var uncertain = [TransactionWrapper]()
    for transaction in loaded.sorted(by: { $0.date < $1.date }) {
      if transaction.dispatchPhase == .queued || canReplayAfterReconnect(transaction: transaction) {
        combined[transaction.id] = transaction.withDispatchPhase(.queued)
      } else {
        uncertain.append(transaction)
      }
    }
    for (id, transaction) in _queue {
      combined[id] = transaction
    }
    _queue = combined
    rescheduleEphemeralExpiryTimer()
    acceptsTransactions = true
    resumeActivationWaiters(accepted: true)

    for transaction in uncertain {
      log.warning(
        "Discarding persisted commit-unknown transaction without replay method=\(transaction.transaction.method)"
      )
      await transaction.transaction.commitOutcomeUnknown()
      deleteFromDisk(transactionId: transaction.id)
    }

    queueContinuation.yield(())
  }

  func reset(
    owner expectedOwner: TransactionOwner,
    deletePersisted: Bool,
    invokeCancellationHandlers: Bool = true
  ) async {
    guard owner == expectedOwner else { return }

    acceptsTransactions = false
    owner = nil
    resumeActivationWaiters(accepted: false)

    let wrappers = uniqueTransactions()
    _queue.removeAll()
    cancelEphemeralExpiryTimer()
    inFlight.removeAll()
    sent.removeAll()
    transactionRpcMap.removeAll()
    pendingAckMsgIds.removeAll()
    satisfiedBlockers.removeAll()

    if invokeCancellationHandlers {
      for wrapper in wrappers {
        await wrapper.transaction.cancelled()
      }
    }
    executionOwners.removeAll()

    if deletePersisted {
      scheduleDeleteAll(owner: expectedOwner)
    }
    await flushPersistence()
  }

  func queue(transaction: some Transaction) -> TransactionId {
    let transactionId = TransactionId.generate()
    enqueue(transaction: transaction, transactionId: transactionId)
    queueContinuation.yield(())
    return transactionId
  }

  func queue(transaction: some Transaction, owner expectedOwner: TransactionOwner) async -> TransactionId? {
    let transactionId = TransactionId.generate()
    let result = await enqueue(
      transaction: transaction,
      transactionId: transactionId,
      owner: expectedOwner
    )
    switch result {
    case let .accepted(superseded):
      for wrapper in superseded {
        await wrapper.transaction.cancelled()
      }
    case .ownerUnavailable, .persistenceFailed:
      return nil
    }
    queueContinuation.yield(())
    return transactionId
  }

  /// Queue without notifying the run-loop yet.
  /// Useful when callers must atomically register continuations before execution starts.
  func enqueue(transaction: some Transaction) -> TransactionId {
    let transactionId = TransactionId.generate()
    enqueue(transaction: transaction, transactionId: transactionId)
    return transactionId
  }

  /// Queue without notifying the run-loop yet, using a caller-provided transaction ID.
  /// Useful when the caller must register state keyed by transaction ID before execution starts.
  func enqueue(transaction: some Transaction, transactionId: TransactionId) {
    let wrapper = TransactionWrapper(id: transactionId, date: Date(), transaction: transaction)
    enqueue(wrapper)
  }

  func enqueue(
    transaction: some Transaction,
    transactionId: TransactionId,
    owner expectedOwner: TransactionOwner
  ) async -> TransactionAdmissionResult {
    guard await waitUntilActive(owner: expectedOwner) else { return .ownerUnavailable }
    let wrapper = TransactionWrapper(id: transactionId, date: Date(), transaction: transaction)
    guard await persistBeforeEnqueue(wrapper, owner: expectedOwner) else {
      if acceptsTransactions, owner == expectedOwner {
        return .persistenceFailed
      }
      return .ownerUnavailable
    }
    guard acceptsTransactions, owner == expectedOwner else { return .ownerUnavailable }
    let superseded = supersedeQueuedEphemeralTransactions(with: wrapper)
    enqueue(wrapper, saveToDisk: false)
    return .accepted(superseded: superseded)
  }

  private func enqueue(_ wrapper: TransactionWrapper, saveToDisk shouldSave: Bool = true) {
    let transactionId = wrapper.id

    log.trace("Queuing transaction \(transactionId) method=\(wrapper.transaction.method)")

    // add to queue
    _queue[transactionId] = wrapper
    rescheduleEphemeralExpiryTimer()

    if shouldSave {
      saveToDisk(transaction: wrapper)
    }
  }

  func signalQueue() {
    queueContinuation.yield(())
  }

  /// Dequeue next transaction from the queue and mark it as in-flight.
  func dequeue(maximumOutstanding: Int = .max) async -> TransactionDequeueResult? {
    if let expired = removeFirstExpiredEphemeral() {
      return .expired(expired)
    }

    if outstandingCount >= max(0, maximumOutstanding), let pressure = queuePressure {
      return .capacityLimited(pressure)
    }

    for transactionId in Array(_queue.keys) {
      guard let wrapper = _queue[transactionId] else { continue }

      switch await blockerState(for: wrapper) {
        case .ready:
          guard acquireExecutionKey(for: wrapper) else { continue }
          _queue.removeValue(forKey: transactionId)
          rescheduleEphemeralExpiryTimer()
          inFlight[transactionId] = wrapper
          return .ready(wrapper)
        case .failed:
          _queue.removeValue(forKey: transactionId)
          rescheduleEphemeralExpiryTimer()
          deleteFromDisk(transactionId: transactionId)
          return .failed(wrapper)
        case .blocked:
          continue
      }
    }

    return nil
  }

  func dequeue(
    owner expectedOwner: TransactionOwner,
    maximumOutstanding: Int = .max
  ) async -> TransactionDequeueResult? {
    guard acceptsTransactions, owner == expectedOwner else { return nil }
    if let expired = removeFirstExpiredEphemeral() {
      return .expired(expired)
    }

    if outstandingCount >= max(0, maximumOutstanding), let pressure = queuePressure {
      return .capacityLimited(pressure)
    }

    for transactionId in Array(_queue.keys) {
      guard let wrapper = _queue[transactionId] else { continue }

      let state = await blockerState(for: wrapper)
      guard acceptsTransactions,
            owner == expectedOwner,
            _queue[transactionId]?.id == wrapper.id
      else { return nil }

      switch state {
        case .ready:
          guard acquireExecutionKey(for: wrapper) else { continue }
          _queue.removeValue(forKey: transactionId)
          rescheduleEphemeralExpiryTimer()
          inFlight[transactionId] = wrapper
          return .ready(wrapper)
        case .failed:
          _queue.removeValue(forKey: transactionId)
          rescheduleEphemeralExpiryTimer()
          deleteFromDisk(transactionId: transactionId)
          return .failed(wrapper)
        case .blocked:
          continue
      }
    }

    return nil
  }

  /// Mark a transaction as running, which means it has an RPC call in progress.
  @discardableResult
  func running(transactionId: TransactionId, rpcMsgId: UInt64) -> Bool {
    guard let wrapper = inFlight[transactionId] else {
      // if not found, it means it was already completed or discarded
      return false
    }

    inFlight[transactionId] = wrapper.withDispatchPhase(.mayHaveExecuted)

    // map rpc msgId to transactionId
    transactionRpcMap[rpcMsgId] = transactionId

    // ACK can arrive before `running` registration on fast transports.
    if pendingAckMsgIds.remove(rpcMsgId) != nil {
      ack(transactionId: transactionId)
    }
    return true
  }

  @discardableResult
  func running(
    transactionId: TransactionId,
    rpcMsgId: UInt64,
    owner expectedOwner: TransactionOwner
  ) -> Bool {
    guard acceptsTransactions, owner == expectedOwner else { return false }
    return running(transactionId: transactionId, rpcMsgId: rpcMsgId)
  }

  /// Durably crosses the dispatch boundary before bytes may reach the transport.
  /// Queries and transient mutations update only in-memory state; durable mutations
  /// must flush `mayHaveExecuted` before request ownership is registered.
  func prepareForDispatch(
    transactionId: TransactionId,
    rpcMsgId: UInt64,
    owner expectedOwner: TransactionOwner
  ) async -> TransactionDispatchPreparationResult {
    guard acceptsTransactions, owner == expectedOwner,
          let wrapper = inFlight[transactionId]
    else { return .ownerUnavailable }

    let marked = wrapper.withDispatchPhase(.mayHaveExecuted)
    guard await persistDispatchPhase(marked, owner: expectedOwner) else {
      return .persistenceUnavailable
    }
    guard acceptsTransactions, owner == expectedOwner,
          inFlight[transactionId]?.id == wrapper.id
    else { return .ownerUnavailable }

    inFlight[transactionId] = marked
    transactionRpcMap[rpcMsgId] = transactionId
    if pendingAckMsgIds.remove(rpcMsgId) != nil {
      ack(transactionId: transactionId)
    }
    return .prepared
  }

  /// Acknowledge a transaction by the rpc message ID. It deletes the transaction from the system.
  func ack(rpcMsgId: UInt64) {
    guard let transactionId = transactionRpcMap[rpcMsgId] else {
      // ACK can race ahead of running() registration; keep it pending.
      pendingAckMsgIds.insert(rpcMsgId)
      return
    }

    ack(transactionId: transactionId)
  }

  /// Acknowledge a transaction that has been completed, it moves it to sent queue waiting for the result.
  func ack(transactionId: TransactionId) {
    log.trace("Acknowledging transaction \(transactionId) - moving to sent queue")

    // move to sent
    sent[transactionId] = inFlight[transactionId]

    // remove from in-flight
    _ = inFlight.removeValue(forKey: transactionId)

    // Keep durable mutations through result application. ACK proves receipt, not
    // commit or local application, and process death must retain that distinction.
  }

  /// Complete a transaction by the rpc message ID. Called when a response or error is received.
  /// It deletes the transaction from the system.
  func complete(
    rpcMsgId: UInt64,
    owner expectedOwner: TransactionOwner,
    deletePersisted: Bool = true
  ) -> TransactionWrapper? {
    guard acceptsTransactions, owner == expectedOwner else { return nil }
    guard let transactionId = transactionRpcMap[rpcMsgId] else {
      pendingAckMsgIds.remove(rpcMsgId)
      log.trace("Complete called for unknown rpcMsgId \(rpcMsgId) - transaction already completed or discarded")
      return nil
    }

    log
      .trace(
        "Completing transaction \(transactionId) (rpcMsgId: \(rpcMsgId)) - removing from all queues and deleting from disk"
      )

    // delete from all queues
    let transactionFromInFlight = inFlight.removeValue(forKey: transactionId)
    let transactionFromSent = sent.removeValue(forKey: transactionId)
    _ = _queue.removeValue(forKey: transactionId)
    rescheduleEphemeralExpiryTimer()

    // remove from rpc map
    transactionRpcMap.removeValue(forKey: rpcMsgId)
    pendingAckMsgIds.remove(rpcMsgId)

    if deletePersisted {
      // delete from disk because we no longer need to retry it
      deleteFromDisk(transactionId: transactionId)
    }

    // In case we have missed the ACK, we return the transaction from in-flight
    return transactionFromSent ?? transactionFromInFlight
  }

  /// Requeue a completed transaction after a deterministic RPC error, up to the provided retry cap.
  func retryAfterRpcError(
    _ wrapper: TransactionWrapper,
    owner expectedOwner: TransactionOwner,
    maxRetries: Int,
    signalQueue: Bool = true
  ) -> Bool {
    guard acceptsTransactions, owner == expectedOwner else { return false }
    guard wrapper.rpcErrorRetryCount < maxRetries else {
      deleteFromDisk(transactionId: wrapper.id)
      return false
    }

    let retried = wrapper.incrementingRpcErrorRetryCount()
    _queue[retried.id] = retried
    rescheduleEphemeralExpiryTimer()
    saveToDisk(transaction: retried)

    if signalQueue {
      queueContinuation.yield(())
    }

    return true
  }

  /// Requeue a transaction that needs to be retried
  func requeue(transactionId: TransactionId, signal: Bool = true) {
    guard let wrapper = inFlight[transactionId] else {
      // if not found, it means it was already completed or discarded
      return
    }

    // remove from in-flight
    inFlight.removeValue(forKey: transactionId)
    removeRpcMappings(for: [transactionId])

    // re-add to queue
    _queue[transactionId] = wrapper
    rescheduleEphemeralExpiryTimer()

    if signal {
      queueContinuation.yield(())
    }
  }

  /// Requeue a transaction when the transport definitively rejected the write
  /// before accepting any bytes. This is different from an uncertain
  /// transport failure: the dispatch boundary was persisted defensively, but
  /// `TransportError.notConnected` proves that no request reached the wire.
  func requeueBeforeDispatch(transactionId: TransactionId, signal: Bool = true) {
    guard let wrapper = inFlight.removeValue(forKey: transactionId) else {
      // If not found, it was already completed, requeued, or discarded.
      return
    }

    removeRpcMappings(for: [transactionId])

    // Undo the defensive mayHaveExecuted marker before persisting the retry.
    let queued = wrapper.withDispatchPhase(.queued)
    _queue[transactionId] = queued
    rescheduleEphemeralExpiryTimer()
    saveToDisk(transaction: queued)

    if signal {
      queueContinuation.yield(())
    }
  }

  @discardableResult
  func requeueAll() -> [TransactionWrapper] {
    var requeuedIds = Set<TransactionId>()
    var dropped = [TransactionWrapper]()
    var droppedIds = Set<TransactionId>()

    for (transactionId, wrapper) in inFlight {
      if wrapper.dispatchPhase == .queued || canReplayAfterReconnect(transaction: wrapper) {
        _queue[transactionId] = wrapper.withDispatchPhase(.queued)
        requeuedIds.insert(transactionId)
      } else {
        dropped.append(wrapper)
        droppedIds.insert(transactionId)
      }
    }
    inFlight.removeAll()

    for (transactionId, wrapper) in sent {
      if canReplayAfterReconnect(transaction: wrapper) {
        _queue[transactionId] = wrapper.withDispatchPhase(.queued)
        requeuedIds.insert(transactionId)
      } else {
        dropped.append(wrapper)
        droppedIds.insert(transactionId)
      }
    }
    sent.removeAll()

    removeRpcMappings(for: requeuedIds.union(droppedIds))
    rescheduleEphemeralExpiryTimer()

    guard !requeuedIds.isEmpty else { return dropped }

    queueContinuation.yield(())

    return dropped
  }

  /// Recovers a transport write whose completion is ambiguous. Returns the
  /// transaction only when the caller must fail it as commit-outcome-unknown.
  func recoverAfterUncertainDispatch(transactionId: TransactionId) -> TransactionWrapper? {
    guard let wrapper = inFlight.removeValue(forKey: transactionId) else { return nil }
    removeRpcMappings(for: [transactionId])

    if wrapper.dispatchPhase == .queued || canReplayAfterReconnect(transaction: wrapper) {
      _queue[transactionId] = wrapper.withDispatchPhase(.queued)
      rescheduleEphemeralExpiryTimer()
      queueContinuation.yield(())
      return nil
    }

    // Keep the durable receipt until the owning Realtime actor has awaited the
    // transaction-specific commit-unknown hook. Deleting here would let a
    // process exit lose the only evidence before reconciliation completes.
    return wrapper
  }

  func requeueAll(owner expectedOwner: TransactionOwner) -> [TransactionWrapper]? {
    guard acceptsTransactions, owner == expectedOwner else { return nil }
    return requeueAll()
  }

  // MARK: - Helpers

  func isInFlight(transactionId: TransactionId) -> Bool {
    inFlight[transactionId] != nil
  }

  func isInQueue(transactionId: TransactionId) -> Bool {
    _queue[transactionId] != nil
  }

  func transactionIdFrom(msgId: UInt64) -> TransactionId? {
    transactionRpcMap[msgId]
  }

  /// Called when a transport/session disconnect happens.
  /// RPC message IDs are session-scoped and must not survive reconnect boundaries.
  func connectionLost() -> [TransactionWrapper] {
    transactionRpcMap.removeAll()
    pendingAckMsgIds.removeAll()

    let queuedEphemeral = _queue.filter { $0.value.transaction.ephemeralConfig != nil }
    let inFlightEphemeral = inFlight.filter { $0.value.transaction.ephemeralConfig != nil }
    let sentEphemeral = sent.filter { $0.value.transaction.ephemeralConfig != nil }
    let expired = queuedEphemeral.map(\.value)
      + inFlightEphemeral.map(\.value)
      + sentEphemeral.map(\.value)

    for (transactionId, _) in queuedEphemeral {
      _queue.removeValue(forKey: transactionId)
    }
    rescheduleEphemeralExpiryTimer()
    for (transactionId, _) in inFlightEphemeral {
      inFlight.removeValue(forKey: transactionId)
    }
    for (transactionId, _) in sentEphemeral {
      sent.removeValue(forKey: transactionId)
    }
    for wrapper in expired {
      finishExecution(for: wrapper)
    }
    return expired
  }

  func satisfy(blockers: [TransactionBlocker]) async {
    guard !blockers.isEmpty else { return }
    let previousCount = satisfiedBlockers.count
    satisfiedBlockers.formUnion(blockers)
    guard satisfiedBlockers.count != previousCount else { return }
    queueContinuation.yield(())
  }

  /// Release a serialization lane after its transaction reaches a terminal
  /// result. Dispatch retries and reconnect requeues intentionally do not call
  /// this method.
  func finishExecution(for wrapper: TransactionWrapper) {
    guard let key = wrapper.transaction.executionKey,
          executionOwners[key] == wrapper.id
    else { return }
    executionOwners[key] = nil
    queueContinuation.yield(())
  }

  /// Cancel all transactions that match the predicate from the queue.
  func cancel(where predicate: @Sendable (TransactionWrapper) -> Bool) async {
    let matches = uniqueTransactions().filter(predicate)
    var cancelledAny = false
    for wrapper in matches {
      let transactionId = wrapper.id
      if wrapper.dispatchPhase == .mayHaveExecuted {
        log.trace("Detaching caller from dispatched transaction \(transactionId) after cancellation request")
        continue
      }
      log.trace("Cancelling transaction \(transactionId) method=\(wrapper.transaction.method)")
      _queue.removeValue(forKey: transactionId)
      inFlight.removeValue(forKey: transactionId)
      sent.removeValue(forKey: transactionId)
      removeRpcMappings(for: [transactionId])
      deleteFromDisk(transactionId: transactionId)
      await wrapper.transaction.cancelled()
      finishExecution(for: wrapper)
      cancelledAny = true
    }
    rescheduleEphemeralExpiryTimer()
    if cancelledAny { queueContinuation.yield(()) }
  }

  func cancel(
    where predicate: @Sendable (TransactionWrapper) -> Bool,
    owner expectedOwner: TransactionOwner
  ) async {
    guard acceptsTransactions, owner == expectedOwner else { return }
    let matches = uniqueTransactions().filter(predicate)
    guard acceptsTransactions, owner == expectedOwner else { return }
    var cancelledAny = false
    for wrapper in matches {
      guard acceptsTransactions, owner == expectedOwner else { return }
      let transactionId = wrapper.id
      if wrapper.dispatchPhase == .mayHaveExecuted {
        log.trace("Detaching caller from dispatched transaction \(transactionId) after cancellation request")
        continue
      }
      _queue.removeValue(forKey: transactionId)
      inFlight.removeValue(forKey: transactionId)
      sent.removeValue(forKey: transactionId)
      removeRpcMappings(for: [transactionId])
      deleteFromDisk(transactionId: transactionId)
      await wrapper.transaction.cancelled()
      guard owner == expectedOwner else { return }
      finishExecution(for: wrapper)
      cancelledAny = true
    }
    rescheduleEphemeralExpiryTimer()
    if cancelledAny { queueContinuation.yield(()) }
  }

  func cancel(transactionId: TransactionId) async {
    let candidate = _queue[transactionId] ?? inFlight[transactionId] ?? sent[transactionId]
    if let candidate, candidate.dispatchPhase == .mayHaveExecuted {
      log.trace("Detaching caller from dispatched transaction \(transactionId)")
      return
    }

    let wrapper = _queue.removeValue(forKey: transactionId)
      ?? inFlight.removeValue(forKey: transactionId)
      ?? sent.removeValue(forKey: transactionId)
    guard let wrapper else { return }
    rescheduleEphemeralExpiryTimer()

    removeRpcMappings(for: [transactionId])
    deleteFromDisk(transactionId: transactionId)
    await wrapper.transaction.cancelled()
    finishExecution(for: wrapper)
    queueContinuation.yield(())
  }

  func waitForPersistence() async {
    await flushPersistence()
  }

  func deletePersisted(transactionId: TransactionId, owner expectedOwner: TransactionOwner) {
    guard owner == expectedOwner else { return }
    deleteFromDisk(transactionId: transactionId)
  }

  private func uniqueTransactions() -> [TransactionWrapper] {
    var seen = Set<TransactionId>()
    var wrappers: [TransactionWrapper] = []
    for wrapper in Array(_queue.values) + Array(inFlight.values) + Array(sent.values) {
      if seen.insert(wrapper.id).inserted {
        wrappers.append(wrapper)
      }
    }
    return wrappers
  }

  private func waitUntilActive(owner expectedOwner: TransactionOwner) async -> Bool {
    if acceptsTransactions, owner == expectedOwner { return true }
    guard owner == expectedOwner else { return false }

    return await withCheckedContinuation { continuation in
      activationWaiters.append(continuation)
    }
  }

  private func resumeActivationWaiters(accepted: Bool) {
    let waiters = activationWaiters
    activationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: accepted)
    }
  }

  // MARK: - Private APIs

  private func shouldSaveToDisk(transaction: TransactionWrapper) -> Bool {
    switch transaction.transaction.type {
      case .query:
        false
      case let .mutation(config):
        config.transient ? false : true
      case .ephemeral:
        false
    }
  }

  private func canReplayAfterReconnect(transaction: TransactionWrapper) -> Bool {
    transaction.transaction.effectiveReconnectReplayPolicy == .replaySafe
  }

  private enum BlockerEvaluation {
    case ready
    case blocked
    case failed
  }

  private func blockerState(for wrapper: TransactionWrapper) async -> BlockerEvaluation {
    guard !wrapper.transaction.blockers.isEmpty else { return .ready }

    for blocker in wrapper.transaction.blockers {
      if satisfiedBlockers.contains(blocker) {
        continue
      }

      guard let blockerResolver else {
        return .blocked
      }

      switch await blockerResolver.state(for: blocker) {
        case .satisfied:
          satisfiedBlockers.insert(blocker)
        case .blocked:
          return .blocked
        case .failed:
          return .failed
      }
    }

    return .ready
  }

  private func acquireExecutionKey(for wrapper: TransactionWrapper) -> Bool {
    guard let key = wrapper.transaction.executionKey else { return true }
    if let currentOwner = executionOwners[key] {
      return currentOwner == wrapper.id
    }
    executionOwners[key] = wrapper.id
    return true
  }

  private func ownsExecutionKey(_ wrapper: TransactionWrapper) -> Bool {
    guard let key = wrapper.transaction.executionKey else { return false }
    return executionOwners[key] == wrapper.id
  }

  private var outstandingCount: Int {
    inFlight.count + sent.count
  }

  private var queuePressure: TransactionQueuePressure? {
    guard let oldest = _queue.values.map(\.date).min() else { return nil }
    return TransactionQueuePressure(
      queued: _queue.count,
      outstanding: outstandingCount,
      oldestQueueAgeMilliseconds: max(0, Int(Date().timeIntervalSince(oldest) * 1_000))
    )
  }

  /// Keep one deadline wakeup for the oldest queued ephemeral transaction.
  /// This lets stale work expire even while every durable dispatch slot remains
  /// occupied, without polling or creating one task per queued transaction.
  private func rescheduleEphemeralExpiryTimer() {
    let nextDeadline = _queue.values.compactMap { wrapper -> Date? in
      guard let config = wrapper.transaction.ephemeralConfig else { return nil }
      return wrapper.date.addingTimeInterval(config.maxQueueAge)
    }.min()

    guard nextDeadline != ephemeralExpiryDeadline else { return }
    ephemeralExpiryTask?.cancel()
    ephemeralExpiryTask = nil
    ephemeralExpiryDeadline = nextDeadline

    guard let nextDeadline else { return }
    let delay = max(0, nextDeadline.timeIntervalSinceNow)
    ephemeralExpiryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }
      await self?.ephemeralExpiryReached(deadline: nextDeadline)
    }
  }

  private func cancelEphemeralExpiryTimer() {
    ephemeralExpiryTask?.cancel()
    ephemeralExpiryTask = nil
    ephemeralExpiryDeadline = nil
  }

  private func ephemeralExpiryReached(deadline: Date) {
    guard ephemeralExpiryDeadline == deadline else { return }
    ephemeralExpiryTask = nil
    ephemeralExpiryDeadline = nil
    queueContinuation.yield(())
  }

  private func removeFirstExpiredEphemeral(at now: Date = Date()) -> TransactionWrapper? {
    for (transactionId, wrapper) in Array(_queue) where wrapper.isEphemeralExpired(at: now) {
      _queue.removeValue(forKey: transactionId)
      rescheduleEphemeralExpiryTimer()
      return wrapper
    }
    return nil
  }

  private func supersedeQueuedEphemeralTransactions(
    with replacement: TransactionWrapper
  ) -> [TransactionWrapper] {
    guard replacement.transaction.ephemeralConfig != nil,
          let key = replacement.transaction.ephemeralCoalescingKey
    else { return [] }

    let superseded = _queue.filter { _, candidate in
      candidate.transaction.ephemeralConfig != nil
        && candidate.transaction.method == replacement.transaction.method
        && candidate.transaction.ephemeralCoalescingKey == key
    }
    for (transactionId, _) in superseded {
      _queue.removeValue(forKey: transactionId)
    }
    return superseded.map(\.value)
  }

  private func removeRpcMappings(for transactionIds: Set<TransactionId>) {
    guard !transactionIds.isEmpty else { return }
    transactionRpcMap = transactionRpcMap.filter { _, transactionId in
      !transactionIds.contains(transactionId)
    }
  }

  private func saveToDisk(transaction: TransactionWrapper) {
    guard shouldSaveToDisk(transaction: transaction) else { return }
    guard let owner else { return }

    schedulePersistenceOperation { [transaction, owner, log, persistenceHandler] in
      do {
        if let persistenceHandler {
          log.trace("Saving transaction \(transaction.id) method=\(transaction.transaction.method)")
          try await persistenceHandler.saveTransaction(transaction, for: owner)
          log.trace("Successfully saved transaction \(transaction.id) to disk")
        } else {
          log.trace("No persistence handler available, skipping save for transaction \(transaction.id)")
        }
      } catch {
        log.error("Failed to save transaction \(transaction.id) to disk", error: error)
      }
    }
  }

  private func persistBeforeEnqueue(
    _ transaction: TransactionWrapper,
    owner expectedOwner: TransactionOwner
  ) async -> Bool {
    guard shouldSaveToDisk(transaction: transaction), let persistenceHandler else { return true }

    let previous = persistenceTail
    let operation = Task<Result<Void, any Error>, Never>(priority: .utility) { [log] in
      await previous?.value
      do {
        log.trace("Saving transaction \(transaction.id) before admission method=\(transaction.transaction.method)")
        try await persistenceHandler.saveTransaction(transaction, for: expectedOwner)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    persistenceTail = Task(priority: .utility) {
      _ = await operation.value
    }

    switch await operation.value {
      case .success:
        return true
      case let .failure(error):
        log.error("Failed to save transaction \(transaction.id) before admission", error: error)
        return false
    }
  }

  private func persistDispatchPhase(
    _ transaction: TransactionWrapper,
    owner expectedOwner: TransactionOwner
  ) async -> Bool {
    guard shouldSaveToDisk(transaction: transaction), let persistenceHandler else { return true }

    let previous = persistenceTail
    let operation = Task<Result<Void, any Error>, Never>(priority: .utility) { [log] in
      await previous?.value
      do {
        log.trace("Persisting transaction dispatch boundary \(transaction.id)")
        try await persistenceHandler.saveTransaction(transaction, for: expectedOwner)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    persistenceTail = Task(priority: .utility) {
      _ = await operation.value
    }

    switch await operation.value {
      case .success:
        return true
      case let .failure(error):
        log.error("Failed to persist transaction dispatch boundary \(transaction.id)", error: error)
        return false
    }
  }

  private func deleteFromDisk(transactionId: TransactionId) {
    guard let owner else { return }
    schedulePersistenceOperation { [transactionId, owner, persistenceHandler, log] in
      do {
        if let persistenceHandler {
          log.trace("Deleting transaction \(transactionId) from disk")
          try await persistenceHandler.deleteTransaction(transactionId, for: owner)
          log.trace("Successfully deleted transaction \(transactionId) from disk")
        } else {
          log.trace("No persistence handler available, skipping delete for transaction \(transactionId)")
        }
      } catch {
        // FIXME: distinguish between queries and mutations to avoid showing errors for queries that are not persisted
        // It's safe to ignore this error, the file may not exist, but better to be safe from infinite retries than
        // sorry
        log.trace("Failed to delete transaction \(transactionId) from disk (file may not exist): \(error)")
      }
    }
  }

  private func loadAllFromDisk(owner: TransactionOwner) async -> [TransactionWrapper] {
    do {
      if let persistenceHandler {
        log.trace("Starting to load account-scoped transactions")
        let allTransactions = try await persistenceHandler.loadTransactions(for: owner)
        log.trace("Loaded \(allTransactions.count) raw transactions from disk")

        // Separate valid and expired transactions
        let expirationDate = Date().addingTimeInterval(-10 * 60) // 10 minutes
        var validTransactions: [TransactionWrapper] = []
        var expiredTransactions: [TransactionWrapper] = []

        for transaction in allTransactions {
          if transaction.date < expirationDate {
            log.trace("Transaction \(transaction.id) expired (created: \(transaction.date))")
            expiredTransactions.append(transaction)
          } else {
            validTransactions.append(transaction)
          }
        }

        // An expired record that crossed the dispatch boundary is still not a
        // definitive failure. Preserve the same commit-unknown semantics used
        // for live reconnects; only known-unsent work may time out normally.
        for expiredTransaction in expiredTransactions {
          if expiredTransaction.dispatchPhase == .mayHaveExecuted {
            log.trace("Transaction \(expiredTransaction.id) expired with unknown commit outcome")
            await expiredTransaction.transaction.commitOutcomeUnknown()
          } else {
            log.trace("Transaction \(expiredTransaction.id) expired before dispatch, calling failed()")
            await expiredTransaction.transaction.failed(error: .timeout)
          }

          // Delete expired transaction from disk
          try? await persistenceHandler.deleteTransaction(expiredTransaction.id, for: owner)
        }

        // Sort valid transactions by creation date
        validTransactions.sort { $0.date < $1.date }
        log.trace("Sorted \(validTransactions.count) valid transactions by creation date")

        log.info("Loaded \(validTransactions.count) transactions from disk, expired \(expiredTransactions.count)")
        return validTransactions
      } else {
        log.trace("No persistence handler available, skipping load from disk")
        return []
      }
    } catch {
      log.error("Failed to load transactions from disk", error: error)
      return []
    }
  }

  private func scheduleDeleteAll(owner: TransactionOwner) {
    schedulePersistenceOperation { [owner, persistenceHandler, log] in
      guard let persistenceHandler else { return }
      do {
        try await persistenceHandler.deleteAllTransactions(for: owner)
        log.info("Cleared persisted transactions for the ending account generation")
      } catch {
        log.error("Failed to clear persisted transactions for the ending account generation", error: error)
      }
    }
  }

  private func schedulePersistenceOperation(
    _ operation: @escaping @Sendable () async -> Void
  ) {
    let previous = persistenceTail
    persistenceTail = Task(priority: .utility) {
      await previous?.value
      await operation()
    }
  }

  private func flushPersistence() async {
    let tail = persistenceTail
    await tail?.value
  }
}

// MARK: - Transaction Persistence Protocol

public protocol TransactionPersistenceHandler: Sendable {
  func saveTransaction(_ transaction: TransactionWrapper, for owner: TransactionOwner) async throws
  func deleteTransaction(_ transactionId: TransactionId, for owner: TransactionOwner) async throws
  func loadTransactions(for owner: TransactionOwner) async throws -> [TransactionWrapper]
  func deleteAllTransactions(for owner: TransactionOwner) async throws
}
