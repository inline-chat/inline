/// Experimental coordination engine. Each call returns a complete output batch,
/// including its next deadline: there is no asynchronous work or hidden event pump.
public struct RealtimeCore<Payload: Equatable & Sendable>: Sendable {
  public let configuration: Configuration
  public private(set) var generation: UInt64 = 0
  public private(set) var now: Tick = 0
  var serial: UInt64 = 0
  var active = false
  var session: Session = .stopped
  var authentication: Authentication?
  var credentialOperations: [OperationID: PendingCredential] = [:]
  var transactions: [TransactionID: PendingTransaction<Payload>] = [:]
  var submissionOrder: [TransactionID] = []
  var finished: [TransactionID: TransactionOutcome] = [:]
  var requests: [OperationID: PendingRequest<Payload>] = [:]
  var database: [OperationID: PendingDatabase<Payload>] = [:]
  var buckets: [BucketID: Bucket<Payload>] = [:]
  var discovery: Discovery?
  var lastSyncBucket: BucketID?
  var lastSyncWasDiscovery = true
  var directQueue: [Payload] = []
  var lastAdmission: AdmissionClass = .direct
  var closing: Set<OperationID> = []
  var sending: Set<OperationID> = []
  var reportedDrained = false
  var output: [Output<Payload>] = []

  public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

  public var nextDeadline: Tick? {
    let times =
      [session.deadline, authentication?.deadline] + requests.values.map { Optional($0.deadline) }
      + database.values.map(\.retryAt) + transactions.values.map(\.retryAt)
      + buckets.values.map(\.retryAt) + [discovery?.retryAt]
    return times.compactMap { $0 }.min()
  }
  public var outstandingRequests: Int { requests.count }
  public var outstandingSends: Int { sending.count }
  public var outstandingDatabaseOperations: Int {
    database.values.filter { $0.retryAt == nil }.count
  }
  public func cursor(for bucket: BucketID) -> Int64? { buckets[bucket]?.cursor }
  public func outcome(for transaction: TransactionID) -> TransactionOutcome? {
    finished[transaction]
  }

