import Testing

@testable import RealtimeCore

@Suite struct WorkflowTests {
  @Test func offlineSendRequiresAuthorizationAndBothDurableGates() throws {
    var s = Scenario()
    let start = s.send(.start(generation: 1))
    let connection = try #require(
      start.compactMap { if case .connect(let id) = $0 { id } else { nil } }.first)
    #expect(try s.queue(1).allSatisfy { if case .transmit = $0 { false } else { true } })
    let marker = try operation(s.authorize(connection))
    #expect(s.core.outstandingRequests == 0)
    let sent = s.send(.databaseFinished(marker, .done))
    let rpc = try attempt(sent)
    #expect(transmissions(sent) == [.transaction(TransactionID(1), "message-1")])
    let apply = try operation(s.send(.response(rpc, .result("server-message"))))
    #expect(s.core.outcome(for: TransactionID(1)) == nil)
    let cleanup = try operation(s.send(.databaseFinished(apply, .done)))
    #expect(s.core.outcome(for: TransactionID(1)) == nil)
    #expect(
      s.send(.databaseFinished(cleanup, .done)).contains(
        .event(.transactionFinished(TransactionID(1), .applied))))
  }

  @Test func sameLaneWaitsThroughApplicationButOtherLaneProceeds() throws {
    var s = Scenario(capacity: 2)
    try s.open()
    let marker = try operation(s.queue(10, lane: "chat"))
    let first = try attempt(s.send(.databaseFinished(marker, .done)))
    #expect(dbWork(try s.queue(2, lane: "chat")).isEmpty)
    let other = try operation(s.queue(3, lane: "other"))
    #expect(
      dbWork(s.send(.response(first, .result("ok")))) == [
        .applyTransaction(TransactionID(10), "ok")
      ])
    #expect(
      transmissions(s.send(.databaseFinished(other, .done))) == [
        .transaction(TransactionID(3), "message-3")
      ])
    let apply = try #require(
      s.core.database.first { if case .applyTransaction = $0.value.work { true } else { false } }?
        .key)
    let cleanup = try operation(s.send(.databaseFinished(apply, .done)))
    let next = s.send(.databaseFinished(cleanup, .done))
    #expect(dbWork(next) == [.markDispatching(TransactionID(2))])
  }

  @Test func blockedChildIsReleasedOnlyAfterParentSettlement() throws {
    var s = Scenario()
    try s.open()
    #expect(dbWork(try s.queue(2, requires: [TransactionID(1)])).isEmpty)
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    let apply = try operation(s.send(.response(rpc, .result("created"))))
    let cleanup = try operation(s.send(.databaseFinished(apply, .done)))
    #expect(
      dbWork(s.send(.databaseFinished(cleanup, .done))) == [.markDispatching(TransactionID(2))])
  }

  @Test func reconnectDoesNotDiscardSameAccountApplyCompletion() throws {
    var s = Scenario()
    let connection = try s.open()
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    let apply = try operation(s.send(.response(rpc, .result("ok"))))
    s.send(.disconnected(connection))
    let cleanup = try operation(s.send(.databaseFinished(apply, .done)))
    s.send(.databaseFinished(cleanup, .done))
    #expect(s.core.outcome(for: TransactionID(1)) == .applied)
  }

  @Test func nonReplayableLostResponseIsUnknownNotRollback() throws {
    var s = Scenario()
    let connection = try s.open()
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    let lost = s.send(.disconnected(connection))
    #expect(dbWork(lost) == [.settle(TransactionID(1), .executionUnknown)])
    #expect(dbWork(s.send(.response(rpc, .result("late")))).isEmpty)
    let settle = try operation(lost)
    s.send(.databaseFinished(settle, .done))
    #expect(s.core.outcome(for: TransactionID(1)) == .executionUnknown)
  }

  @Test func replaySafeLostAttemptCannotFinishReplacement() throws {
    var s = Scenario()
    let connection = try s.open()
    let marker = try operation(s.queue(1, replay: .replaySafe))
    let old = try attempt(s.send(.databaseFinished(marker, .done)))
    s.send(.disconnected(connection))
    let reconnect = s.send(.timeout, at: 10)
    let fresh = try #require(
      reconnect.compactMap { if case .connect(let id) = $0 { id } else { nil } }.first)
    let nextMarker = try operation(s.authorize(fresh))
    let next = try attempt(s.send(.databaseFinished(nextMarker, .done)))
    #expect(old != next)
    #expect(dbWork(s.send(.response(old, .result("late")))).isEmpty)
    #expect(s.core.outstandingRequests == 1)
    #expect(
      dbWork(s.send(.response(next, .result("current")))) == [
        .applyTransaction(TransactionID(1), "current")
      ])
  }

  @Test func persistenceFailureRetriesWithNewIdentityAndNoPrematureSend() throws {
    var s = Scenario()
    try s.open()
    let marker = try operation(s.queue(1))
    #expect(transmissions(s.send(.databaseFinished(marker, .failed))).isEmpty)
    #expect(transmissions(s.send(.databaseFinished(marker, .done))).isEmpty)
    let retry = try operation(s.send(.timeout, at: 10))
    #expect(retry != marker)
    #expect(transmissions(s.send(.databaseFinished(retry, .done))).count == 1)
  }

  @Test func shutdownWaitsForRealWriteAndCloseCompletion() throws {
    var s = Scenario()
    let connection = try s.open()
    let marker = try operation(s.queue(1))
    let stopping = s.send(.stop)
    #expect(!stopping.contains(.event(.drained)))
    #expect(!s.send(.disconnected(connection)).contains(.event(.drained)))
    let ended = s.send(.databaseFinished(marker, .done))
    #expect(ended.contains(.event(.drained)))
    #expect(transmissions(ended).isEmpty)
    #expect(!s.send(.databaseFinished(marker, .done)).contains(.event(.drained)))
  }

  @Test func oldAccountWriteCannotAdvanceReplacement() throws {
    var s = Scenario()
    try s.open()
    let old = try operation(s.queue(1))
    try s.open(generation: 2)
    let fresh = try operation(s.queue(1))
    #expect(transmissions(s.send(.databaseFinished(old, .done))).isEmpty)
    #expect(s.core.outcome(for: TransactionID(1)) == nil)
    #expect(transmissions(s.send(.databaseFinished(fresh, .done))).count == 1)
  }

  @Test func staleHandshakeAndTerminalAuthFailureCannotOpenSession() throws {
    var s = Scenario()
    let old = try s.open()
    let current = try s.open(generation: 2)
    #expect(!s.send(.connected(old)).contains(.event(.online)))
    s.send(.authorizationRevoked(current))
    #expect(dbWork(try s.queue(1)).isEmpty)
    #expect(transmissions(s.send(.timeout, at: 1_000)).isEmpty)
    #expect(s.core.nextDeadline == nil)
  }

  @Test func dependencyCyclesAreRejected() throws {
    var s = Scenario()
    try s.open()
    try s.queue(1, requires: [TransactionID(2)])
    let result = s.send(
      .submit(Tx(id: TransactionID(2), payload: "child", requires: [TransactionID(1)])))
    #expect(result.contains(.event(.submissionRejected(TransactionID(2)))))
  }

  @Test func laneOrderCannotIntroduceHiddenDependencyCycle() throws {
    var s = Scenario()
    try s.open()
    try s.queue(1, lane: "same", requires: [TransactionID(2)])
    let result = s.send(.submit(Tx(id: TransactionID(2), payload: "child", lane: "same")))
    #expect(result.contains(.event(.submissionRejected(TransactionID(2)))))
  }
}
