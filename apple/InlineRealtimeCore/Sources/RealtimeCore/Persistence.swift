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

  mutating func databaseFinished(_ operation: OperationID, _ result: DatabaseResult) {
    guard let pending = database[operation], pending.retryAt == nil else { return }
    database.removeValue(forKey: operation)
    guard active, operation.generation == generation else { return }
    if result == .failed {
      let replacement = write(pending.work, retryAt: now + configuration.retryDelay)
      switch pending.work {
      case .loadBucket(let key), .applyPage(let key, _, _), .importRepair(let key, _, _),
        .finalizeRepair(let key, _, _, _):
        buckets[key]?.pending = replacement
      case .storeCheckpoint: discovery?.pending = replacement
      default: break
      }
      return
    }
    switch (pending.work, result) {
    case (.optimistic(let spec), .done):
      transactions[spec.id]?.phase = .storing
      _ = write(.store(spec))
    case (.store(let spec), .done):
      transactions[spec.id]?.phase = .ready
      if transactions[spec.id]?.cancellationRequested == true { settle(spec.id, .cancelled) }
    case (.markDispatching(let key), .done):
      guard let transaction = transactions[key] else { return }
      if transaction.cancellationRequested {
        settle(key, .cancelled)
      } else if session.openConnection != nil {
        let attempt = transmit(
          .transaction(key, transaction.spec.payload), owner: .transaction(key))
        transactions[key]?.phase = .requesting(attempt)
      } else {
        transactions[key]?.phase = .ready
      }
    case (.applyTransaction(let key, _), .done): settle(key, .applied)
    case (.settle(let key, let outcome), .done):
      finished[key] = outcome
      transactions.removeValue(forKey: key)
      submissionOrder.removeAll { $0 == key }
      output.append(.event(.transactionFinished(key, outcome)))
    case (.loadBucket(let key), .bucketState(let position))
    where position.sequence >= 0 && position.date >= 0:
      buckets[key]?.pending = nil
      if position.sequence >= (buckets[key]?.cursor ?? 0) {
        buckets[key]?.cursor = position.sequence
        let date = max(buckets[key]?.date ?? 0, position.date)
        buckets[key]?.date = date
      }
    case (.applyPage(let key, let expected, let page), .committed(let position))
    where position.sequence == page.through
      && position.date >= max(expected.date, max(page.date, page.updates.map(\.date).max() ?? 0)):
      buckets[key]?.pending = nil
      if position.sequence >= (buckets[key]?.cursor ?? 0) {
        buckets[key]?.cursor = position.sequence
        let date = max(buckets[key]?.date ?? 0, position.date)
        buckets[key]?.date = date
      }
      let cursor = buckets[key]?.cursor ?? position.sequence
      let buffer = buckets[key]?.buffer.filter { $0.key > cursor } ?? [:]
      buckets[key]?.buffer = buffer
    case (.importRepair(let key, _, let snapshot), .done):
      buckets[key]?.pending = nil
      buckets[key]?.repair?.phase = .waitingForChildren
      for child in snapshot.children.keys.sorted() {
        let target = snapshot.children[child]!
        demand(child, through: target > 0 ? target : nil)
        if target == 0 {
          let latest = buckets[child]?.latest
          buckets[key]?.repair?.requiredLatest[child] = latest
        }
      }
    case (.finalizeRepair(let key, _, let snapshot, _), .committed(let position))
    where position == snapshot.position:
      buckets[key]?.pending = nil
      buckets[key]?.repair = nil
      if position.sequence >= (buckets[key]?.cursor ?? 0) {
        buckets[key]?.cursor = position.sequence
        let date = max(buckets[key]?.date ?? 0, position.date)
        buckets[key]?.date = date
      }
    case (.applyPage(let key, _, _), .conflict), (.importRepair(let key, _, _), .conflict),
      (.finalizeRepair(let key, _, _, _), .conflict):
      buckets[key]?.cursor = nil
      buckets[key]?.date = 0
      buckets[key]?.repair = nil
      let reload = write(.loadBucket(key))
      buckets[key]?.pending = reload
    case (.storeCheckpoint(let checkpoint), .done):
      output.append(.event(.checkpointStored(checkpoint)))
      let again = discovery?.requested == true
      discovery = again ? Discovery(after: checkpoint) : nil
    default:
      // A mismatched result is an adapter contract error, never a successful transition.
      database[operation] = pending
      output.append(.event(.blocked("database result does not match issued work")))
    }
  }
}
