/// Discovery checkpoints cannot pass the exact child targets they introduced.
struct Discovery: Sendable {
  var after: Int64
  var requested = true
  var pending: OperationID?
  var checkpoint: Int64?
  var targets: [BucketID: Int64] = [:]
  var requiredLatest: [BucketID: UInt64] = [:]
  var retryAt: Tick?
}

extension RealtimeCore {
  /// The response freezes the round. Hints seen earlier cannot be overwritten by
  /// a lower server target; later hints must not keep extending this checkpoint.
  mutating func observeDiscoveryDemand(_ key: BucketID, through target: Int64?) {
    guard discovery != nil, discovery?.checkpoint == nil else { return }
    if let target, target <= 0 { return }
    let value = target ?? 0
    if let existing = discovery?.targets[key] {
      discovery?.targets[key] = existing == 0 || value == 0 ? 0 : max(existing, value)
    } else {
      discovery?.targets[key] = value
    }
  }

  mutating func pumpDiscovery() {
    if var recovery = discovery, recovery.pending == nil {
      if recovery.retryAt == nil || recovery.retryAt! <= now {
        recovery.retryAt = nil
        discovery = recovery
        if let checkpoint = recovery.checkpoint {
          if discoveryChildrenReady(recovery) {
            let operation = write(.storeCheckpoint(checkpoint))
            discovery?.pending = operation
          }
        } else if session.openConnection != nil, reservedRequests < configuration.capacity,
          nextAdmission == .sync
        {
          discovery?.requested = false
          lastAdmission = .sync
          lastSyncWasDiscovery = true
          let attempt = transmit(.discover(after: recovery.after), owner: .discovery)
          discovery?.pending = attempt
        }
      }
    }
  }

  func discoveryChildrenReady(_ recovery: Discovery) -> Bool {
    recovery.targets.allSatisfy { key, target in
      guard let bucket = buckets[key], bucket.position != nil else { return false }
      if target > 0 { return bucket.cursor! >= target }
      guard let latest = recovery.requiredLatest[key] else { return false }
      return bucket.completedLatest >= latest
    }
  }
}
