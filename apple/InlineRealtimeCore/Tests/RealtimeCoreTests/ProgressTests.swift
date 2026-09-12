import Testing

@testable import RealtimeCore

@Suite struct ProgressTests {
  @Test(arguments: [false, true])
  func uninterpretableLiveCannotAdvanceCursor(missingSequence: Bool) throws {
    var s = Scenario()
    try s.open()
    let bucket = BucketID(1)
    s.send(.snapshot(bucket, position(0), generation: 1))
    let actions = s.send(
      .live(
        bucket,
        Update(
          sequence: 1, payload: "unknown", date: 1,
          hasSequence: !missingSequence, supported: false), generation: 1))
    #expect(dbWork(actions).isEmpty)
    #expect(s.core.cursor(for: bucket) == 0)
    if !missingSequence {
      #expect(transmissions(actions) == [.fetch(bucket, from: 0, through: 1)])
    } else {
      #expect(transmissions(actions).isEmpty)
    }
  }

  @Test func discoveryZeroNeedsCapturedLatestEvidence() throws {
    var s = Scenario()
    try s.open()
    let bucket = BucketID(1)
    s.send(.snapshot(bucket, position(5), generation: 1))
    let discover = try attempt(s.send(.discover(after: 1)))
    let captureActions = s.send(
      .response(discover, .discovery(checkpoint: 2, targets: [bucket: 0])))
    #expect(!dbWork(captureActions).contains(.storeCheckpoint(2)))
    #expect(transmissions(captureActions) == [.captureLatest(bucket)])
    let fetch = try attempt(s.send(.response(try attempt(captureActions), .head(position(6)))))
    let apply = try operation(s.send(.response(fetch, .page(page(5, 6)))))
    #expect(!s.trace.contains(.event(.checkpointStored(2))))
    let checkpointActions = s.send(.databaseFinished(apply, .committed(position(6))))
    #expect(dbWork(checkpointActions) == [.storeCheckpoint(2)])
    let completed = s.send(.databaseFinished(try operation(checkpointActions), .done))
    #expect(completed.contains(.event(.checkpointStored(2))))
  }

  @Test func snapshotOvertakingHeadIsProgressNotProtocolFailure() throws {
    var s = Scenario()
    try s.open()
    let bucket = BucketID(1)
    s.send(.snapshot(bucket, position(1), generation: 1))
    let capture = try attempt(s.send(.catchUp(bucket, through: nil)))
    s.send(.snapshot(bucket, position(10, date: 10), generation: 1))
    let completed = s.send(.response(capture, .head(position(5))))
    #expect(completed.contains(.event(.caughtUp(bucket, through: 10))))
    #expect(s.core.buckets[bucket]?.blocked == false)
    #expect(transmissions(completed).isEmpty)
  }

