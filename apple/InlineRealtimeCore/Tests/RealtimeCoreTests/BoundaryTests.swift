import Testing

@testable import RealtimeCore

@Suite struct BoundaryTests {
  @Test func resultAfterDeadlineCannotBecomeSuccessfulApply() throws {
    var s = Scenario()
    try s.open()
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    let late = s.send(.response(rpc, .result("late")), at: 101)
    #expect(dbWork(late) == [.settle(TransactionID(1), .executionUnknown)])
  }

  @Test func responseAtDeadlineWinsIfDeliveredBeforeTimeout() throws {
    var s = Scenario()
    try s.open()
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    #expect(
      dbWork(s.send(.response(rpc, .result("on-time")), at: 100)) == [
        .applyTransaction(TransactionID(1), "on-time")
      ])
  }

  @Test func timeoutAtDeadlineWinsIfDeliveredBeforeResponse() throws {
    var s = Scenario()
    try s.open()
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    #expect(dbWork(s.send(.timeout, at: 100)) == [.settle(TransactionID(1), .executionUnknown)])
    #expect(dbWork(s.send(.response(rpc, .result("late")))).isEmpty)
  }

  @Test func busyTransactionQueueCannotStarveSync() throws {
    var s = Scenario(capacity: 1)
    try s.open()
    let first = try operation(s.queue(1))
    try s.queue(2)
    let load = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    s.send(.databaseFinished(load, .bucketState(position(0))))
    let rpc = try attempt(s.send(.databaseFinished(first, .done)))
    let result = s.send(.response(rpc, .result("ok")))
    #expect(transmissions(result) == [.fetch(BucketID(1), from: 0, through: 2)])
  }

  @Test func mismatchedDatabaseResultDoesNotAcknowledgeOrLoseWork() throws {
    var s = Scenario()
    try s.open()
    let marker = try operation(s.queue(1))
    #expect(transmissions(s.send(.databaseFinished(marker, .committed(position(9))))).isEmpty)
    #expect(transmissions(s.send(.databaseFinished(marker, .done))).count == 1)
  }

  @Test func cancelDuringApplyWaitsForActualOutcome() throws {
    var s = Scenario()
    try s.open()
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    let apply = try operation(s.send(.response(rpc, .result("ok"))))
    #expect(dbWork(s.send(.cancel(TransactionID(1)))).isEmpty)
    let cleanup = try operation(s.send(.databaseFinished(apply, .done)))
    s.send(.databaseFinished(cleanup, .done))
    #expect(s.core.outcome(for: TransactionID(1)) == .applied)
  }

  @Test func directTimeoutHasCorrelatedCompletion() throws {
    var s = Scenario()
    try s.open()
    let rpc = try attempt(s.send(.call("query")))
    #expect(s.send(.timeout, at: 100).contains(.event(.directFinished(rpc, nil))))
  }
  @Test func shutdownDoesNotEquateServerReplyWithSendTaskCompletion() throws {
    var s = Scenario()
    let connection = try s.open()
    let rpc = try attempt(s.send(.call("query")))
    s.send(.response(rpc, .result("ok")))
    s.send(.stop)
    #expect(!s.send(.disconnected(connection)).contains(.event(.drained)))
    #expect(s.core.outstandingSends == 1)
    #expect(s.send(.sendFinished(rpc)).contains(.event(.drained)))
    #expect(s.core.outstandingSends == 0)
  }

}
