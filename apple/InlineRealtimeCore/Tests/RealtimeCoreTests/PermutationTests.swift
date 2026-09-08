import Testing

@testable import RealtimeCore

@Suite struct PermutationTests {
  /// 24 completion orders x 81 result assignments. Only emitted operations are completed.
  @Test(arguments: 0..<1944)
  func fourRequestsAcrossEveryOrderAndOutcome(_ scenario: Int) throws {
    let orders = permutations([0, 1, 2, 3])
    let order = orders[scenario % 24]
    var choices = scenario / 24
    var outcomes: [Int] = []
    for _ in 0..<4 {
      outcomes.append(choices % 3)
      choices /= 3
    }
    var s = Scenario(capacity: 4)
    try s.open()
    var attempts: [OperationID] = []
    for i in 0..<4 {
      let marker = try operation(s.queue(Int64(i)))
      attempts.append(try attempt(s.send(.databaseFinished(marker, .done))))
    }
    var pending: [Action] = []
    for i in order {
      let actions: [Action]
      switch outcomes[i] {
      case 0: actions = s.send(.response(attempts[i], .result("ok")))
      case 1: actions = s.send(.sendFailed(attempts[i], .knownUnsent))
      default: actions = s.send(.sendFailed(attempts[i], .executionUnknown))
      }
      pending += actions
      pending += s.send(.sendFinished(attempts[i]))
      // Duplicate delivery must not create extra apply/settle work.
      #expect(dbWork(s.send(.response(attempts[i], .result("late")))).isEmpty)
    }
    pending += s.send(.timeout, at: 10)
    var steps = 0
    while !pending.isEmpty {
      steps += 1
      try #require(steps < 100, "bounded scenario did not finish: \(scenario)")
      switch pending.removeFirst() {
      case .database(let id, _): pending += s.send(.databaseFinished(id, .done))
      case .transmit(let id, _, _):
        pending += s.send(.response(id, .result("retry-ok")))
        pending += s.send(.sendFinished(id))
      default: break
      }
    }
    for i in 0..<4 {
      let expected: TransactionOutcome = outcomes[i] == 2 ? .executionUnknown : .applied
      #expect(s.core.outcome(for: TransactionID(Int64(i))) == expected)
      let completions = s.trace.filter {
        if case .event(.transactionFinished(let id, _)) = $0 {
          id == TransactionID(Int64(i))
        } else {
          false
        }
      }
      #expect(completions.count == 1)
    }
    #expect(s.core.outstandingSends == 0)
    #expect(s.core.outstandingRequests == 0)
    #expect(s.core.outstandingDatabaseOperations == 0)
    #expect(s.core.nextDeadline == 1_000_000)
  }

  /// Snapshot, later demand and response can occur in any order while one page is in flight.
  @Test(arguments: 0..<6)
  func snapshotDemandResponseOrders(_ index: Int) throws {
    var s = Scenario()
    try s.open()
    let load = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    let rpc = try attempt(s.send(.databaseFinished(load, .bucketState(position(0)))))
    var commit: OperationID?
    var snapshotArrived = false
    for event in permutations([0, 1, 2])[index] {
      switch event {
      case 0:
        s.send(.snapshot(BucketID(1), position(3)))
        snapshotArrived = true
      case 1: s.send(.catchUp(BucketID(1), through: 4))
      default:
        let response = s.send(.response(rpc, .page(page(0, 2))))
        if snapshotArrived {
          #expect(dbWork(response).isEmpty)
        } else {
          commit = try operation(response)
        }
      }
    }
    if let commit { s.send(.databaseFinished(commit, .committed(position(2)))) }
    #expect(s.core.cursor(for: BucketID(1)) == 3)
    #expect(
      transmissions(s.trace).filter { $0 == .fetch(BucketID(1), from: 3, through: 4) }.count == 1)

  }
}
