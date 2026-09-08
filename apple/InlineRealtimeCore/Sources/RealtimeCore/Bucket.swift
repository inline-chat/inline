struct Bucket<Payload: Equatable & Sendable>: Sendable {
  var cursor: Int64?
  var date: Int64 = 0
  var pass: CatchUpPass?
  var repair: BucketRepair<Payload>?
  var position: SyncPosition? { cursor.map { SyncPosition(sequence: $0, date: date) } }
  var target: Int64 = 0
  var requiresAuthoritativeThrough: Int64 = 0
  var latest: UInt64 = 0
  var completedLatest: UInt64 = 0
  var pending: OperationID?
  var retryAt: Tick?
  var blocked = false
  var buffer: [Int64: Update<Payload>] = [:]
  var notified = false
  var hasDemand: Bool { cursor == nil || target > (cursor ?? 0) || latest > completedLatest }
}

extension RealtimeCore {
  mutating func demand(_ key: BucketID, through target: Int64?) {
    if let target, target < 0 { return }
    if buckets[key] == nil { buckets[key] = Bucket() }
    if let target {
      let nextTarget = max(buckets[key]?.target ?? 0, target)
      buckets[key]?.target = nextTarget
    } else {
      buckets[key]?.latest += 1
    }
    buckets[key]?.notified = false
  }
}

struct CatchUpPass: Sendable {
  let target: Int64
  let latest: UInt64
}
struct BucketRepair<Payload: Equatable & Sendable>: Sendable {
  enum Phase: Sendable { case fetching, importing, waitingForChildren, finalizing }
  let boundary: SyncPosition
  let expected: SyncPosition
  let reason: RepairReason
  var phase: Phase = .fetching
  var snapshot: RepairSnapshot<Payload>?
  var requiredLatest: [BucketID: UInt64] = [:]
}
