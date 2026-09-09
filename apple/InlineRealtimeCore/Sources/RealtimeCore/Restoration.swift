/// Empty is an explicit known-empty queue. Restore asks the driver for durable facts.
public enum TransactionStartup: Equatable, Sendable { case empty, restore }
public enum DispatchEvidence: Equatable, Sendable { case queued, mayHaveExecuted }
public struct StoredTransaction<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let transaction: Transaction<Payload>
  public let dispatch: DispatchEvidence
  public let createdAtUnixSeconds: Int64
  public init(
    _ transaction: Transaction<Payload>, dispatch: DispatchEvidence,
    createdAtUnixSeconds: Int64
  ) {
    self.transaction = transaction
    self.dispatch = dispatch
    self.createdAtUnixSeconds = createdAtUnixSeconds
  }
}
/// Deserialization and the wall-clock read belong outside the core. Expiry and
/// replay decisions belong inside. Array order breaks equal creation-time ties.
public struct TransactionRestoration<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let records: [StoredTransaction<Payload>]
  public let settled: [TransactionID: TransactionOutcome]
  public let observedUnixSeconds: Int64
  public let maximumAgeSeconds: Int64
  public init(
    records: [StoredTransaction<Payload>],
    settled: [TransactionID: TransactionOutcome] = [:], observedUnixSeconds: Int64,
    maximumAgeSeconds: Int64 = 600
  ) {
    self.records = records
    self.settled = settled
    self.observedUnixSeconds = observedUnixSeconds
    self.maximumAgeSeconds = maximumAgeSeconds
  }
}

extension RealtimeCore {
  /// Validate the entire graph before admitting any restored operation. A failed
  /// read is never equivalent to an empty queue, nor is missing predecessor evidence.
  mutating func restoreTransactions(_ snapshot: TransactionRestoration<Payload>) -> Bool {
    guard restoringTransactions, snapshot.observedUnixSeconds >= 0,
      snapshot.maximumAgeSeconds > 0
    else { return false }
    let ordered = snapshot.records.enumerated().sorted {
      if $0.element.createdAtUnixSeconds != $1.element.createdAtUnixSeconds {
        return $0.element.createdAtUnixSeconds < $1.element.createdAtUnixSeconds
      }
      return $0.offset < $1.offset
    }.map(\.element)
    var candidate = RealtimeCore(configuration: configuration)
    candidate.finished = snapshot.settled
    let ids = Set(ordered.map { $0.transaction.id })
    guard ids.count == ordered.count, ids.isDisjoint(with: snapshot.settled.keys) else {
      return false
    }
    for record in ordered {
      let spec = record.transaction
      guard record.createdAtUnixSeconds >= 0,
        spec.requires.allSatisfy({ ids.contains($0) || snapshot.settled[$0] != nil }),
        !candidate.introducesCycle(spec)
      else { return false }
      candidate.transactions[spec.id] = PendingTransaction(spec: spec, phase: .ready)
      candidate.submissionOrder.append(spec.id)
    }
    transactions = candidate.transactions
    submissionOrder = candidate.submissionOrder
    finished = candidate.finished
    restoringTransactions = false
    for record in ordered {
      let expired =
        snapshot.observedUnixSeconds - record.createdAtUnixSeconds >= snapshot.maximumAgeSeconds
      if record.dispatch == .mayHaveExecuted
        && (expired || record.transaction.replay == .neverReplay)
      {
        settle(record.transaction.id, .executionUnknown)
      } else if expired {
        settle(record.transaction.id, .failed)
      }
    }
    output.append(.event(.transactionsReady))
    return true
  }
}