  /// Inputs use concrete workflow names rather than a generic command/effect wrapper.
  /// Time must be monotonic. Returned I/O outputs are admitted work, even if a
  /// following stop arrives before the caller's executor has started that work.
  public mutating func handle(_ input: Input<Payload>, at time: Tick) -> [Output<Payload>] {
    precondition(
      time >= now && time <= Int64.max - max(configuration.requestTimeout, configuration.retryDelay)
    )
    now = time
    output = []
    // Authorization expiry gates admission even when a DB completion arrives at
    // the rotation deadline before a timeout callback.
    if let auth = authentication, case .accepted(let temporary) = auth.phase,
      temporary.rotateAt <= now
    {
      disconnect(auth.connection)
    }
    if let deadline = session.deadline, deadline < now, let connection = session.connection {
      disconnect(connection)
    }
    switch input {
    case .start(let newGeneration):
      guard newGeneration > generation else {
        return [.event(.blocked("account generation must increase")), .wait(until: nextDeadline)]
      }
      stopAdmission()
      generation = newGeneration
      transactions = [:]
      submissionOrder = []
      finished = [:]
      buckets = [:]
      discovery = nil
      lastSyncBucket = nil
      lastSyncWasDiscovery = true
      directQueue = []
      active = true
      reportedDrained = false
      connect()
    case .connected(let id):
      if case .connecting(id, _) = session {
        session = .authorizing(id, deadline: now + configuration.requestTimeout)
        beginAuthorization(id)
      }
    case .credentialsFinished(let id, let result): credentialsFinished(id, result)
    case .authorizationRevoked(let id):
      if session.connection == id { rejectAuthorization() }
    case .disconnected(let id):
      closing.remove(id)
      if session.connection == id { disconnect(id, alreadyClosed: true) }
    case .submit(let spec):
      guard active, transactions[spec.id] == nil, finished[spec.id] == nil,
        !spec.requires.contains(spec.id), !introducesCycle(spec)
      else {
        output.append(.event(.submissionRejected(spec.id)))
        break
      }
      transactions[spec.id] = PendingTransaction(spec: spec)
      submissionOrder.append(spec.id)
      _ = write(.optimistic(spec))
    case .cancel(let id):
      if var transaction = transactions[id] {
        transaction.cancellationRequested = true
        transactions[id] = transaction
        if case .ready = transaction.phase { settle(id, .cancelled) }
        if case .requesting(let attempt) = transaction.phase {
          output.append(.cancel(attempt))
          if let request = requests.removeValue(forKey: attempt) {
            requestFailed(request, uncertain: true)
          }
        }
      }
    case .call(let payload):
      if active { directQueue.append(payload) }
    case .catchUp(let key, let target):
      if active {
        demand(key, through: target)
        observeDiscoveryDemand(key, through: target)
      }
    case .live(let key, let update):
      if active {
        guard update.hasSequence, update.sequence > 0 else { break }
        demand(key, through: update.sequence)
        observeDiscoveryDemand(key, through: update.sequence)
        // Uninterpretable live payloads retain the gap but cannot certify it.
        guard update.supported, update.date >= 0 else {
          let fence = max(buckets[key]?.requiresAuthoritativeThrough ?? 0, update.sequence)
          buckets[key]?.requiresAuthoritativeThrough = fence
          buckets[key]?.buffer.removeValue(forKey: update.sequence)
          break
        }
        if let buffered = buckets[key]?.buffer[update.sequence], buffered != update {
          // Contradictory payloads are not resolved by arrival order. Fetch authority.
          let fence = max(buckets[key]?.requiresAuthoritativeThrough ?? 0, update.sequence)
          buckets[key]?.requiresAuthoritativeThrough = fence
          buckets[key]?.buffer.removeValue(forKey: update.sequence)
          break
        }
        if update.sequence > (buckets[key]?.cursor ?? 0) {
          buckets[key]?.buffer[update.sequence] = update
          if (buckets[key]?.buffer.count ?? 0) > configuration.maxBufferedUpdates {
            // Buffered payloads are only an optimization; retained target drives repair.
            buckets[key]?.buffer = [:]
          }
        }
      }
    case .snapshot(let key, let position):
      if active, position.sequence >= 0, position.date >= 0 {
        if buckets[key] == nil { buckets[key] = Bucket() }
        if position.sequence >= (buckets[key]?.cursor ?? 0) {
          buckets[key]?.cursor = position.sequence
          let date = max(buckets[key]?.date ?? 0, position.date)
          buckets[key]?.date = date
        }
        let cursor = buckets[key]?.cursor ?? 0
        let buffer = buckets[key]?.buffer.filter { $0.key > cursor } ?? [:]
        buckets[key]?.buffer = buffer
      }
    case .discover(let after):
      if active, after >= 0 {
        if discovery == nil {
          discovery = Discovery(after: after)
          for key in buckets.keys.sorted() {
            guard let bucket = buckets[key], bucket.hasDemand else { continue }
            observeDiscoveryDemand(
              key,
              through: bucket.latest > bucket.completedLatest ? nil : bucket.target)
          }
        } else {
          discovery?.requested = true
        }
      }
    case .databaseFinished(let id, let result): databaseFinished(id, result)
    case .response(let id, let result):
      if let request = requests.removeValue(forKey: id) {
        if request.deadline < now {
          output.append(.cancel(id))
          requestFailed(request, uncertain: true)
        } else {
          received(id, request, result)
        }
      }
    case .sendFinished(let id): sending.remove(id)
    case .sendFailed(let id, let failure):
      sending.remove(id)
      if let request = requests.removeValue(forKey: id) {
        requestFailed(request, uncertain: failure == .executionUnknown)
      }
    case .timeout: break
    case .stop: stopAdmission()
    }
    expire()
    // Drain synchronously to a stable boundary, including work unblocked by
    // earlier admission decisions in this same call.
    var previousOutputCount: Int
    repeat {
      previousOutputCount = output.count
      pump()
    } while output.count != previousOutputCount
    if !active, database.isEmpty, credentialOperations.isEmpty, closing.isEmpty, sending.isEmpty,
      !reportedDrained
    {
      reportedDrained = true
      output.append(.event(.drained))
    }
    output.append(.wait(until: nextDeadline))
    let result = output
    output = []
    return result
  }

