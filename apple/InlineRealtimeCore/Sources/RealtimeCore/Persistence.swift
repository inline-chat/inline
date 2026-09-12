// Tracks issued persistence work; contains no database implementation.

extension RealtimeCore {
  @discardableResult
  mutating func write(_ work: DatabaseWork<Payload>, retryAt: Tick? = nil)
    -> OperationID
  {
    let operation = id()
    database[operation] = PendingDatabase(work: work, retryAt: retryAt)
    if retryAt == nil { output.append(.database(operation, work)) }
    return operation
  }

  mutating func databaseFinished(_ operation: OperationID, _ result: DatabaseResult<Payload>) {
    guard let pending = database[operation], pending.retryAt == nil else { return }
    database.removeValue(forKey: operation)
    guard active, operation.generation == generation else { return }
    // Both modes share commit/conflict handling. The actual issued/retried work
    // retains the removal revision for the real transaction-local admission check.
    let interpretedWork: DatabaseWork<Payload>
    if case .applyAdmittedPage(let key, let admission, let page) = pending.work {
      interpretedWork = .applyPage(key, expected: admission.position, page)
    } else {
      interpretedWork = pending.work
    }
    let accepted: Bool
    switch interpretedWork {
    case .importBootstrapProjection, .admitBootstrap, .storeBootstrapCheckpoint:
      accepted = completeBootstrapWrite(interpretedWork, result)
    case .loadTransactions:
      accepted = completeRestorationWrite(interpretedWork, result)
    case .optimistic, .store, .markDispatching, .applyTransaction, .settle:
      accepted = completeTransactionsWrite(interpretedWork, result)
    case .captureBucketAdmission, .applyAdmittedPage, .loadBucket, .applyPage, .importRepair,
      .finalizeRepair:
      accepted = completeSyncWrite(interpretedWork, result)
    case .storeCheckpoint:
      accepted = completeDiscoveryWrite(interpretedWork, result)
    }
    if accepted { return }
    if result == .failed {
      let replacement = write(pending.work, retryAt: now + configuration.retryDelay)
      switch pending.work {
      case .importBootstrapProjection(let kind, _, _):
        bootstrap?.pending[.projection(kind)] = replacement
      case .captureBucketAdmission(let key, _, _), .applyAdmittedPage(let key, _, _),
        .loadBucket(let key), .applyPage(let key, _, _), .importRepair(let key, _, _),
        .finalizeRepair(let key, _, _, _):
        buckets[key]?.pending = replacement
      case .storeCheckpoint: discovery?.pending = replacement
      default: break
      }
      return
    }
    // The external operation finished even though its receipt is impossible.
    // Never invent a second callback or retry a possibly committed mutation.
    // Close admission and join only genuinely outstanding work; restoration
    // under a new generation must recover from actual durable evidence.
    output.append(.event(.databaseContractViolation(operation)))
    stopAdmission()

  }
}
