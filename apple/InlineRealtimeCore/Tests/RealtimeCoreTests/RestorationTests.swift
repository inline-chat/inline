import Testing

@testable import RealtimeCore

extension Scenario {
  mutating func restoring() throws -> OperationID {
    let start = send(.start(generation: 1, transactions: .restore))
    let connection = try #require(
      start.compactMap {
        if case .connect(let id) = $0 { id } else { nil }
      }.first)
    _ = try authorize(connection)
    return try operation(start)
  }
}

@Suite struct RestorationTests {
  @Test(arguments: 0..<12)
  func replayAndExpiryUseDurableDispatchEvidence(_ variant: Int) throws {
    var s = Scenario()
    let load = try s.restoring()
    let dispatched = variant % 2 == 0
    let safe = (variant / 2) % 2 == 0
    let age: Int64 = [599, 600, 601][variant / 4]
    let spec = Tx(
      id: TransactionID(1), payload: "persisted", replay: safe ? .replaySafe : .neverReplay)
    let restored = s.send(
      .databaseFinished(
        load,
        .transactions(
          TransactionRestoration(
            records: [
              StoredTransaction(
                spec, dispatch: dispatched ? .mayHaveExecuted : .queued,
                createdAtUnixSeconds: 100)
            ], observedUnixSeconds: 100 + age))))
    let work = dbWork(restored)
    if dispatched && (age >= 600 || !safe) {
      #expect(work == [.settle(spec.id, .executionUnknown)])
    } else if age >= 600 {
      #expect(work == [.settle(spec.id, .failed)])
    } else {
      #expect(work == [.markDispatching(spec.id)])
      #expect(
        transmissions(s.send(.databaseFinished(try operation(restored), .done))) == [
          .transaction(spec.id, "persisted")
        ])
    }
    #expect(!work.contains(.optimistic(spec)))
    #expect(!work.contains(.store(spec)))
    #expect(restored.contains(.event(.transactionsReady)))
  }

  @Test func readFailureCannotOpenTransactionAdmission() throws {
    var s = Scenario()
    let load = try s.restoring()
    s.send(.databaseFinished(load, .failed))
    let spec = Tx(id: TransactionID(1), payload: "new")
    #expect(s.send(.submit(spec)).contains(.event(.submissionRejected(spec.id))))
    let retry = try operation(s.send(.timeout, at: 10))
    #expect(retry != load)
    s.send(
      .databaseFinished(
        load, .transactions(TransactionRestoration(records: [], observedUnixSeconds: 100))))
    #expect(s.core.restoringTransactions)
    s.send(
      .databaseFinished(
        retry, .transactions(TransactionRestoration(records: [], observedUnixSeconds: 100))))
    #expect(dbWork(s.send(.submit(spec))) == [.optimistic(spec)])
  }

  @Test func unknownPredecessorSettlesBeforeDependentFails() throws {
    var s = Scenario()
    let load = try s.restoring()
    let first = Tx(id: TransactionID(1), payload: "unknown", lane: "chat")
    let second = Tx(id: TransactionID(2), payload: "dependent", lane: "chat", requires: [first.id])
    let actions = s.send(
      .databaseFinished(
        load,
        .transactions(
          TransactionRestoration(
            records: [
              StoredTransaction(first, dispatch: .mayHaveExecuted, createdAtUnixSeconds: 100),
              StoredTransaction(second, dispatch: .queued, createdAtUnixSeconds: 101),
            ], observedUnixSeconds: 102))))
    #expect(dbWork(actions) == [.settle(first.id, .executionUnknown)])
    let dependent = s.send(.databaseFinished(try operation(actions), .done))
    #expect(dbWork(dependent) == [.settle(second.id, .dependencyFailed)])
    s.send(.databaseFinished(try operation(dependent), .done))
    #expect(transmissions(s.trace).isEmpty)
    #expect(s.core.transactions.isEmpty)
  }

  @Test func cyclicSnapshotIsAtomicAndCanBeCorrected() throws {
    var s = Scenario()
    let load = try s.restoring()
    let a = Tx(id: TransactionID(1), payload: "a", requires: [TransactionID(2)])
    let b = Tx(id: TransactionID(2), payload: "b", requires: [TransactionID(1)])
    let invalid = s.send(
      .databaseFinished(
        load,
        .transactions(
          TransactionRestoration(
            records: [
              StoredTransaction(a, dispatch: .queued, createdAtUnixSeconds: 1),
              StoredTransaction(b, dispatch: .queued, createdAtUnixSeconds: 2),
            ], observedUnixSeconds: 3))))
    #expect(dbWork(invalid).isEmpty)
    #expect(s.core.transactions.isEmpty)
    #expect(s.core.restoringTransactions)
    let retry = try operation(s.send(.retryRestoration))
    #expect(retry != load)
    let corrected = s.send(
      .databaseFinished(
        retry, .transactions(TransactionRestoration(records: [], observedUnixSeconds: 3))))
    #expect(corrected.contains(.event(.transactionsReady)))
  }
  @Test func clockRollbackDoesNotTurnAValidQueueIntoCorruptStorage() throws {
    var s = Scenario()
    let load = try s.restoring()
    let transaction = Tx(id: TransactionID(1), payload: "future timestamp")
    let restored = s.send(
      .databaseFinished(
        load,
        .transactions(
          TransactionRestoration(
            records: [
              StoredTransaction(transaction, dispatch: .queued, createdAtUnixSeconds: 200)
            ], observedUnixSeconds: 100))))
    #expect(dbWork(restored) == [.markDispatching(transaction.id)])
  }

}
