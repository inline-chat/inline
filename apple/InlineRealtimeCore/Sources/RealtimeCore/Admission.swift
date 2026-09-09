/// Experimental comparison: cursor-only is the original draft; removal-fenced
/// mode captures real storage evidence after reserving request/send capacity.
public enum BucketAdmissionPolicy: Sendable { case cursorOnly, removalFenced }
public struct BucketAdmission: Equatable, Sendable {
  public let position: SyncPosition
  public let removalRevision: UInt64
  public init(position: SyncPosition, removalRevision: UInt64) {
    self.position = position
    self.removalRevision = removalRevision
  }
}
extension RealtimeCore {
  mutating func captureAdmission(_ key: BucketID, position: SyncPosition, network: Bool) {
    buckets[key]?.admission = nil
    if network { bucketReservations.insert(key) } else { releaseBucketReservation(key) }
    let operation = write(.captureBucketAdmission(key, expected: position, network: network))
    buckets[key]?.pending = operation
  }
  mutating func releaseBucketReservation(_ key: BucketID) {
    if bucketReservations.remove(key) != nil {
      needsPumpAgain = true
    }
  }
  mutating func admissionFinished(
    _ key: BucketID, expected: SyncPosition, network: Bool,
    evidence: BucketAdmission
  ) {
    buckets[key]?.pending = nil
    guard buckets[key]?.position == expected,
      !network || (bucketReservations.contains(key) && session.openConnection != nil)
    else {
      releaseBucketReservation(key)
      return
    }
    // A durable read may legitimately see a lower cursor after destructive removal.
    buckets[key]?.cursor = evidence.position.sequence
    buckets[key]?.date = evidence.position.date
    buckets[key]?.admission = evidence
    buckets[key]?.admissionForNetwork = network
  }
  mutating func writePage(
    _ key: BucketID, expected: SyncPosition, page: Page<Payload>,
    admission: BucketAdmission?
  ) {
    releaseBucketReservation(key)
    buckets[key]?.admission = nil
    let work: DatabaseWork<Payload> =
      admission.map { .applyAdmittedPage(key, $0, page) }
      ?? .applyPage(key, expected: expected, page)
    let operation = write(work)
    buckets[key]?.pending = operation
  }
}
