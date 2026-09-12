import Testing

@testable import RealtimeCore

@Suite struct RecoveryProgressTests {
  @Test func latestDemandDuringAdmissionTransfersRatherThanDuplicatesReservation() throws {
    var s = Scenario()
    s.core = Core(
      configuration: Configuration(capacity: 1, maxPendingSends: 1, bucketAdmission: .removalFenced)
    )
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let read = try operation(s.send(.catchUp(key, through: 2)))
    s.send(.catchUp(key, through: nil))
    let head = s.send(
      .databaseFinished(read, .admission(BucketAdmission(position: .zero, removalRevision: 1))))
    #expect(transmissions(head) == [.captureLatest(key)])
    #expect(s.core.outstandingReservations == 0)
    let id = try attempt(head)
    s.send(.sendFinished(id))
    let fresh = s.send(.response(id, .head(position(2))))
    #expect(dbWork(fresh) == [.captureBucketAdmission(key, expected: .zero, network: true)])
    let fetch = s.send(
      .databaseFinished(
        try operation(fresh), .admission(BucketAdmission(position: .zero, removalRevision: 2))))
    #expect(transmissions(fetch) == [.fetch(key, from: 0, through: 2)])
  }

  @Test(arguments: [
    Response<String>.discovery(checkpoint: 4, targets: [:]), .result("wrong shape"),
  ])
  func invalidDiscoveryRetainsRoundAndRetriesAtItsOwnDeadline(_ response: Response<String>) throws {
    var s = Scenario()
    try s.open()
    let id = try attempt(s.send(.discover(after: 5)))
    s.send(.discover(after: 5))  // Preserve a requested follow-up too.
    s.send(.sendFinished(id))
    let rejected = s.send(.response(id, response))
    #expect(dbWork(rejected).isEmpty)
    #expect(s.core.discovery != nil)
    #expect(s.core.discovery?.requested == true)
    #expect(s.core.nextDeadline == 10)
    let retry = s.send(.timeout, at: 10)
    #expect(transmissions(retry) == [.discover(after: 5)])
    let write = s.send(.response(try attempt(retry), .discovery(checkpoint: 6, targets: [:])))
    #expect(dbWork(write) == [.storeCheckpoint(6)])
    let followUp = s.send(.databaseFinished(try operation(write), .done))
    #expect(transmissions(followUp) == [.discover(after: 6)])
  }

