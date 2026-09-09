// Concrete producer admission for one synchronous owner. This is not an async
// task scheduler: every admitted operation is returned to the external driver.
extension RealtimeCore {
  var reservedRequests: Int {
    let marking = outstandingReservations
    // Server completion does not mean the local writer has released its buffer.
    // Durable dispatch markers reserve this second resource before they persist.
    if sending.count + marking >= configuration.maxPendingSends { return configuration.capacity }
    return marking + requests.count
  }
  mutating func pump() {
    guard active else { return }
    expireQueuedCalls()
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
      transactionReservations.insert(key)
      lastAdmission = .transaction
      _ = write(.markDispatching(key))
    }
    pumpBootstrap()
    if !lastSyncWasDiscovery { pumpDiscovery() }
    pumpBuckets()
    pumpDiscovery()
    while !directQueue.isEmpty, session.openConnection != nil,
      reservedRequests < configuration.capacity, nextAdmission == .direct
    {
      lastAdmission = .direct
      let call = directQueue.removeFirst()
      let owner: RequestOwner =
        call.id.map { .directCall($0, expiresAt: call.expiresAt) } ?? .direct
      _ = transmit(.direct(call.payload), owner: owner, expiresAt: call.expiresAt)
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
    let bucketReady = buckets.contains { key, bucket in
      if bootstrap?.user == key && bootstrap?.blocksUser == true { return false }
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
      case .sync: bucketReady || discoveryReady || bootstrapReady
      case .direct: !directQueue.isEmpty
      }
    }
  }

}
