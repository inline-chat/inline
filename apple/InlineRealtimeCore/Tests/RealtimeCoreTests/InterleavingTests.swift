import Testing

@testable import RealtimeCore

private struct RandomOrder {
  var state: UInt64
  mutating func index(_ count: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 32) % UInt64(count))
  }
}

@Suite struct InterleavingTests {
  /// Seeded delivery order, not a fake service/database. Each result explicitly
  /// fulfills an emitted operation. No external algorithm predicts sync progress.
  @Test(arguments: 0..<256)
  func mixedWorkAndPersistenceFailuresReplayExactly(_ seed: Int) throws {
    let first = try run(seed)
    let replay = try run(seed)
    #expect(first == replay, "seed \(seed) changed its trace")
  }

  private func run(_ seed: Int) throws -> [Action] {
    var random = RandomOrder(state: UInt64(seed))
    var s = Scenario(capacity: 1 + seed % 3)
    try s.open()
    var pending: [Action] = []
    for i in 1...4 {
      pending += s.send(
        .submit(
          Tx(
            id: TransactionID(Int64(i)), payload: "message",
            lane: i % 2 == 0 ? "even" : "odd",
            requires: i == 4 ? [TransactionID(1)] : [])))
    }
    pending += s.send(.catchUp(BucketID(1), through: 3))
    pending += s.send(.discover(after: 1))
    pending += s.send(.call("direct"))
    var remainingFailures = seed % 5
    var steps = 0
    while true {
      pending = pending.filter {
        switch $0 {
        case .database, .transmit: true
        default: false
        }
      }
      if pending.isEmpty {
        if s.core.transactions.isEmpty, s.core.discovery == nil,
          s.core.buckets.values.allSatisfy({ !$0.hasDemand && $0.pending == nil })
        {
          break
        }
        if let deadline = s.core.nextDeadline {
          pending += s.send(.timeout, at: deadline)
        } else {
          break
        }
      } else {
        let action = pending.remove(at: random.index(pending.count))
        switch action {
        case .database(let id, let work):
          if remainingFailures > 0 && random.index(3) == 0 {
            remainingFailures -= 1
            pending += s.send(.databaseFinished(id, .failed))
            // The failed completion relinquished this ID. A duplicate cannot commit.
            #expect(dbWork(s.send(.databaseFinished(id, .done))).isEmpty)
          } else {
            let result: DatabaseResult
            switch work {
            case .loadBucket: result = .bucketState(position(0))
            case .applyPage(_, _, let page):
              result = .committed(position(page.through, date: page.date))
            default: result = .done
            }
            pending += s.send(.databaseFinished(id, result))
          }
        case .transmit(let id, _, let request):
          let result: Response<String>
          switch request {
          case .fetch(_, let start, let target): result = .page(page(start, target))
          case .captureLatest: result = .head(position(3))
          case .repairSnapshot: throw TestFailure.unexpectedRepair
          case .discover:
            result = .discovery(checkpoint: 10, targets: [BucketID(1): 3, BucketID(2): 2])
          default: result = .result("result")
          }
          pending += s.send(.response(id, result))
          pending += s.send(.sendFinished(id))
        default: break
        }
      }
      steps += 1
      try #require(steps < 200, "seed \(seed): stranded work or repeated retry")
    }
    for i in 1...4 { #expect(s.core.outcome(for: TransactionID(Int64(i))) == .applied) }
    #expect(s.core.cursor(for: BucketID(1)) == 3)
    #expect(s.core.cursor(for: BucketID(2)) == 2)
    #expect(s.trace.contains(.event(.checkpointStored(10))))
    #expect(
      s.trace.contains { if case .event(.directFinished(_, .some)) = $0 { true } else { false } })
    #expect(s.core.outstandingSends == 0)
    #expect(s.core.outstandingRequests == 0)
    #expect(s.core.outstandingDatabaseOperations == 0)
    return s.trace
  }
}