  mutating func id() -> OperationID {
    serial += 1
    return OperationID(generation: generation, serial: serial)
  }

  mutating func stopAdmission() {
    cancelAuthorization()
    if let connection = session.connection {
      closing.insert(connection)
      output.append(.close(connection))
    }
    for attempt in requests.keys.sorted(by: { $0.serial < $1.serial }) {
      output.append(.cancel(attempt))
    }
    requests = [:]
    active = false
    session = .stopped
    directQueue = []
    // Retry entries have not been issued, so they are not outstanding I/O.
    for key in Array(database.keys) where database[key]?.retryAt != nil {
      database.removeValue(forKey: key)
    }
    for key in transactions.keys { transactions[key]?.retryAt = nil }
    for key in buckets.keys { buckets[key]?.retryAt = nil }
    discovery?.retryAt = nil
  }

  mutating func expire() {
    guard active else { return }
    if let deadline = session.deadline, deadline <= now {
      if case .backingOff = session {
        connect()
      } else if let connection = session.connection {
        disconnect(connection)
      }
    }
    for attempt in requests.keys.sorted(by: { $0.serial < $1.serial }) {
      if let request = requests[attempt], request.deadline <= now {
        requests.removeValue(forKey: attempt)
        output.append(.cancel(attempt))
        requestFailed(request, uncertain: true)
      }
    }
  }

  mutating func received(
    _ attempt: OperationID, _ request: PendingRequest<Payload>, _ response: Response<Payload>
  ) {
    if case .rejectedBeforeExecution = response {
      requestFailed(request, uncertain: false)
      return
    }
    switch (request.owner, response) {
    case (.transaction(let key), .result(let payload)):
      transactions[key]?.phase = .applying
      _ = write(.applyTransaction(key, payload))
    case (.transaction(let key), .rejected): settle(key, .failed)
    case (.bucket(let key, let from, let target), .page(let page)):
      receivedPage(page, bucket: key, from: from, target: target)
    case (.captureLatest(let key, let start, let latest, let minimum), .head(let position)):
      buckets[key]?.pending = nil
      if let current = buckets[key]?.position,
        position.sequence >= start.sequence, position.date >= start.date
      {
        buckets[key]?.pass = CatchUpPass(
          target: max(current.sequence, max(minimum, position.sequence)), latest: latest)
      } else {
        buckets[key]?.blocked = true
        output.append(.event(.blocked("invalid latest coordinate")))
      }
    case (.repair(let key), .repairSnapshot(let snapshot)): receivedRepair(snapshot, bucket: key)
    case (.discovery, .discovery(let checkpoint, let targets)):
      guard let current = discovery, checkpoint >= current.after,
        targets.values.allSatisfy({ $0 >= 0 })
      else {
        discovery?.pending = nil
        output.append(.event(.blocked("invalid discovery")))
        discovery = nil
        return
      }
      discovery?.pending = nil
      discovery?.checkpoint = checkpoint
      var combined = current.targets
      for (key, target) in targets {
        if let existing = combined[key] {
          combined[key] = existing == 0 || target == 0 ? 0 : max(existing, target)
        } else {
          combined[key] = target
        }
      }
      discovery?.targets = combined
      for key in combined.keys.sorted() {
        let target = combined[key]!
        demand(key, through: target > 0 ? target : nil)
        if target == 0 { discovery?.requiredLatest[key] = buckets[key]?.latest }
      }
    case (.direct, .result(let payload)): output.append(.event(.directFinished(attempt, payload)))
    default:
      switch request.owner {
      case .transaction(let key): settle(key, .executionUnknown)
      case .bucket(let key, _, _), .captureLatest(let key, _, _, _), .repair(let key):
        buckets[key]?.pending = nil
        buckets[key]?.blocked = true
      case .discovery: discovery = nil
      case .direct: output.append(.event(.directFinished(attempt, nil)))
      }
      output.append(.event(.blocked("unexpected response kind")))
    }
  }

