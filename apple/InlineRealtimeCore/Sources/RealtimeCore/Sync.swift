extension RealtimeCore {
  mutating func receivedPage(
    _ page: Page<Payload>, bucket key: BucketID,
    from start: SyncPosition, target: Int64, admission: BucketAdmission?
  ) {
    guard buckets[key]?.position == start else {
      // A snapshot committed while the fetch was running. Do not even propose
      // stale sidecars; reconsider retained demand from the current coordinate.
      buckets[key]?.pending = nil
      return
    }
    switch page.decision(from: start, through: target) {
    case .reject:
      buckets[key]?.pending = nil
      buckets[key]?.blocked = true
      output.append(.event(.blocked("malformed or non-progress page")))
    case .apply:
      writePage(key, expected: start, page: page, admission: admission)
    case .repair(let boundary, let reason):
      buckets[key]?.pending = nil
      buckets[key]?.repair = BucketRepair(boundary: boundary, expected: start, reason: reason)
    }
  }

  mutating func pumpBuckets() {
    let keys = bucketOrder
    let start = lastSyncBucket.flatMap { last in keys.firstIndex { $0 > last } } ?? 0
    for offset in keys.indices {
      let key = keys[(start + offset) % keys.count]
      if bootstrap?.user == key && bootstrap?.blocksUser == true { continue }
      guard var bucket = buckets[key], bucket.pending == nil, !bucket.blocked else { continue }
      if let retry = bucket.retryAt, retry > now { continue }
      bucket.retryAt = nil
      buckets[key] = bucket
      guard let position = bucket.position else {
        let operation = write(.loadBucket(key))
        buckets[key]?.pending = operation
        continue
      }
      if let repair = bucket.repair {
        switch repair.phase {
        case .fetching:
          if session.openConnection != nil, reservedRequests < configuration.capacity,
            nextAdmission == .sync
          {
            lastAdmission = .sync
            lastSyncBucket = key
            lastSyncWasDiscovery = false
            let operation = transmit(
              .repairSnapshot(key, repair.boundary, repair.reason), owner: .repair(key))
            buckets[key]?.pending = operation
          }
        case .waitingForChildren:
          if let snapshot = repair.snapshot, repairChildrenReady(repair) {
            buckets[key]?.repair?.phase = .finalizing
            let evidence = snapshot.children.keys.reduce(into: [BucketID: SyncPosition]()) {
              result, child in
              result[child] = buckets[child]?.position
            }
            let operation = write(
              .finalizeRepair(key, expected: repair.expected, snapshot, children: evidence))
            buckets[key]?.pending = operation
          }
        default: break
        }
        continue
      }
      if let pass = bucket.pass, position.sequence >= pass.target {
        bucket.completedLatest = max(bucket.completedLatest, pass.latest)
        bucket.pass = nil
        buckets[key] = bucket
      }
      if !bucket.hasDemand {
        releaseBucketReservation(key)
        buckets[key]?.admission = nil
        if !bucket.notified {
          buckets[key]?.notified = true
          output.append(.event(.caughtUp(key, through: position.sequence)))
        }
        continue
      }
      if bucket.latest == bucket.completedLatest,
        position.sequence >= bucket.requiresAuthoritativeThrough,
        position.sequence < Int64.max,
        bucket.buffer[position.sequence + 1] != nil
      {
        if configuration.bucketAdmission == .removalFenced && bucket.admission == nil {
          captureAdmission(key, position: position, network: false)
          continue
        }
        var updates: [Update<Payload>] = []
        var end = position.sequence
        while end < Int64.max, let update = bucket.buffer[end + 1] {
          end += 1
          updates.append(update)
        }
        let page = Page(
          through: end, date: max(position.date, updates.map(\.date).max() ?? 0), final: false,
          updates: updates)
        writePage(key, expected: position, page: page, admission: bucket.admission)
      } else if session.openConnection != nil,
        bucketReservations.contains(key)
          || (reservedRequests < configuration.capacity && nextAdmission == .sync)
      {
        lastAdmission = .sync
        lastSyncBucket = key
        lastSyncWasDiscovery = false
        if bucket.pass == nil && bucket.latest > bucket.completedLatest {
          let operation = transmit(
            .captureLatest(key),
            owner: .captureLatest(
              key, from: position, latest: bucket.latest, minimum: bucket.target))
          buckets[key]?.pending = operation
        } else {
          if configuration.bucketAdmission == .removalFenced
            && (bucket.admission == nil || !bucket.admissionForNetwork)
          {
            captureAdmission(key, position: position, network: true)
            continue
          }
          let pass =
            bucket.pass ?? CatchUpPass(target: bucket.target, latest: bucket.completedLatest)
          buckets[key]?.pass = pass
          releaseBucketReservation(key)
          buckets[key]?.admission = nil
          let operation = transmit(
            .fetch(key, from: position.sequence, through: pass.target),
            owner: .bucket(key, from: position, target: pass.target, admission: bucket.admission))
          buckets[key]?.pending = operation
        }
      }
    }
  }

  mutating func receivedRepair(_ snapshot: RepairSnapshot<Payload>, bucket key: BucketID) {
    guard let repair = buckets[key]?.repair,
      snapshot.position.sequence >= repair.boundary.sequence,
      snapshot.position.date >= repair.boundary.date, snapshot.position.date > 0,
      !snapshot.children.keys.contains(key), snapshot.children.values.allSatisfy({ $0 >= 0 }),
      !repairCycle(parent: key, children: Set(snapshot.children.keys))
    else {
      buckets[key]?.pending = nil
      buckets[key]?.blocked = true
      output.append(.event(.blocked("invalid repair snapshot or dependency cycle")))
      return
    }
    buckets[key]?.repair?.snapshot = snapshot
    buckets[key]?.repair?.phase = .importing
    let operation = write(.importRepair(key, expected: repair.expected, snapshot))
    buckets[key]?.pending = operation
  }
  func repairCycle(parent: BucketID, children: Set<BucketID>) -> Bool {
    var work = Array(children)
    var seen: Set<BucketID> = []
    while let child = work.popLast() {
      if child == parent { return true }
      if seen.insert(child).inserted {
        if let descendants = buckets[child]?.repair?.snapshot?.children.keys {
          work.append(contentsOf: descendants)
        }
        if child == bootstrap?.user, let children = bootstrap?.children.keys {
          work.append(contentsOf: children)
        }
      }
    }
    return false
  }
  func repairChildrenReady(_ repair: BucketRepair<Payload>) -> Bool {
    guard let snapshot = repair.snapshot else { return false }
    return snapshot.children.allSatisfy { key, target in
      guard let bucket = buckets[key], bucket.position != nil else { return false }
      if target > 0 { return (bucket.cursor ?? -1) >= target }
      guard let demand = repair.requiredLatest[key] else { return false }
      return bucket.completedLatest >= demand
    }
  }
}
