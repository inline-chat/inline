import Testing

@testable import RealtimeCore

@Suite struct PageContractTests {
  @Test func exactEmptyCompletionPreservesStoredDate() {
    let page = Page<String>(through: 5, date: 0, final: true, kind: .empty)
    #expect(page.decision(from: position(5, date: 7), through: 5) == .apply(position(5, date: 7)))
    #expect(page.decision(from: position(5, date: 7), through: 6) == .reject)
    let sidecars = Page<String>(
      through: 5, date: 0, final: true, kind: .empty, sidecars: "sidecars")
    #expect(sidecars.decision(from: position(5), through: 5) == .reject)
  }

  @Test func finalBelowCapturedTargetAndNonfinalNoProgressAreRejected() {
    let earlyFinal = Page(through: 2, date: 1, final: true, updates: page(0, 2).updates)
    #expect(earlyFinal.decision(from: .zero, through: 3) == .reject)
    let stalled = Page<String>(through: 0, date: 1, final: false)
    #expect(stalled.decision(from: .zero, through: 3) == .reject)
    let falselyFinal = Page<String>(through: 0, date: 1, final: true)
    #expect(falselyFinal.decision(from: .zero, through: 0) == .reject)
    #expect(page(0, 4).decision(from: .zero, through: 3) == .reject)
  }

  @Test func tooLongCannotCarryPagePayload() {
    let clean = Page<String>(through: 3, date: 1, final: true, kind: .tooLong)
    #expect(clean.decision(from: .zero, through: 3) == .repair(position(3), .historyExpired))
    let update = Page(
      through: 3, date: 1, final: true, kind: .tooLong,
      updates: [Update(sequence: 1, payload: "update")])
    #expect(update.decision(from: .zero, through: 3) == .reject)
    let skip = Page<String>(
      through: 3, date: 1, final: true, kind: .tooLong,
      skipped: [SkippedSequence(1, reason: .snapshotRepairRequired)])
    #expect(skip.decision(from: .zero, through: 3) == .reject)
    let sidecars = Page(
      through: 3, date: 1, final: true, kind: .tooLong, sidecars: "sidecars")
    #expect(sidecars.decision(from: .zero, through: 3) == .reject)
  }

  @Test func latestCaptureIsNotProgressAndSlicesKeepTheSameBound() throws {
    var s = Scenario()
    try s.open()
    let load = try operation(s.send(.catchUp(BucketID(1), through: nil)))
    let head = try attempt(s.send(.databaseFinished(load, .bucketState(.zero))))
    let first = s.send(.response(head, .head(position(4))))
    #expect(s.core.cursor(for: BucketID(1)) == 0)
    #expect(transmissions(first) == [.fetch(BucketID(1), from: 0, through: 4)])
    let commit = try operation(s.send(.response(try attempt(first), .page(page(0, 2)))))
    let second = s.send(.databaseFinished(commit, .committed(position(2))))
    #expect(transmissions(second) == [.fetch(BucketID(1), from: 2, through: 4)])
    #expect(!second.contains(.event(.caughtUp(BucketID(1), through: 2))))
  }

  @Test func dateParticipatesInSnapshotSupersessionAndCommitEvidence() throws {
    var s = Scenario()
    try s.open()
    let load = try operation(s.send(.catchUp(BucketID(1), through: 3)))
    let rpc = try attempt(s.send(.databaseFinished(load, .bucketState(position(1, date: 10)))))
    s.send(.snapshot(BucketID(1), position(1, date: 11), generation: 1))
    let stale = s.send(.response(rpc, .page(page(1, 3))))
    #expect(dbWork(stale).isEmpty)
    #expect(transmissions(stale) == [.fetch(BucketID(1), from: 1, through: 3)])
    let fresh = try attempt(stale)
    let commit = try operation(s.send(.response(fresh, .page(page(1, 3)))))
    #expect(
      s.send(.databaseFinished(commit, .committed(position(3, date: 1)))).contains(
        .event(.blocked("database result does not match issued work"))))
    s.send(.databaseFinished(commit, .committed(position(3, date: 11))))
    #expect(s.core.cursor(for: BucketID(1)) == 3)
  }

  @Test func updateDatesAndUnsupportedConstructorsAreNotDiscarded() {
    let updated = Update(sequence: 1, payload: "update", date: 12)
    #expect(
      Page(through: 1, date: 8, final: true, updates: [updated]).decision(
        from: position(0, date: 10), through: 1) == .apply(position(1, date: 12)))
    let unsupported = Update(sequence: 1, payload: "unknown", supported: false)
    #expect(
      Page(through: 1, date: 1, final: true, updates: [unsupported]).decision(
        from: .zero, through: 1) == .reject)
  }

  /// All 216 representations of three covered sequence positions. Expected
  /// authority is defined by the wire contract, including negative classifications.
  @Test(arguments: 0..<216)
  func sequenceAccountingCannotInventRepairAuthority(_ code: Int) {
    var digits = code
    var updates: [Update<String>] = []
    var skips: [SkippedSequence] = []
    var invalid = false
    var repair = false
    for sequence in 1...3 {
      let choice = digits % 6
      digits /= 6
      switch choice {
      case 0: updates.append(Update(sequence: Int64(sequence), payload: "update"))
      case 1: skips.append(SkippedSequence(Int64(sequence), reason: .irrelevant))
      case 2:
        skips.append(SkippedSequence(Int64(sequence), reason: .snapshotRepairRequired))
        repair = true
      case 3: invalid = true  // Missing position.
      case 4:
        skips.append(SkippedSequence(Int64(sequence), reason: .unknown))
        invalid = true
      default:
        updates.append(Update(sequence: Int64(sequence), payload: "update"))
        skips.append(SkippedSequence(Int64(sequence), reason: .irrelevant))
        invalid = true
      }
    }
    let candidate = Page(through: 3, date: 1, final: true, updates: updates, skipped: skips)
    let expected: PageDecision =
      invalid ? .reject : repair ? .repair(position(3), .serverClassifiedGap) : .apply(position(3))
    #expect(candidate.decision(from: .zero, through: 3) == expected)
  }
}
