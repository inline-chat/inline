/// Recoverable response failures retain demand and durable evidence. They never
/// grant snapshot authority or require a user to poke the scheduling loop.
public enum SyncRetryReason: Equatable, Sendable {
  case requestFailed, invalidPage, invalidHead, invalidRepairSnapshot, unexpectedResponse
}

public enum SyncBlockReason: Equatable, Sendable { case dependencyCycle }

extension RealtimeCore {
  mutating func retrySync(_ key: BucketID, reason: SyncRetryReason) {
    buckets[key]?.pending = nil
    buckets[key]?.admission = nil
    releaseBucketReservation(key)
    let deadline = now + configuration.retryDelay
    buckets[key]?.retryAt = deadline
    output.append(.event(.syncRetryScheduled(key, reason, at: deadline)))
  }
}

extension RealtimeCore {
  mutating func retireBucket(_ key: BucketID) {
    // The server classified this exact child request as terminal. Keep durable
    // state, but do not fabricate completion or keep fetching an inaccessible peer.
    buckets[key]?.pending = nil
    buckets[key]?.inaccessible = true
    buckets[key]?.buffer = [:]
    buckets[key]?.pass = nil
    buckets[key]?.repair = nil
    buckets[key]?.needsAudit = false
    buckets[key]?.retryAt = nil
    buckets[key]?.admission = nil
    releaseBucketReservation(key)
    discovery?.targets.removeValue(forKey: key)
    discovery?.requiredLatest.removeValue(forKey: key)
    for parent in bucketOrder where buckets[parent]?.repair?.snapshot?.children[key] != nil {
      buckets[parent]?.needsAudit = true
    }
    if bootstrap?.children[key] != nil { bootstrap?.needsAudit = true }
    withdrawUnissuedAuditWrites()
    output.append(.event(.bucketRetired(key)))
  }
}

extension RealtimeCore {
  mutating func withdrawUnissuedAuditWrites() {
    // A delayed retry owns no external resource. Invalidation may withdraw it;
    // an already-issued write must instead drain through its actual receipt.
    for operation in database.keys.sorted(by: { $0.serial < $1.serial }) {
      guard let pending = database[operation], pending.retryAt != nil else { continue }
      switch pending.work {
      case .importRepair(let parent, _, _) where buckets[parent]?.needsAudit == true,
        .finalizeRepair(let parent, _, _, _) where buckets[parent]?.needsAudit == true:
        database.removeValue(forKey: operation)
        buckets[parent]?.pending = nil
      case .admitBootstrap where bootstrap?.needsAudit == true:
        database.removeValue(forKey: operation)
        bootstrap?.phase = .children
      default: break
      }
    }
  }
}
