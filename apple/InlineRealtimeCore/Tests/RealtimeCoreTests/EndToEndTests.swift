import Testing

@testable import RealtimeCore

private struct Schedule {
  var state: UInt64
  mutating func index(_ count: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 32) % UInt64(count))
  }
}

@Suite struct EndToEndTests {
  @Test(arguments: 0..<1024)
  func restoredAccountBootstrapReconnectAndShutdown(_ seed: Int) throws {
    #expect(try run(seed) == run(seed), "trace must replay exactly for seed \(seed)")
  }

  private func run(_ seed: Int) throws -> [Action] {
    var s = Scenario(capacity: 1 + seed % 4)
    s.core = Core(
      configuration: Configuration(
        capacity: 1 + seed % 4, maxPendingSends: 8, bucketAdmission: .removalFenced))
    var random = Schedule(state: UInt64(seed))
    let user = BucketID(100)
    var pending = s.send(.start(generation: 1, transactions: .restore))
    pending += s.send(.bootstrap(user: user))
    pending += s.send(.discover(after: 0))
    pending += s.send(.live(user, Update(sequence: 13, payload: "live", date: 9), generation: 1))
    pending += s.send(.request(Call(id: CallID(1), payload: "direct", expiresAt: 500)))
    var failures = seed % 4
    var sendFailures = seed % 3
    var disconnected = false
    var rejectedRestore = false
    var checkpoints = 0
    var steps = 0
    while true {
      pending.removeAll { if case .wait = $0 { true } else { false } }
      if pending.isEmpty {
        if s.core.bootstrap == nil, !s.core.restoringTransactions, s.core.transactions.isEmpty,
          s.core.discovery == nil,
          s.core.buckets.values.allSatisfy({ !$0.hasDemand && $0.pending == nil }),
          s.core.outstandingRequests == 0, s.core.outstandingDatabaseOperations == 0,
          s.core.outstandingSends == 0, s.core.closing.isEmpty
        {
          break
        }
        let deadline = try #require(
          s.core.nextDeadline, "seed \(seed): work stranded without a wakeup")
        try #require(
          deadline < 10_000,
          "seed \(seed): only unrelated maintenance can wake stranded business work")
        pending += s.send(.timeout, at: deadline)
      } else {
        let action = pending.remove(at: random.index(pending.count))
        switch action {
        case .connect(let id): pending += s.send(.connected(id))
        case .credentials(let id, _, let work):
          let result: CredentialResult
          switch work {
          case .load:
            result = .loaded(
              StoredCredentials(
                permanent: CredentialHandle(1),
                temporary: TemporaryAuthorization(handle: CredentialHandle(2), rotateAt: 1_000_000))
            )
          case .verify: result = .verified
          case .createTemporary:
            result = .created(
              TemporaryAuthorization(handle: CredentialHandle(2), rotateAt: 1_000_000))
          case .save: result = .saved
          }
          pending += s.send(.credentialsFinished(id, result))
        case .close(let id): pending += s.send(.disconnected(id))
        case .event(.restorationRejected): pending += s.send(.retryRestoration)
        case .event(.transactionsReady):
          pending += s.send(
            .submit(
              Tx(id: TransactionID(3), payload: "new", lane: "chat", requires: [TransactionID(2)])))
          pending += s.send(.submit(Tx(id: TransactionID(4), payload: "safe", replay: .replaySafe)))
        case .database(let id, let work):
          if failures > 0 && random.index(4) == 0 {
            failures -= 1
            pending += s.send(.databaseFinished(id, .failed))
            pending += s.send(.databaseFinished(id, .done))  // duplicate old attempt
            break
          }
          let result: DatabaseResult<String>
          switch work {
          case .loadTransactions:
            if seed % 4 == 0 && !rejectedRestore {
              rejectedRestore = true
              let duplicate = StoredTransaction(
                Tx(id: TransactionID(1), payload: "duplicate"), dispatch: .queued,
                createdAtUnixSeconds: 90)
              result = .transactions(
                TransactionRestoration(records: [duplicate, duplicate], observedUnixSeconds: 100))
              break
            }
            result = .transactions(
              TransactionRestoration(
                records: [
                  StoredTransaction(
                    Tx(id: TransactionID(1), payload: "unknown"), dispatch: .mayHaveExecuted,
                    createdAtUnixSeconds: 90),
                  StoredTransaction(
                    Tx(id: TransactionID(2), payload: "queued", replay: .replaySafe, lane: "chat"),
                    dispatch: .queued, createdAtUnixSeconds: 91),
                ], observedUnixSeconds: 100))
          case .importBootstrapProjection(let kind, _, _):
            result = .projection(
              kind == .chats
                ? ProjectionReceipt(
                  evidence: "catalog", seeds: [BucketID(1): .zero, BucketID(2): .zero],
                  targets: [BucketID(1): 3, BucketID(2): 0])
                : ProjectionReceipt(evidence: "projection"))
          case .admitBootstrap(_, let before, _, _, _): result = .committed(before)
          case .captureBucketAdmission(_, let expected, _):
            result = .admission(BucketAdmission(position: expected, removalRevision: 7))
          case .applyAdmittedPage(_, let admission, let page):
            result = .committed(
              position(page.through, date: max(admission.position.date, page.date)))
          case .loadBucket: result = .bucketState(.zero)
          case .applyPage(_, let expected, let page):
            result = .committed(position(page.through, date: max(expected.date, page.date)))
          case .finalizeRepair(_, _, let snapshot, _): result = .committed(snapshot.position)
          default: result = .done
          }
          pending += s.send(.databaseFinished(id, result))
        case .transmit(let id, _, let request):
          if sendFailures > 0 && random.index(4) == 0 {
            sendFailures -= 1
            pending += s.send(.sendFailed(id, .knownUnsent))
            break
          }
          let response: Response<String>
          switch request {
          case .bootstrapCheckpoint:
            checkpoints += 1
            response = .head(position(checkpoints == 1 ? 10 : 12, date: checkpoints == 1 ? 7 : 8))
          case .bootstrapProjection: response = .result("projection")
          case .captureLatest: response = .head(position(2))
          case .fetch(_, let from, let through): response = .page(page(from, through))
          case .discover:
            response = .discovery(
              checkpoint: 9, targets: [user: 13, BucketID(1): 3, BucketID(2): 2])
          case .repairSnapshot: throw TestFailure.unexpectedRepair
          default: response = .result("result")
          }
          pending += s.send(.response(id, response))
          pending += s.send(.sendFinished(id))
        default: break
        }
      }
      if !disconnected, steps >= 25, let connection = s.core.session.openConnection {
        disconnected = true
        pending += s.send(.disconnected(connection))
      }
      if seed % 2 == 0, steps == 40, let deadline = s.core.nextDeadline, deadline < 10_000 {
        // Deliver a real emitted deadline before outstanding I/O completes.
        pending += s.send(.timeout, at: deadline)
      }
      if seed < 16 { try assertLifecycleBoundary(s) }
      steps += 1
      try #require(steps < 1000, "seed \(seed): non-converging trace")
    }
    #expect(s.core.outcome(for: TransactionID(1)) == .executionUnknown)
    #expect(s.core.outcome(for: TransactionID(2)) == .applied)
    #expect(
      [TransactionOutcome.applied, .executionUnknown].contains(
        s.core.outcome(for: TransactionID(3)) ?? .failed))
    #expect(s.core.outcome(for: TransactionID(4)) == .applied)
    #expect(
      s.trace.filter { if case .event(.callFinished(CallID(1), _)) = $0 { true } else { false } }
        .count == 1)
    #expect(s.core.cursor(for: user) == 13)
    #expect(s.trace.contains(.event(.bootstrapFinished)))
    #expect(s.trace.contains(.event(.checkpointStored(9))))
    let stopped = s.send(.stop)
    for action in stopped { if case .close(let id) = action { s.send(.disconnected(id)) } }
    #expect(s.trace.last(where: { if case .event(.drained) = $0 { true } else { false } }) != nil)
    return s.trace
  }
  /// Fork the actual composed engine at each boundary. These are stale receipts,
  /// not simulated DB state: no completion may mutate the replacement account.
  private func assertLifecycleBoundary(_ original: Scenario) throws {
    for replace in [false, true] {
      var fork = Scenario()
      fork.core = original.core
      fork.now = original.now
      let writes = Array(fork.core.database.keys)
      let credentials = Array(fork.core.credentialOperations.keys)
      let sends = Array(fork.core.sending)
      if replace { fork.send(.start(generation: 2)) } else { fork.send(.stop) }
      for id in writes {
        let completed = fork.send(.databaseFinished(id, .done))
        #expect(
          !completed.contains { if case .event(.transactionFinished) = $0 { true } else { false } })
        #expect(!completed.contains(.event(.bootstrapFinished)))
      }
      for id in credentials { fork.send(.credentialsFinished(id, .transientFailure)) }
      for id in sends {
        fork.send(.response(id, .result("late")))
        fork.send(.sendFinished(id))
      }
      if replace {
        #expect(fork.core.generation == 2)
        #expect(fork.core.transactions.isEmpty)
        #expect(fork.core.buckets.isEmpty)
        #expect(fork.core.bootstrap == nil)
        fork.send(.stop)
      }
      for id in Array(fork.core.closing) { fork.send(.disconnected(id)) }
      #expect(fork.core.outstandingDatabaseOperations == 0)
      #expect(fork.core.outstandingSends == 0)
      #expect(
        fork.trace.filter { if case .event(.drained) = $0 { true } else { false } }.count == 1)
    }
  }

}