  @Test func admissionConflictDropsUncommittedLivePayloadButRetainsDemand() throws {
    var s = Scenario()
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let apply = try operation(
      s.send(.live(key, Update(sequence: 1, payload: "old incarnation", date: 1), generation: 1)))
    let reload = try operation(s.send(.databaseFinished(apply, .conflict)))
    let resumed = s.send(.databaseFinished(reload, .bucketState(.zero)))
    #expect(dbWork(resumed).isEmpty)
    #expect(transmissions(resumed) == [.fetch(key, from: 0, through: 1)])
    #expect(s.core.cursor(for: key) == 0)
  }
  @Test func interruptedLargePageRetriesSameCursorAndKeepsCompletePayload() throws {
    var s = Scenario()
    let connection = try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let interrupted = try attempt(s.send(.catchUp(key, through: 2)))
    // Transport rejection supplies no page and no authority to repair or advance.
    s.send(.disconnected(connection))
    s.send(.sendFinished(interrupted))
    #expect(s.core.cursor(for: key) == 0)
    let reconnect = s.send(.timeout, at: 10)
    let next = try #require(
      reconnect.compactMap { if case .connect(let id) = $0 { id } else { nil } }.first)
    let retried = try s.authorize(next)
    #expect(transmissions(retried) == [.fetch(key, from: 0, through: 2)])
    let payload = String(repeating: "x", count: 1_100_000)
    let prefix = Page(
      through: 1, date: 1, final: false,
      updates: [Update(sequence: 1, payload: payload, date: 1)], sidecars: "prefix dependencies")
    #expect(dbWork(s.send(.response(interrupted, .page(prefix)))).isEmpty)
    let apply = s.send(.response(try attempt(retried), .page(prefix)))
    let intact = dbWork(apply) == [.applyPage(key, expected: .zero, prefix)]
    #expect(intact, "Core must forward the complete indivisible update and selected sidecars")
    #expect(s.core.cursor(for: key) == 0)
    let remainder = s.send(.databaseFinished(try operation(apply), .committed(position(1))))
    #expect(transmissions(remainder) == [.fetch(key, from: 1, through: 2)])
    let tail = Page<String>(
      through: 2, date: 1, final: true, skipped: [SkippedSequence(2, reason: .irrelevant)])
    let finalWrite = s.send(.response(try attempt(remainder), .page(tail)))
    let completed = s.send(.databaseFinished(try operation(finalWrite), .committed(position(2))))
    #expect(completed.contains(.event(.caughtUp(key, through: 2))))
  }

  @Test(arguments: [false, true])
  func reachingTargetWithoutFinalPageStillNeedsCompletionEvidence(latest: Bool) throws {
    var s = Scenario()
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let first = try attempt(s.send(.catchUp(key, through: latest ? nil : 2)))
    let fetch = latest ? try attempt(s.send(.response(first, .head(position(2))))) : first
    let nonfinal = Page(through: 2, date: 1, final: false, updates: page(0, 2).updates)
    let write = try operation(s.send(.response(fetch, .page(nonfinal))))
    let probe = s.send(.databaseFinished(write, .committed(position(2))))
    #expect(!probe.contains(.event(.caughtUp(key, through: 2))))
    #expect(transmissions(probe) == [.fetch(key, from: 2, through: 2)])
    let final = Page<String>(through: 2, date: 0, final: true, kind: .empty)
    let finalWrite = try operation(s.send(.response(try attempt(probe), .page(final))))
    let done = s.send(.databaseFinished(finalWrite, .committed(position(2))))
    #expect(done.contains(.event(.caughtUp(key, through: 2))))
    #expect(s.core.buckets[key]?.completedLatest == (latest ? 1 : 0))
  }

  @Test func malformedPageRetriesWithoutUserInterventionOrCursorAdvance() throws {
    var s = Scenario()
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let first = try attempt(s.send(.catchUp(key, through: 2)))
    let invalid = Page<String>(through: 2, date: 1, final: true)
    s.send(.response(first, .page(invalid)))
    s.send(.sendFinished(first))
    #expect(s.core.cursor(for: key) == 0)
    #expect(s.core.buckets[key]?.blocked == false)
    #expect(s.core.nextDeadline == 10)
    let retry = s.send(.timeout, at: 10)
    #expect(transmissions(retry) == [.fetch(key, from: 0, through: 2)])
    let write = try operation(
      s.send(
        .response(
          try attempt(retry),
          .page(Page(through: 2, date: 1, final: true, updates: page(0, 2).updates)))))
    #expect(
      s.send(.databaseFinished(write, .committed(position(2)))).contains(
        .event(.caughtUp(key, through: 2))))
  }

  @Test func malformedRepairRetainsRecoveryIntentAndRetriesWithoutReplayingOldPage() throws {
    var s = Scenario()
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let fetch = try attempt(s.send(.catchUp(key, through: 2)))
    let repair = try attempt(
      s.send(.response(fetch, .page(Page(through: 2, date: 1, final: true, kind: .tooLong)))))
    let invalid = RepairSnapshot(payload: "stale", position: position(1))
    let rejected = s.send(.response(repair, .repairSnapshot(invalid)))
    #expect(rejected.contains(.event(.syncRetryScheduled(key, .invalidRepairSnapshot, at: 10))))
    #expect(dbWork(rejected).isEmpty)
    let retry = s.send(.timeout, at: 10)
    #expect(transmissions(retry) == [.repairSnapshot(key, position(2), .historyExpired)])
    let valid = RepairSnapshot(payload: "fresh", position: position(2))
    let imported = try operation(s.send(.response(try attempt(retry), .repairSnapshot(valid))))
    let finalized = try operation(s.send(.databaseFinished(imported, .done)))
    #expect(
      s.send(.databaseFinished(finalized, .committed(position(2)))).contains(
        .event(.caughtUp(key, through: 2))))
  }

  @Test func inaccessibleChildReleasesDiscoveryAndReauditsParentWithoutAdvancingChild() throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let parent = BucketID(1)
    let child = BucketID(2)
    let imported = try s.beginRepair(parent, children: [child: 3])
    let load = try operation(s.send(.databaseFinished(imported, .done)))
    let fetch = try attempt(s.send(.databaseFinished(load, .bucketState(position(1)))))
    let discovery = try attempt(s.send(.discover(after: 1)))
    s.send(.response(discovery, .discovery(checkpoint: 2, targets: [child: 3])))
    let retired = s.send(.response(fetch, .bucketUnavailable))
    #expect(retired.contains(.event(.bucketRetired(child))))
    #expect(!retired.contains(.event(.caughtUp(child, through: 3))))
    #expect(s.core.cursor(for: child) == 1)
    #expect(s.core.discovery?.targets[child] == nil)
    let audit = s.send(.timeout, at: 10)
    #expect(transmissions(audit) == [.repairSnapshot(parent, position(2), .dependencyChanged)])
    let newSnapshot = RepairSnapshot(payload: "child removed", position: position(3))
    let nextImport = try operation(
      s.send(.response(try attempt(audit), .repairSnapshot(newSnapshot))))
    let finalize = try operation(s.send(.databaseFinished(nextImport, .done)))
    #expect(
      s.send(.databaseFinished(finalize, .committed(position(3)))).contains(
        .event(.caughtUp(parent, through: 3))))
    #expect(s.core.cursor(for: child) == 1)
  }

  @Test(arguments: [false, true])
  func parentReauditWaitsForIssuedFinalizationAndIgnoresDuplicateReceipt(failed: Bool) throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let parent = BucketID(1)
    let child = BucketID(2)
    s.send(.snapshot(child, position(1), generation: 1))
    let imported = try s.beginRepair(parent, children: [child: 1])
    let finalization = try operation(s.send(.databaseFinished(imported, .done)))
    let fetch = try attempt(s.send(.catchUp(child, through: 2)))
    s.send(.response(fetch, .bucketUnavailable))
    #expect(transmissions(s.send(.timeout, at: 10)).isEmpty)
    #expect(s.core.outstandingDatabaseOperations == 1)
    let receipt = s.send(
      .databaseFinished(finalization, failed ? .failed : .committed(position(2))))
    #expect(!receipt.contains(.event(.caughtUp(parent, through: 2))))
    #expect(transmissions(receipt).isEmpty)
    let audit = s.send(.timeout, at: 20)
    #expect(transmissions(audit) == [.repairSnapshot(parent, position(2), .dependencyChanged)])
    #expect(dbWork(s.send(.databaseFinished(finalization, .committed(position(2))))).isEmpty)
  }

  @Test(arguments: [false, true])
  func bootstrapReauditWaitsForIssuedAdmission(failed: Bool) throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let child = BucketID(1)
    s.send(.snapshot(child, position(1), generation: 1))
    let admission = try operation(s.bootstrapChildren([child: 1]))
    let fetch = try attempt(s.send(.catchUp(child, through: 2)))
    s.send(.response(fetch, .bucketUnavailable))
    #expect(transmissions(s.send(.timeout, at: 10)).isEmpty)
    let receipt = s.send(
      .databaseFinished(admission, failed ? .failed : .committed(position(10, date: 8))))
    #expect(!receipt.contains(.event(.bootstrapFinished)))
    #expect(dbWork(receipt).isEmpty)
    #expect(transmissions(s.send(.timeout, at: 20)) == [.bootstrapCheckpoint])
  }

  @Test func accessLossWithdrawsUnissuedFinalizationRetry() throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let parent = BucketID(1)
    let child = BucketID(2)
    s.send(.snapshot(child, position(1), generation: 1))
    let imported = try s.beginRepair(parent, children: [child: 1])
    let finalization = try operation(s.send(.databaseFinished(imported, .done)))
    s.send(.databaseFinished(finalization, .failed))
    let fetch = try attempt(s.send(.catchUp(child, through: 2)))
    s.send(.response(fetch, .bucketUnavailable))
    let audit = s.send(.timeout, at: 10)
    #expect(dbWork(audit).isEmpty)
    #expect(transmissions(audit) == [.repairSnapshot(parent, position(2), .dependencyChanged)])
  }

  @Test func accessLossWithdrawsUnissuedBootstrapAdmissionRetry() throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let child = BucketID(1)
    s.send(.snapshot(child, position(1), generation: 1))
    let admission = try operation(s.bootstrapChildren([child: 1]))
    s.send(.databaseFinished(admission, .failed))
    let fetch = try attempt(s.send(.catchUp(child, through: 2)))
    s.send(.response(fetch, .bucketUnavailable))
    let audit = s.send(.timeout, at: 10)
    #expect(dbWork(audit).isEmpty)
    #expect(transmissions(audit) == [.bootstrapCheckpoint])
  }

  @Test(arguments: [false, true])
  func finiteDiscoveryNeedsDurablePositionButLatestNeedsCompletedPass(latest: Bool) throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let discover = try attempt(s.send(.discover(after: 1)))
    let first = try attempt(
      s.send(.response(discover, .discovery(checkpoint: 2, targets: [key: latest ? 0 : 2]))))
    let fetch = latest ? try attempt(s.send(.response(first, .head(position(2))))) : first
    let write = try operation(s.send(.response(fetch, .page(page(0, 2, final: false)))))
    let atTarget = s.send(.databaseFinished(write, .committed(position(2))))
    #expect(dbWork(atTarget).contains(.storeCheckpoint(2)) == !latest)
    #expect(transmissions(atTarget) == [.fetch(key, from: 2, through: 2)])
    let final = Page<String>(through: 2, date: 0, final: true, kind: .empty)
    let finalWrite = try operation(s.send(.response(try attempt(atTarget), .page(final))))
    let done = s.send(.databaseFinished(finalWrite, .committed(position(2))))
    if latest { #expect(dbWork(done).contains(.storeCheckpoint(2))) }
  }

}
