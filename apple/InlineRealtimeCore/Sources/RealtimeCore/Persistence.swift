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
    // Both modes share commit/conflict handling. The actual issued/retried work
    // retains the removal revision for the real transaction-local admission check.
    let interpretedWork: DatabaseWork<Payload>
    if case .applyAdmittedPage(let key, let admission, let page) = pending.work {
      interpretedWork = .applyPage(key, expected: admission.position, page)
    } else {
      interpretedWork = pending.work
    }
    switch (interpretedWork, result) {
    case (.captureBucketAdmission(let key, let expected, let network), .admission(let evidence))
    where evidence.position.sequence >= 0 && evidence.position.date >= 0:
      admissionFinished(key, expected: expected, network: network, evidence: evidence)
    case (.importBootstrapProjection(let kind, _, _), .projection(let receipt))
    where receipt.seeds.allSatisfy({
      $0.key != bootstrap?.user && $0.value.sequence >= 0 && $0.value.date >= 0
    })
      && receipt.targets.allSatisfy({ $0.key != bootstrap?.user && $0.value >= 0 }):
      bootstrap?.pending.removeValue(forKey: .projection(kind))
      bootstrap?.receipts[kind] = receipt
      if bootstrap?.receipts.count == BootstrapProjection.allCases.count {
        bootstrap?.phase = .after
      }
    case (.admitBootstrap(let user, let before, let after, _, _), .committed(let position))
    where position.sequence >= before.sequence && position.date >= before.date:
      ensureBucket(user)
      if position.sequence >= (buckets[user]?.cursor ?? 0) {
        buckets[user]?.cursor = position.sequence
        let date = max(buckets[user]?.date ?? 0, position.date)
        buckets[user]?.date = date
      }
      bootstrap?.phase = .replaying
      demand(user, through: after.sequence)
    case (.admitBootstrap, .conflict):
      // Projections may remain durable, but their admission evidence is obsolete.
      // Start a new P0/projection audit without inventing a baseline or checkpoint.
      if let previous = bootstrap {
        bootstrap = Bootstrap(user: previous.user)
        bootstrap?.discoverAfter = previous.discoverAfter
        bootstrap?.retryAt[.before] = now + configuration.retryDelay
      }
    case (.storeBootstrapCheckpoint(let checkpoint), .done):
      let discoverAfter = bootstrap?.discoverAfter == true
      bootstrap = nil
      output.append(.event(.checkpointStored(checkpoint)))
      output.append(.event(.bootstrapFinished))
      if discoverAfter { discovery = Discovery(after: checkpoint) }
    case (.loadTransactions, .transactions(let snapshot)):
      if !restoreTransactions(snapshot) {
        restorationRejected = true
        output.append(.event(.restorationRejected))
      }
    case (.optimistic(let spec), .done):
      transactions[spec.id]?.phase = .storing
      _ = write(.store(spec))
    case (.store(let spec), .done):
      transactions[spec.id]?.phase = .ready
      if transactions[spec.id]?.cancellationRequested == true { settle(spec.id, .cancelled) }
    case (.markDispatching(let key), .done):
      transactionReservations.remove(key)
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
    where position.sequence >= snapshot.position.sequence && position.date >= snapshot.position.date:
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
