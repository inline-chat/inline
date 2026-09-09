import Testing

@testable import RealtimeCore

@Suite struct AdmissionTests {
  @Test func evidenceIsCapturedAfterCapacityAdmissionAndTravelsToWriter() throws {
    var s = Scenario()
    s.core = Core(configuration: Configuration(capacity: 1, bucketAdmission: .removalFenced))
    try s.open()
    let a = BucketID(1)
    let b = BucketID(2)
    s.send(.snapshot(a, .zero, generation: 1))
    s.send(.snapshot(b, .zero, generation: 1))
    let read = try operation(s.send(.catchUp(a, through: 2)))
    #expect(dbWork(s.send(.catchUp(b, through: 2))).isEmpty)
    let firstEvidence = BucketAdmission(position: .zero, removalRevision: 4)
    let first = try attempt(s.send(.databaseFinished(read, .admission(firstEvidence))))
    let response = s.send(.response(first, .page(page(0, 2))))
    #expect(dbWork(response).contains(.applyAdmittedPage(a, firstEvidence, page(0, 2))))
    let secondRead = try #require(
      response.compactMap {
        if case .database(let id, .captureBucketAdmission(b, _, true)) = $0 { id } else { nil }
      }.first)
    let secondEvidence = BucketAdmission(position: .zero, removalRevision: 7)
    let second = try attempt(s.send(.databaseFinished(secondRead, .admission(secondEvidence))))
    #expect(
      dbWork(s.send(.response(second, .page(page(0, 2))))).contains(
        .applyAdmittedPage(b, secondEvidence, page(0, 2))))
  }
  @Test func durableAdvanceReleasesReservationWithoutAnExtraWakeup() throws {
    var s = Scenario()
    s.core = Core(configuration: Configuration(capacity: 1, bucketAdmission: .removalFenced))
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let read = try operation(s.send(.catchUp(key, through: 1)))
    #expect(dbWork(try s.queue(1)).isEmpty)
    let advanced = s.send(
      .databaseFinished(
        read, .admission(BucketAdmission(position: position(1), removalRevision: 1))))
    #expect(dbWork(advanced) == [.markDispatching(TransactionID(1))])
    #expect(transmissions(advanced).isEmpty)
  }
  @Test func offlineLiveApplyAlsoCarriesRevisionWithoutReservingNetworkCapacity() throws {
    var s = Scenario()
    s.core = Core(configuration: Configuration(capacity: 1, bucketAdmission: .removalFenced))
    s.send(.start(generation: 1))
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let read = s.send(.live(key, Update(sequence: 1, payload: "live", date: 1), generation: 1))
    #expect(dbWork(read) == [.captureBucketAdmission(key, expected: .zero, network: false)])
    #expect(s.core.reservedRequests == 0)
    let evidence = BucketAdmission(position: .zero, removalRevision: 2)
    let apply = s.send(.databaseFinished(try operation(read), .admission(evidence)))
    #expect(
      dbWork(apply).contains {
        if case .applyAdmittedPage(key, evidence, _) = $0 { true } else { false }
      })
    #expect(transmissions(apply).isEmpty)
  }
  @Test func disconnectReleasesReservedSlotAndRequiresFreshEvidence() throws {
    var s = Scenario()
    s.core = Core(configuration: Configuration(capacity: 1, bucketAdmission: .removalFenced))
    let connection = try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let read = try operation(s.send(.catchUp(key, through: 2)))
    s.send(.disconnected(connection))
    #expect(s.core.reservedRequests == 0)
    s.send(
      .databaseFinished(read, .admission(BucketAdmission(position: .zero, removalRevision: 1))))
    let reconnect = s.send(.timeout, at: 10)
    let next = try #require(
      reconnect.compactMap { if case .connect(let id) = $0 { id } else { nil } }.first)
    let ready = try s.authorize(next)
    #expect(dbWork(ready) == [.captureBucketAdmission(key, expected: .zero, network: true)])
    #expect(transmissions(ready).isEmpty)
  }
  @Test func staleAccountNotificationsCannotPopulateReplacementState() throws {
    var s = Scenario()
    try s.open()
    try s.open(generation: 2)
    let key = BucketID(1)
    s.send(.snapshot(key, position(100), generation: 1))
    s.send(.live(key, Update(sequence: 101, payload: "old account"), generation: 1))
    #expect(s.core.cursor(for: key) == nil)
    #expect(s.core.buckets.isEmpty)
  }
  @Test func liveEvidenceCannotBeReusedForALaterNetworkAdmission() throws {
    var s = Scenario()
    s.core = Core(
      configuration: Configuration(
        capacity: 1, maxBufferedUpdates: 1, bucketAdmission: .removalFenced))
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, .zero, generation: 1))
    let liveRead = try operation(
      s.send(.live(key, Update(sequence: 1, payload: "one", date: 1), generation: 1)))
    s.send(.live(key, Update(sequence: 2, payload: "two", date: 1), generation: 1))  // buffer overflow
    let admission = s.send(
      .databaseFinished(liveRead, .admission(BucketAdmission(position: .zero, removalRevision: 1))))
    #expect(dbWork(admission) == [.captureBucketAdmission(key, expected: .zero, network: true)])
    #expect(transmissions(admission).isEmpty)
    let fetch = s.send(
      .databaseFinished(
        try operation(admission), .admission(BucketAdmission(position: .zero, removalRevision: 2))))
    #expect(transmissions(fetch) == [.fetch(key, from: 0, through: 2)])
  }
  @Test func removalConflictReloadsWithoutReusingOldAdmission() throws {
    var s = Scenario()
    s.core = Core(configuration: Configuration(capacity: 1, bucketAdmission: .removalFenced))
    try s.open()
    let key = BucketID(1)
    s.send(.snapshot(key, position(3), generation: 1))
    let read = try operation(s.send(.catchUp(key, through: 5)))
    let fetch = try attempt(
      s.send(
        .databaseFinished(
          read, .admission(BucketAdmission(position: position(3), removalRevision: 1)))))
    let apply = try operation(s.send(.response(fetch, .page(page(3, 5)))))
    let reload = try operation(s.send(.databaseFinished(apply, .conflict)))
    let freshRead = try operation(s.send(.databaseFinished(reload, .bucketState(.zero))))
    s.send(.databaseFinished(apply, .committed(position(5))))
    #expect(s.core.cursor(for: key) == 0)
    let next = s.send(
      .databaseFinished(freshRead, .admission(BucketAdmission(position: .zero, removalRevision: 2)))
    )
    #expect(transmissions(next) == [.fetch(key, from: 0, through: 5)])
  }

}
