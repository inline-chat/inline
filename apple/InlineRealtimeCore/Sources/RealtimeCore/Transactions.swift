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
