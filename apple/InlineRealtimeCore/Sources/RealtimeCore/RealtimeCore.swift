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
  var restorationRejected = false
  var restoringTransactions = false
  var transactions: [TransactionID: PendingTransaction<Payload>] = [:]
  var submissionOrder: [TransactionID] = []
  var finished: [TransactionID: TransactionOutcome] = [:]
  var transactionReservations: Set<TransactionID> = []
  var bucketReservations: Set<BucketID> = []
  var requests: [OperationID: PendingRequest<Payload>] = [:]
  var database: [OperationID: PendingDatabase<Payload>] = [:]
  var bucketOrder: [BucketID] = []
  var buckets: [BucketID: Bucket<Payload>] = [:]
  var bootstrap: Bootstrap<Payload>?
  var discovery: Discovery?
  var lastSyncBucket: BucketID?
  var lastSyncWasDiscovery = true
  var directQueue: [QueuedCall<Payload>] = []
  var lastAdmission: AdmissionClass = .direct
  var closing: Set<OperationID> = []
  var sending: Set<OperationID> = []
  var reportedDrained = false
  var output: [Output<Payload>] = []
  var needsPumpAgain = false

  public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

  public var nextDeadline: Tick? {
    let times =
      [session.deadline, authentication?.deadline] + requests.values.map { Optional($0.deadline) }
      + database.values.map(\.retryAt) + transactions.values.map(\.retryAt)
      + buckets.values.map(\.retryAt) + [discovery?.retryAt]
      + (bootstrap?.retryAt.values.map { Optional($0) } ?? [])
    return (times + directQueue.map(\.expiresAt)).compactMap { $0 }.min()
  }
  public var outstandingReservations: Int {
    transactionReservations.count + bucketReservations.count
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
    case .start(let newGeneration, let startup):
      guard newGeneration > generation else {
        output.append(.event(.blocked("account generation must increase")))
        break
      }
      stopAdmission()
      generation = newGeneration
      transactions = [:]
      submissionOrder = []
      finished = [:]
      buckets = [:]
      bucketOrder = []
      discovery = nil
      bootstrap = nil
      lastSyncBucket = nil
      lastSyncWasDiscovery = true
      directQueue = []
      active = true
      reportedDrained = false
      restorationRejected = false
      restoringTransactions = startup == .restore
      if restoringTransactions { _ = write(.loadTransactions) }
      connect()
    case .retryRestoration:
      if active, restoringTransactions, restorationRejected {
        restorationRejected = false
        _ = write(.loadTransactions)
      }
    case .retryBucket(let key, let sourceGeneration):
      if active, sourceGeneration == generation {
        buckets[key]?.blocked = false
      }
    case .bootstrap(let user):
      if active, bootstrap == nil, discovery == nil, buckets[user]?.pending == nil,
        buckets[user]?.repair == nil, buckets[user]?.blocked != true
      {
        bootstrap = Bootstrap(user: user)
      } else {
        output.append(
          .event(.blocked("bootstrap requires an idle, unblocked User bucket and discovery owner")))
      }
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
      guard active, session != .rejected, !restoringTransactions, transactions[spec.id] == nil,
        finished[spec.id] == nil,
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
    case .request(let call): enqueue(call)
    case .cancelCall(let id): cancelCall(id)
    case .call(let payload):
      if active, session != .rejected, directQueue.count < configuration.maxQueuedCalls {
        directQueue.append(QueuedCall(id: nil, payload: payload, expiresAt: nil))
      } else {
        output.append(.event(.blocked("direct queue unavailable")))
      }
    case .catchUp(let key, let target):
      if active {
        demand(key, through: target)
        observeDiscoveryDemand(key, through: target)
      }
    case .live(let key, let update, let sourceGeneration):
      if active, sourceGeneration == generation {
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
    case .snapshot(let key, let position, let sourceGeneration):
      if active, sourceGeneration == generation, position.sequence >= 0, position.date >= 0 {
        ensureBucket(key)
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
        if bootstrap != nil {
          bootstrap?.discoverAfter = true
          break
        }
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
      needsPumpAgain = false
      pump()
    } while output.count != previousOutputCount || needsPumpAgain
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
    for call in directQueue {
      if let id = call.id { output.append(.event(.callFinished(id, .cancelled))) }
    }
    for attempt in requests.keys.sorted(by: { $0.serial < $1.serial }) {
      output.append(.cancel(attempt))
      if case .directCall(let id, _) = requests[attempt]?.owner {
        output.append(.event(.callFinished(id, .cancelled)))
      }
    }
    requests = [:]
    transactionReservations = []
    bucketReservations = []
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
    bootstrap?.retryAt = [:]
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
    case (.bootstrap(let owner), _): bootstrapResponse(owner, response)
    case (.transaction(let key), .result(let payload)):
      transactions[key]?.phase = .applying
      _ = write(.applyTransaction(key, payload))
    case (.transaction(let key), .rejected): settle(key, .failed)
    case (.bucket(let key, let from, let target, let admission), .page(let page)):
      receivedPage(page, bucket: key, from: from, target: target, admission: admission)
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
    case (.directCall(let id, _), .result(let payload)):
      output.append(.event(.callFinished(id, .result(payload))))
    case (.direct, .result(let payload)): output.append(.event(.directFinished(attempt, payload)))
    default:
      switch request.owner {
      case .transaction(let key): settle(key, .executionUnknown)
      case .bucket(let key, _, _, _), .captureLatest(let key, _, _, _), .repair(let key):
        buckets[key]?.pending = nil
        buckets[key]?.blocked = true
      case .bootstrap: break
      case .discovery: discovery = nil
      case .directCall(let id, _): output.append(.event(.callFinished(id, .failed)))
      case .direct: output.append(.event(.directFinished(attempt, nil)))
      }
      output.append(.event(.blocked("unexpected response kind")))
    }
  }

}
