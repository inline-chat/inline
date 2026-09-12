import Testing

@testable import RealtimeCore

extension Scenario {
  mutating func beginRepair(_ key: BucketID = BucketID(1), children: [BucketID: Int64] = [:]) throws
    -> OperationID
  {
    let load = try operation(send(.catchUp(key, through: 2)))
    let rpc = try attempt(send(.databaseFinished(load, .bucketState(.zero))))
    let repair = try attempt(
      send(.response(rpc, .page(Page(through: 2, date: 1, final: true, kind: .tooLong)))))
    let snapshot = RepairSnapshot(payload: "catalog", position: position(2), children: children)
    return try operation(send(.response(repair, .repairSnapshot(snapshot))))
  }
}

@Suite struct RepairTests {
  @Test func finalizationWaitsForChildAndRetriesWithoutRepeatingImport() throws {
    var s = Scenario()
    try s.open()
    let imported = try s.beginRepair(children: [BucketID(2): 3])
    let childLoad = try operation(s.send(.databaseFinished(imported, .done)))
    #expect(s.core.cursor(for: BucketID(1)) == 0)
    let childFetch = try attempt(s.send(.databaseFinished(childLoad, .bucketState(.zero))))
    let childCommit = try operation(s.send(.response(childFetch, .page(page(0, 3)))))
    let finalizing = s.send(.databaseFinished(childCommit, .committed(position(3))))
    let finalization = try operation(finalizing)
    #expect(
      dbWork(finalizing).contains { work in
        if case .finalizeRepair(_, let expected, _, let children) = work {
          return expected == .zero && children == [BucketID(2): position(3)]
        }
        return false
      })
    #expect(dbWork(finalizing).contains { if case .finalizeRepair = $0 { true } else { false } })
    s.send(.databaseFinished(finalization, .failed))
    #expect(s.core.cursor(for: BucketID(1)) == 0)
    let retry = s.send(.timeout, at: 10)
    #expect(transmissions(retry).isEmpty)
    #expect(dbWork(retry) == dbWork(finalizing))
    let completed = s.send(.databaseFinished(try operation(retry), .committed(position(2))))
    #expect(completed.contains(.event(.caughtUp(BucketID(1), through: 2))))
    #expect(
      dbWork(s.trace).filter { if case .importRepair = $0 { true } else { false } }.count == 1)
  }

  @Test func latestChildNeedsCapturedEvidenceEvenWhenCursorIsAlreadyZero() throws {
    var s = Scenario()
    try s.open()
    let imported = try s.beginRepair(children: [BucketID(2): 0])
    let childLoad = try operation(s.send(.databaseFinished(imported, .done)))
    let childHead = s.send(.databaseFinished(childLoad, .bucketState(.zero)))
    #expect(transmissions(childHead) == [.captureLatest(BucketID(2))])
    #expect(dbWork(childHead).isEmpty)
    let finalize = s.send(.response(try attempt(childHead), .head(.zero)))
    #expect(dbWork(finalize).contains { if case .finalizeRepair = $0 { true } else { false } })
  }

  @Test func repairSkipsNeverFallBackToBufferedPayload() throws {
    var s = Scenario()
    try s.open()
    let load = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    let rpc = try attempt(s.send(.databaseFinished(load, .bucketState(.zero))))
    s.send(.live(BucketID(1), Update(sequence: 1, payload: "old grant"), generation: 1))
    let repairPage = Page<String>(
      through: 2, date: 1, final: true,
      skipped: [
        SkippedSequence(1, reason: .snapshotRepairRequired),
        SkippedSequence(2, reason: .irrelevant),
      ])
    let actions = s.send(.response(rpc, .page(repairPage)))
    #expect(dbWork(actions).isEmpty)
    #expect(
      transmissions(actions) == [.repairSnapshot(BucketID(1), position(2), .serverClassifiedGap)])
  }

  @Test func ordinarySkippedPositionsDoNotRequireSnapshotOrUseBufferedValues() throws {
    var s = Scenario()
    try s.open()
    let load = try operation(s.send(.catchUp(BucketID(1), through: 1)))
    let rpc = try attempt(s.send(.databaseFinished(load, .bucketState(.zero))))
    s.send(.live(BucketID(1), Update(sequence: 1, payload: "revoked"), generation: 1))
    let candidate = Page<String>(
      through: 1, date: 1, final: true, skipped: [SkippedSequence(1, reason: .irrelevant)])
    let actions = s.send(.response(rpc, .page(candidate)))
    #expect(dbWork(actions) == [.applyPage(BucketID(1), expected: .zero, candidate)])
    #expect(transmissions(actions).isEmpty)
  }

  @Test func repairAndTransactionApplicationProgressTogether() throws {
    var s = Scenario(capacity: 2)
    try s.open()
    let imported = try s.beginRepair()
    let marker = try operation(s.queue(1))
    let rpc = try attempt(s.send(.databaseFinished(marker, .done)))
    let finalization = try operation(s.send(.databaseFinished(imported, .done)))
    let txApply = try operation(s.send(.response(rpc, .result("reply"))))
    s.send(.databaseFinished(finalization, .failed))
    let cleanup = try operation(s.send(.databaseFinished(txApply, .done)))
    s.send(.databaseFinished(cleanup, .done))
    #expect(s.core.outcome(for: TransactionID(1)) == .applied)
    #expect(s.core.cursor(for: BucketID(1)) == 0)
  }

  @Test func circularRepairChildrenAreRejected() throws {
    var s = Scenario()
    try s.open()
    let load = try operation(s.send(.catchUp(BucketID(1), through: 2)))
    let rpc = try attempt(s.send(.databaseFinished(load, .bucketState(.zero))))
    let repair = try attempt(
      s.send(.response(rpc, .page(Page(through: 2, date: 1, final: true, kind: .tooLong)))))
    let circular = RepairSnapshot(
      payload: "catalog", position: position(2), children: [BucketID(1): 2])
    let rejected = s.send(.response(repair, .repairSnapshot(circular)))
    #expect(dbWork(rejected).isEmpty)
    #expect(rejected.contains(.event(.syncBlocked(BucketID(1), .dependencyCycle))))
  }
}
