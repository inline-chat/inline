import Testing

@testable import RealtimeCore

@Suite struct ScaleTests {
  /// Work counts are the invariant. Swift Testing reports elapsed time externally;
  /// the engine/harness never reads a clock or uses timing assertions.
  @Test(arguments: 0..<6)
  func independentBucketsHaveOneFetchAndCommitEach(_ variant: Int) throws {
    let count = [32, 256, 1024][variant / 2]
    let fenced = variant % 2 == 0
    var s = Scenario(capacity: 8)
    s.core = Core(
      configuration: Configuration(
        capacity: 8, bucketAdmission: fenced ? .removalFenced : .cursorOnly))
    try s.open()
    var core = s.core
    var pending: [Action] = []
    for index in 0..<count {
      let key = BucketID(Int64(index))
      core.handle(.snapshot(key, .zero, generation: 1), at: 0)
      pending += core.handle(.catchUp(key, through: 1), at: 0)
    }
    var next = 0
    var fetched = 0
    var committed = 0
    var captured = 0
    while next < pending.count {
      let action = pending[next]
      next += 1
      switch action {
      case .database(let id, .captureBucketAdmission(_, let expected, _)):
        captured += 1
        pending += core.handle(
          .databaseFinished(
            id, .admission(BucketAdmission(position: expected, removalRevision: 1))), at: 0)
      case .database(let id, .applyAdmittedPage), .database(let id, .applyPage):
        committed += 1
        pending += core.handle(.databaseFinished(id, .committed(position(1))), at: 0)
      case .transmit(let id, _, .fetch(_, let from, let through)):
        fetched += 1
        #expect(from == 0 && through == 1)
        pending += core.handle(.response(id, .page(page(0, 1))), at: 0)
        pending += core.handle(.sendFinished(id), at: 0)
      default: break
      }
      try #require(next < count * 20, "unbounded extra work")
    }
    #expect(fetched == count && committed == count)
    #expect(captured == (fenced ? count : 0))
    #expect(
      core.buckets.values.allSatisfy { $0.cursor == 1 && !$0.hasDemand && $0.pending == nil })
    #expect(core.outstandingReservations == 0)
    #expect(core.outstandingSends == 0)
    #expect(core.outstandingRequests == 0)
    #expect(core.now == 0)
  }
}
