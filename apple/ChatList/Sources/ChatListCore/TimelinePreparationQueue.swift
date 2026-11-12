/// Coalesces timeline preparation requests without owning worker execution.
///
/// Revisions are caller-provided completion fences. The caller must keep them
/// strictly increasing for the lifetime of the owning coordinator, including
/// across `cancel()`, so a late completion cannot match a later request.
public struct TimelinePreparationQueue<Context: Equatable, Snapshot> {
  public struct Request {
    public let revision: UInt64
    public let context: Context
    public let snapshot: Snapshot

    public init(revision: UInt64, context: Context, snapshot: Snapshot) {
      self.revision = revision
      self.context = context
      self.snapshot = snapshot
    }
  }

  public enum Submission {
    /// The caller should prepare this request now, replacing any prior worker
    /// when the queue's context changed.
    case start(Request)
    /// A compatible request was retained as the newest pending snapshot.
    case coalesced
  }

  public enum FinishResult {
    /// The active revision completed. `next` is now active and should be
    /// prepared, or `nil` when the queue became idle.
    case accepted(next: Request?)
    /// The completion was stale or there was no active request.
    case rejected
  }

  public private(set) var active: Request?
  public private(set) var pending: Request?

  public init() {}

  /// Starts when idle or when context changes. Compatible requests replace
  /// only the pending snapshot, allowing the active request to finish first.
  public mutating func submit(_ request: Request) -> Submission {
    if let newest = pending ?? active {
      precondition(request.revision > newest.revision, "Preparation revisions must increase")
    }

    guard let current = active else {
      active = request
      pending = nil
      return .start(request)
    }

    guard current.context == request.context else {
      active = request
      pending = nil
      return .start(request)
    }

    pending = request
    return .coalesced
  }

  /// Accepts only the active revision and promotes the newest pending request.
  public mutating func finish(revision: UInt64) -> FinishResult {
    guard let current = active, current.revision == revision else { return .rejected }

    guard let next = pending else {
      active = nil
      return .accepted(next: nil)
    }

    active = next
    pending = nil
    return .accepted(next: next)
  }

  /// Invalidates all queued work. Late completions are rejected until a new
  /// request is submitted; callers must continue using fresh revisions.
  public mutating func cancel() {
    active = nil
    pending = nil
  }
}
