import Testing

@testable import RealtimeCore

extension Scenario {
  mutating func bootstrapProjections(user: BucketID = BucketID(100)) throws -> [BootstrapProjection:
    OperationID]
  {
    let before = try attempt(send(.bootstrap(user: user)))
    let actions = send(.response(before, .head(position(10, date: 7))))
    return Dictionary(
      uniqueKeysWithValues: actions.compactMap {
        if case .transmit(let id, _, .bootstrapProjection(let kind, _)) = $0 {
          (kind, id)
        } else {
          nil
        }
      })
  }
  mutating func bootstrapChildren(_ targets: [BucketID: Int64]) throws -> [Action] {
    let requests = try bootstrapProjections()
    var after: [Action] = []
    for kind in BootstrapProjection.allCases {
      let write = try operation(
        send(.response(try #require(requests[kind]), .result("projection"))))
      after = send(
        .databaseFinished(
          write,
          .projection(
            ProjectionReceipt(evidence: "receipt", targets: kind == .chats ? targets : [:]))))
    }
    return send(.response(try attempt(after), .head(position(10, date: 8))))
  }

}

@Suite struct BootstrapTests {
  @Test(arguments: 0..<36)
  func allProjectionResponseAndCommitOrdersRespectBaseline(_ variant: Int) throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let user = BucketID(100)
    let requests = try s.bootstrapProjections(user: user)
    #expect(requests.count == 3)
    let orders = permutations(BootstrapProjection.allCases)
    var writes: [BootstrapProjection: OperationID] = [:]
    for kind in orders[variant % 6] {
      writes[kind] = try operation(
        s.send(.response(try #require(requests[kind]), .result("projection"))))
    }
    var last: [Action] = []
    for kind in orders[variant / 6] {
      #expect(s.core.cursor(for: user) == nil)
      last = s.send(
        .databaseFinished(
          try #require(writes[kind]), .projection(ProjectionReceipt(evidence: "receipt"))))
    }
    #expect(transmissions(last) == [.bootstrapCheckpoint])
    let baseline = s.send(.response(try attempt(last), .head(position(12, date: 8))))
    #expect(s.core.cursor(for: user) == nil)
    #expect(dbWork(baseline).contains { if case .admitBootstrap = $0 { true } else { false } })
    let replay = s.send(
      .databaseFinished(try operation(baseline), .committed(position(10, date: 7))))
    #expect(transmissions(replay) == [.fetch(user, from: 10, through: 12)])
    let apply = try operation(
      s.send(
        .response(
          try attempt(replay),
          .page(
            Page(
              through: 12, date: 8, final: true,
              updates: [Update(sequence: 11, payload: "11"), Update(sequence: 12, payload: "12")])))
      ))
    let checkpoint = s.send(.databaseFinished(apply, .committed(position(12, date: 8))))
    #expect(dbWork(checkpoint) == [.storeBootstrapCheckpoint(7)])
    #expect(
      s.send(.databaseFinished(try operation(checkpoint), .done)).contains(
        .event(.bootstrapFinished)))
  }

  @Test func childEvidenceAndFailedAdmissionPreserveSuccessfulProjections() throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let requests = try s.bootstrapProjections()
    var after: [Action] = []
    for kind in BootstrapProjection.allCases {
      let write = try operation(
        s.send(.response(try #require(requests[kind]), .result("projection"))))
      let receipt =
        kind == .chats
        ? ProjectionReceipt(
          evidence: "catalog", seeds: [BucketID(1): position(2), BucketID(2): .zero],
          targets: [BucketID(1): 3, BucketID(2): 0])
        : ProjectionReceipt(evidence: "receipt")
      after = s.send(.databaseFinished(write, .projection(receipt)))
    }
    let children = s.send(.response(try attempt(after), .head(position(10, date: 8))))
    #expect(dbWork(children).isEmpty)
    let fetch = try #require(
      children.compactMap { if case .transmit(let id, _, .fetch) = $0 { id } else { nil } }.first)
    let latest = try #require(
      children.compactMap { if case .transmit(let id, _, .captureLatest) = $0 { id } else { nil } }
        .first)
    let apply = try operation(s.send(.response(fetch, .page(page(2, 3)))))
    s.send(.databaseFinished(apply, .committed(position(3))))
    #expect(s.core.cursor(for: BucketID(100)) == nil)
    let admission = s.send(.response(latest, .head(.zero)))
    let work = dbWork(admission)
    #expect(
      work.contains {
        if case .admitBootstrap(_, _, _, _, let evidence) = $0 {
          evidence == [BucketID(1): position(3), BucketID(2): .zero]
        } else {
          false
        }
      })
    s.send(.databaseFinished(try operation(admission), .failed))
    let retry = s.send(.timeout, at: 10)
    #expect(dbWork(retry) == work)
    let checkpoint = s.send(
      .databaseFinished(try operation(retry), .committed(position(10, date: 7))))
    #expect(dbWork(checkpoint) == [.storeBootstrapCheckpoint(7)])
    #expect(
      dbWork(s.trace).filter { if case .importBootstrapProjection = $0 { true } else { false } }
        .count == 3)
  }

  @Test func baselineConflictReauditsInsteadOfCommittingOldEvidence() throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let requests = try s.bootstrapProjections()
    var after: [Action] = []
    for kind in BootstrapProjection.allCases {
      let write = try operation(
        s.send(.response(try #require(requests[kind]), .result("projection"))))
      after = s.send(.databaseFinished(write, .projection(ProjectionReceipt(evidence: "receipt"))))
    }
    let admit = try operation(s.send(.response(try attempt(after), .head(position(10, date: 8)))))
    s.send(.databaseFinished(admit, .conflict))
    #expect(s.core.cursor(for: BucketID(100)) == nil)
    #expect(transmissions(s.send(.timeout, at: 10)) == [.bootstrapCheckpoint])
  }
  @Test func malformedChildAutomaticallyRetriesAndResumesBootstrap() throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let child = BucketID(1)
    s.send(.snapshot(child, .zero, generation: 1))
    let fetch = try attempt(s.send(.catchUp(child, through: 1)))
    s.send(.response(fetch, .page(Page(through: 1, date: 1, final: true))))
    let blocked = try s.bootstrapChildren([child: 1])
    #expect(!blocked.contains(.event(.bootstrapBlocked([child]))))
    #expect(!s.send(.timeout).contains(.event(.bootstrapBlocked([child]))))
    let retry = try attempt(s.send(.timeout, at: 10))
    let apply = try operation(s.send(.response(retry, .page(page(0, 1)))))
    let admission = s.send(.databaseFinished(apply, .committed(position(1))))
    #expect(dbWork(admission).contains { if case .admitBootstrap = $0 { true } else { false } })
  }
  @Test func repairCannotDependOnItsOwnBootstrapParent() throws {
    var s = Scenario(capacity: 3)
    try s.open()
    let child = BucketID(1)
    let user = BucketID(100)
    let load = try operation(s.bootstrapChildren([child: 2]))
    let fetch = try attempt(s.send(.databaseFinished(load, .bucketState(.zero))))
    let repair = try attempt(
      s.send(.response(fetch, .page(Page(through: 2, date: 1, final: true, kind: .tooLong)))))
    let cyclic = s.send(
      .response(
        repair,
        .repairSnapshot(
          RepairSnapshot(payload: "cycle", position: position(2), children: [user: 10]))))
    #expect(dbWork(cyclic).isEmpty)
    #expect(cyclic.contains(.event(.syncBlocked(BucketID(1), .dependencyCycle))))
    #expect(cyclic.contains(.event(.bootstrapBlocked([child]))))
  }
  @Test func bootstrapCannotOverlapAnAlreadyIssuedUserFetch() throws {
    var s = Scenario()
    try s.open()
    let user = BucketID(100)
    s.send(.snapshot(user, .zero, generation: 1))
    s.send(.catchUp(user, through: 1))
    s.send(.bootstrap(user: user))
    #expect(s.core.bootstrap == nil)
  }

}
