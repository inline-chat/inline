import Testing

@testable import RealtimeCore

@Suite struct SyncCompositionTests {
  @Test func capacityDoesNotRequireWallClockNegativeAssertion() throws {
    var s = Scenario(capacity: 1)
    try s.open()
    let a = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    let b = try operation(s.send(.catchUp(BucketID(2), through: 2)))
    let request = try attempt(s.send(.databaseFinished(a, .bucketState(position(0)))))
    #expect(transmissions(s.send(.databaseFinished(b, .bucketState(position(0))))).isEmpty)
    let result = s.send(.response(request, .page(page(0, 2))))
    // Network slot is free even though A's commit still hasn't completed.
    #expect(transmissions(result) == [.fetch(BucketID(2), from: 0, through: 2)])
    #expect(s.core.cursor(for: BucketID(1)) == 0)
  }

  @Test func laterDemandSurvivesFrozenPass() throws {
    var s = Scenario()
    try s.open()
    let read = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    let first = try attempt(s.send(.databaseFinished(read, .bucketState(position(0)))))
    s.send(.catchUp(BucketID(1), through: 4))
    let commit = try operation(s.send(.response(first, .page(page(0, 2)))))
    let next = s.send(.databaseFinished(commit, .committed(position(2))))
    #expect(transmissions(next) == [.fetch(BucketID(1), from: 2, through: 4)])
  }

  @Test func newerLatestDemandNeedsAnotherCapture() throws {
    var s = Scenario()
    try s.open()
    let read = try operation(s.send(.catchUp(BucketID(1), through: nil)))
    let capture = try attempt(s.send(.databaseFinished(read, .bucketState(position(0)))))
    let first = try attempt(s.send(.response(capture, .head(position(2)))))
    s.send(.catchUp(BucketID(1), through: nil))
    let commit = try operation(s.send(.response(first, .page(page(0, 2)))))
    #expect(
      transmissions(s.send(.databaseFinished(commit, .committed(position(2))))) == [
        .captureLatest(BucketID(1))
      ])
  }

  @Test func staleLatestHeadCannotCompleteDemand() throws {
    for head in [position(3, date: 11), position(5, date: 9)] {
      var s = Scenario()
      try s.open()
      let read = try operation(s.send(.catchUp(BucketID(1), through: nil)))
      let capture = try attempt(
        s.send(.databaseFinished(read, .bucketState(position(5, date: 10)))))
      let stale = s.send(.response(capture, .head(head)))
      #expect(transmissions(stale).isEmpty)
      #expect(stale.contains(.event(.blocked("invalid latest coordinate"))))
      #expect(s.core.cursor(for: BucketID(1)) == 5)
    }
  }

  @Test func externalSnapshotOutranksOlderApplyReceipt() throws {
    var s = Scenario()
    try s.open()
    let read = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    let rpc = try attempt(s.send(.databaseFinished(read, .bucketState(position(0)))))
    let commit = try operation(s.send(.response(rpc, .page(page(0, 2)))))
    s.send(.snapshot(BucketID(1), position(5)))
    s.send(.databaseFinished(commit, .committed(position(2))))
    #expect(s.core.cursor(for: BucketID(1)) == 5)
  }

  @Test func conflictReloadCanObserveRemovedCursorWithoutLosingTarget() throws {
    var s = Scenario()
    try s.open()
    let read = try operation(s.send(.catchUp(BucketID(1), through: 5)))
    let rpc = try attempt(s.send(.databaseFinished(read, .bucketState(position(3)))))
    let commit = try operation(s.send(.response(rpc, .page(page(3, 5)))))
    let reload = try operation(s.send(.databaseFinished(commit, .conflict)))
    #expect(
      transmissions(s.send(.databaseFinished(reload, .bucketState(position(0))))) == [
        .fetch(BucketID(1), from: 0, through: 5)
      ])
  }

  @Test func pageValidationRejectsMissingAndDuplicatePositions() throws {
    for updates in [
      [Update(sequence: 2, payload: "u2")],
      [Update(sequence: 1, payload: "u1"), Update(sequence: 1, payload: "u1")],
    ] {
      var s = Scenario()
      try s.open()
      let read = try operation(s.send(.catchUp(BucketID(1), through: 2)))
      let rpc = try attempt(s.send(.databaseFinished(read, .bucketState(position(0)))))
      let rejected = s.send(
        .response(rpc, .page(Page(through: 2, date: 1, final: true, updates: updates))))
      #expect(dbWork(rejected).isEmpty)
      #expect(rejected.contains(.event(.blocked("malformed or non-progress page"))))
      #expect(s.core.cursor(for: BucketID(1)) == 0)
      #expect(s.core.nextDeadline == 1_000_000)
    }
  }

  @Test func livePayloadOverflowRetainsCatchupDemand() throws {
    var s = Scenario(buffer: 2)
    try s.open()
    let read = try operation(s.send(.catchUp(BucketID(1), through: 1)))
    let rpc = try attempt(s.send(.databaseFinished(read, .bucketState(position(0)))))
    for sequence in 2...4 {
      s.send(.live(BucketID(1), Update(sequence: Int64(sequence), payload: "live")))
    }
    let commit = try operation(s.send(.response(rpc, .page(page(0, 1)))))
    #expect(
      transmissions(s.send(.databaseFinished(commit, .committed(position(1))))) == [
        .fetch(BucketID(1), from: 1, through: 4)
      ])
  }

  @Test func discoveryCheckpointWaitsForEveryChildCommitAndOwnSave() throws {
    var s = Scenario()
    try s.open()
    let discover = try attempt(s.send(.discover(after: 10)))
    let reads = s.send(
      .response(discover, .discovery(checkpoint: 20, targets: [BucketID(1): 2, BucketID(2): 3])))
    let operations = reads.compactMap {
      if case .database(let id, .loadBucket(let key)) = $0 { (id, key) } else { nil }
    }
    #expect(operations.count == 2)
    var commits: [(OperationID, Int64)] = []
    for (read, key) in operations {
      let rpc = try attempt(s.send(.databaseFinished(read, .bucketState(position(0)))))
      let end: Int64 = key == BucketID(1) ? 2 : 3
      commits.append((try operation(s.send(.response(rpc, .page(page(0, end))))), end))
    }
    #expect(
      dbWork(s.send(.databaseFinished(commits[0].0, .committed(position(commits[0].1))))).isEmpty)
    let checkpointActions = s.send(
      .databaseFinished(commits[1].0, .committed(position(commits[1].1))))
    #expect(dbWork(checkpointActions) == [.storeCheckpoint(20)])
    let checkpoint = try operation(checkpointActions)
    #expect(!s.trace.contains(.event(.checkpointStored(20))))
    s.send(.databaseFinished(checkpoint, .failed))
    let retry = try operation(s.send(.timeout, at: 10))
    #expect(s.send(.databaseFinished(retry, .done)).contains(.event(.checkpointStored(20))))
  }

  @Test func transactionAndSyncShareCapacityButNotCommitOwnership() throws {
    var s = Scenario(capacity: 1)
    try s.open()
    let marker = try operation(s.queue(1))
    let read = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    #expect(transmissions(s.send(.databaseFinished(read, .bucketState(position(0))))).isEmpty)
    let transaction = try attempt(s.send(.databaseFinished(marker, .done)))
    let response = s.send(.response(transaction, .result("ok")))
    #expect(dbWork(response) == [.applyTransaction(TransactionID(1), "ok")])
    #expect(transmissions(response) == [.fetch(BucketID(1), from: 0, through: 2)])
  }
}