  var reservedRequests: Int {
    transactions.values.filter { $0.phase == .marking }.count + requests.count
  }
  mutating func pump() {
    guard active else { return }
    pumpAuthorization()
    for operation in database.keys.sorted(by: { $0.serial < $1.serial }) {
      if let pending = database[operation], let time = pending.retryAt, time <= now {
        database[operation]?.retryAt = nil
        output.append(.database(operation, pending.work))
      }
    }
    for key in submissionOrder {
      guard let transaction = transactions[key], transaction.phase == .ready else { continue }
      if let retry = transaction.retryAt, retry > now { continue }
      transactions[key]?.retryAt = nil
      if transaction.spec.requires.contains(where: {
        finished[$0] != nil && finished[$0] != .applied
      }) {
        settle(key, .dependencyFailed)
        continue
      }
      guard transaction.spec.requires.allSatisfy({ finished[$0] == .applied }),
        session.openConnection != nil,
        reservedRequests < configuration.capacity, nextAdmission == .transaction
      else { continue }
      if let lane = transaction.spec.lane, !transaction.ownsLane {
        let laneBusy = transactions.values.contains { $0.ownsLane && $0.spec.lane == lane }
        // Arrival order, not transaction numeric identity, establishes lane ordering.
        let earlier = submissionOrder.prefix(while: { $0 != key }).contains {
          transactions[$0]?.spec.lane == lane
        }
        if laneBusy || earlier { continue }
      }
      transactions[key]?.ownsLane = true
      transactions[key]?.phase = .marking
      lastAdmission = .transaction
      _ = write(.markDispatching(key))
    }
    if !lastSyncWasDiscovery { pumpDiscovery() }
    pumpBuckets()
    pumpDiscovery()
    while !directQueue.isEmpty, session.openConnection != nil,
      reservedRequests < configuration.capacity, nextAdmission == .direct
    {
      lastAdmission = .direct
      _ = transmit(.direct(directQueue.removeFirst()), owner: .direct)
    }
  }

  /// Fairness is between the three concrete producers, not a generic task scheduler.
  var nextAdmission: AdmissionClass? {
    let transactionReady = submissionOrder.contains { key in
      guard let transaction = transactions[key], transaction.phase == .ready,
        transaction.retryAt.map({ $0 <= now }) ?? true,
        transaction.spec.requires.allSatisfy({ finished[$0] == .applied })
      else { return false }
      guard let lane = transaction.spec.lane, !transaction.ownsLane else { return true }
      return !transactions.values.contains(where: { $0.ownsLane && $0.spec.lane == lane })
        && !submissionOrder.prefix(while: { $0 != key }).contains(where: {
          transactions[$0]?.spec.lane == lane
        })
    }
    let bucketReady = buckets.values.contains { bucket in
      guard let cursor = bucket.cursor, bucket.pending == nil, !bucket.blocked,
        bucket.hasDemand, bucket.retryAt.map({ $0 <= now }) ?? true
      else { return false }
      if let repair = bucket.repair {
        if case .fetching = repair.phase { return true }
        return false
      }
      let canApplyLive =
        bucket.latest == bucket.completedLatest && cursor >= bucket.requiresAuthoritativeThrough
        && cursor < Int64.max
        && bucket.buffer[cursor + 1] != nil
      return !canApplyLive
    }
    let discoveryReady =
      discovery.map {
        $0.pending == nil && $0.checkpoint == nil && ($0.retryAt.map { $0 <= now } ?? true)
      } ?? false
    let order: [AdmissionClass]
    switch lastAdmission {
    case .transaction: order = [.sync, .direct, .transaction]
    case .sync: order = [.direct, .transaction, .sync]
    case .direct: order = [.transaction, .sync, .direct]
    }
    return order.first { candidate in
      switch candidate {
      case .transaction: transactionReady
      case .sync: bucketReady || discoveryReady
      case .direct: !directQueue.isEmpty
      }
    }
  }

}
