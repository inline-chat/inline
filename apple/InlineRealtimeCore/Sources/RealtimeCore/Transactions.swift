enum TransactionPhase: Equatable, Sendable {
  case optimistic, storing, ready, marking
  case requesting(OperationID)
  case applying
  case settling(TransactionOutcome)
}
struct PendingTransaction<Payload: Equatable & Sendable>: Sendable {
  let spec: Transaction<Payload>
  var phase: TransactionPhase = .optimistic
  var ownsLane = false
  var retryAt: Tick?
  var cancellationRequested = false
}

extension RealtimeCore {
  mutating func settle(_ id: TransactionID, _ outcome: TransactionOutcome) {
    guard let transaction = transactions[id] else { return }
    if case .settling = transaction.phase { return }
    transactions[id]?.phase = .settling(outcome)
    transactions[id]?.retryAt = nil
    _ = write(.settle(id, outcome))
  }

  func introducesCycle(_ spec: Transaction<Payload>) -> Bool {
    var visiting = Array(spec.requires)
    // FIFO lanes add implicit dependency edges. Include them in cycle detection.
    if let lane = spec.lane,
      let predecessor = submissionOrder.last(where: { transactions[$0]?.spec.lane == lane })
    {
      visiting.append(predecessor)
    }
    var seen: Set<TransactionID> = []
    while let next = visiting.popLast() {
      if next == spec.id { return true }
      if seen.insert(next).inserted, let dependency = transactions[next] {
        visiting.append(contentsOf: dependency.spec.requires)
        if let lane = dependency.spec.lane,
          let predecessor = submissionOrder.prefix(while: { $0 != next }).last(where: {
            transactions[$0]?.spec.lane == lane
          })
        {
          visiting.append(predecessor)
        }
      }
    }
    return false
  }
}

// Durable receipts advance this workflow only after its own contract accepts them.
extension RealtimeCore {
  mutating func completeTransactionsWrite(
    _ work: DatabaseWork<Payload>, _ result: DatabaseResult<Payload>
  ) -> Bool {
    switch (work, result) {
    case (.optimistic(let spec), .done):
      transactions[spec.id]?.phase = .storing
      _ = write(.store(spec))
    case (.store(let spec), .done):
      transactions[spec.id]?.phase = .ready
      if transactions[spec.id]?.cancellationRequested == true { settle(spec.id, .cancelled) }
    case (.markDispatching(let key), .done):
      transactionReservations.remove(key)
      guard let transaction = transactions[key] else { return false }
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
    default: return false
    }
    return true
  }
}