  @Test func hotBucketCannotStarveOtherBucketOrDiscovery() throws {
    var s = Scenario(capacity: 1)
    try s.open()
    let hot = BucketID(1)
    let other = BucketID(2)
    s.send(.snapshot(hot, position(0), generation: 1))
    s.send(.snapshot(other, position(0), generation: 1))
    let first = try attempt(s.send(.catchUp(hot, through: 100)))
    s.send(.catchUp(other, through: 1))
    s.send(.discover(after: 1))
    let actions = s.send(.response(first, .page(page(0, 1, final: false))))
    #expect(transmissions(actions) == [.discover(after: 1)])
    // Hot bucket becomes runnable again before the request slot frees.
    s.send(.databaseFinished(try operation(actions), .committed(position(1))))
    let next = s.send(.response(try attempt(actions), .discovery(checkpoint: 2, targets: [:])))
    #expect(transmissions(next) == [.fetch(other, from: 0, through: 1)])
  }
  @Test(arguments: 1...8)
  func everyBucketAndDiscoveryMakeProgressWithoutExtraWakeups(capacity: Int) throws {
    var s = Scenario(capacity: capacity)
    let started = s.send(.start(generation: 1))
    let connection = try #require(
      started.compactMap {
        if case .connect(let id) = $0 { id } else { nil }
      }.first)
    let keys = (1...32).map { BucketID(Int64($0)) }
    for key in keys {
      s.send(.snapshot(key, .zero, generation: 1))
      s.send(.catchUp(key, through: 2))
    }
    s.send(.discover(after: 1))
    var work = try s.authorize(connection)
    var visited: Set<BucketID> = []
    var discovered = false
    var steps = 0
    // No timer advancement: every next step must be justified by admitted I/O.
    while !work.isEmpty && steps < 1000 {
      let action = work.removeFirst()
      steps += 1
      switch action {
      case .transmit(let id, _, .fetch(let key, let from, let target)):
        visited.insert(key)
        work += s.send(.response(id, .page(page(from, from + 1, final: from + 1 == target))))
        work += s.send(.sendFinished(id))
      case .transmit(let id, _, .discover):
        discovered = true
        work += s.send(.response(id, .discovery(checkpoint: 2, targets: [:])))
        work += s.send(.sendFinished(id))
      case .database(let id, .applyPage(_, _, let page)):
        work += s.send(.databaseFinished(id, .committed(position(page.through))))
      case .database(let id, .storeCheckpoint):
        work += s.send(.databaseFinished(id, .done))
      default: break
      }
    }
    #expect(steps < 1000)
    #expect(visited == Set(keys))
    #expect(discovered)
    #expect(keys.allSatisfy { s.core.cursor(for: $0) == 2 })
    #expect(s.core.outstandingRequests == 0)
    #expect(s.core.outstandingDatabaseOperations == 0)
    #expect(s.core.outstandingSends == 0)
    #expect(s.now == 0)
  }

  @Test func conflictingLivePayloadsRequireAuthoritativeFetch() throws {
    var s = Scenario()
    try s.open()
    let key = BucketID(1)
    let read = try operation(s.send(.catchUp(key, through: 2)))
    s.send(.live(key, Update(sequence: 2, payload: "before", date: 1), generation: 1))
    s.send(.live(key, Update(sequence: 2, payload: "after", date: 1), generation: 1))
    s.send(.live(key, Update(sequence: 1, payload: "one", date: 1), generation: 1))
    s.send(.live(key, Update(sequence: 2, payload: "after", date: 1), generation: 1))
    let fetch = s.send(.databaseFinished(read, .bucketState(.zero)))
    #expect(dbWork(fetch).isEmpty)
    #expect(transmissions(fetch) == [.fetch(key, from: 0, through: 2)])
  }

  @Test func discoveryRetainsEarlyHintsButDoesNotChaseLaterOnes() throws {
    var s = Scenario()
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let first = try attempt(s.send(.catchUp(key, through: 1)))
    let discovery = try attempt(s.send(.discover(after: 1)))
    s.send(.live(key, Update(sequence: 2, payload: "two", date: 1), generation: 1))
    s.send(.response(discovery, .discovery(checkpoint: 2, targets: [key: 1])))
    let firstApply = try operation(s.send(.response(first, .page(page(0, 1)))))
    let second = s.send(.databaseFinished(firstApply, .committed(position(1))))
    #expect(!dbWork(second).contains(.storeCheckpoint(2)))
    s.send(.catchUp(key, through: 3))
    let secondApplied = s.send(.databaseFinished(try operation(second), .committed(position(2))))
    #expect(dbWork(secondApplied).contains(.storeCheckpoint(2)))
    #expect(transmissions(secondApplied) == [.fetch(key, from: 2, through: 3)])
  }

  @Test func newerRevalidatedRepairReceiptCompletesInsteadOfStranding() throws {
    var s = Scenario()
    try s.open()
    let imported = try s.beginRepair()
    let finalize = try operation(s.send(.databaseFinished(imported, .done)))
    let completed = s.send(.databaseFinished(finalize, .committed(position(3, date: 2))))
    #expect(s.core.cursor(for: BucketID(1)) == 3)
    #expect(s.core.outstandingDatabaseOperations == 0)
    #expect(completed.contains(.event(.caughtUp(BucketID(1), through: 3))))
  }

  @Test func negativeUpdateDatesCannotEnterPageApplication() {
    let candidate = Page(
      through: 1, date: 1, final: true,
      updates: [Update(sequence: 1, payload: "bad", date: -1)])
    #expect(candidate.decision(from: .zero, through: 1) == .reject)
  }

}
