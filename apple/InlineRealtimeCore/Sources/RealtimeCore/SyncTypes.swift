/// Durable bucket coordinate; date is part of admission, not just display metadata.
public struct SyncPosition: Equatable, Sendable {
  public let sequence: Int64
  public let date: Int64
  public init(sequence: Int64, date: Int64) {
    self.sequence = sequence
    self.date = date
  }
  public static let zero = SyncPosition(sequence: 0, date: 0)
}
public enum PageKind: Equatable, Sendable { case slice, empty, tooLong, unknown }
public enum SkipReason: Equatable, Sendable { case irrelevant, snapshotRepairRequired, unknown }
public struct SkippedSequence: Equatable, Sendable {
  public let sequence: Int64
  public let reason: SkipReason
  public init(_ sequence: Int64, reason: SkipReason) {
    self.sequence = sequence
    self.reason = reason
  }
}
public enum RepairReason: Equatable, Sendable { case historyExpired, serverClassifiedGap }
public enum PageDecision: Equatable, Sendable {
  case apply(SyncPosition)
  case repair(SyncPosition, RepairReason)
  case reject
}

extension Page {
  /// Lossless accounting and authority checks mirror the production envelope contract.
  /// No malformed response may promote itself into snapshot-replacement authority.
  public func decision(from start: SyncPosition, through target: Int64) -> PageDecision {
    guard start.sequence >= 0, start.date >= 0, target >= start.sequence,
      through >= start.sequence, through <= target
    else { return .reject }
    if kind == .tooLong {
      return through > start.sequence && date > 0 && updates.isEmpty && skipped.isEmpty
        && sidecars == nil
        ? .repair(SyncPosition(sequence: through, date: max(start.date, date)), .historyExpired)
        : .reject
    }
    guard kind == .slice || kind == .empty else { return .reject }
    let exactEmpty =
      kind == .empty && final && through == start.sequence && through == target
      && date == 0 && updates.isEmpty && skipped.isEmpty && sidecars == nil
    guard date > 0 || exactEmpty, !final || through == target,
      through > start.sequence || exactEmpty, kind != .empty || updates.isEmpty
    else { return .reject }
    var accounted: Set<Int64> = []
    var endDate = max(start.date, date)
    for update in updates {
      guard update.hasSequence, update.supported, update.date >= 0,
        update.sequence > start.sequence,
        update.sequence <= through, accounted.insert(update.sequence).inserted
      else { return .reject }
      endDate = max(endDate, update.date)
    }
    var repair = false
    for skip in skipped {
      guard skip.sequence > start.sequence, skip.sequence <= through,
        accounted.insert(skip.sequence).inserted, skip.reason != .unknown
      else { return .reject }
      repair = repair || skip.reason == .snapshotRepairRequired
    }
    guard Int64(accounted.count) == through - start.sequence else { return .reject }
    let end = SyncPosition(sequence: through, date: endDate)
    return repair ? .repair(end, .serverClassifiedGap) : .apply(end)
  }
}

/// The snapshot importer remains real GRDB work. Its child targets are prerequisites
/// for finalization, not evidence that the parent cursor has already advanced.
public struct RepairSnapshot<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let payload: Payload
  public let position: SyncPosition
  public let children: [BucketID: Int64]
  public init(payload: Payload, position: SyncPosition, children: [BucketID: Int64] = [:]) {
    self.payload = payload
    self.position = position
    self.children = children
  }
}
