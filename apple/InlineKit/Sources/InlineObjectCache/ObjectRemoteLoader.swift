/// What one remote fetch did with its batch. An ID in neither set was not there to fetch.
public struct ObjectFetchOutcome<ID: Hashable & Sendable>: Sendable {
  /// Fetched and saved.
  public var resolved: Set<ID>
  /// Could not be asked for or answered this time; worth another attempt.
  public var failed: Set<ID>

  public init(resolved: Set<ID> = [], failed: Set<ID> = []) {
    self.resolved = resolved
    self.failed = failed
  }
}

/// Fetches records that are missing locally from a slower place, such as a server.
///
/// Callers `ensure` IDs; the loader coalesces nearby requests into batches, never
/// fetches one ID twice at once, and stops asking for an ID that keeps failing or
/// that the remote does not have until `Policy.retryAfter` has passed.
///
/// The loader stores nothing itself: `fetch` saves what it receives wherever the
/// local records live, and the cache picks the change up from there.
@MainActor
public final class ObjectRemoteLoader<ID: Hashable & Sendable> {
  public struct Policy: Sendable {
    /// Requests arriving within this window share one fetch.
    public var coalesceWindow: Duration
    /// Most IDs sent in one fetch.
    public var batchSize: Int
    /// Fetches for one ID before it is left alone for `retryAfter`.
    public var maxAttempts: Int
    /// How long an ID is left alone after it exhausted its attempts or the remote reported it absent.
    public var retryAfter: Duration

    public init(
      coalesceWindow: Duration = .milliseconds(30),
      batchSize: Int = 100,
      maxAttempts: Int = 3,
      retryAfter: Duration = .seconds(600)
    ) {
      self.coalesceWindow = coalesceWindow
      self.batchSize = max(1, batchSize)
      self.maxAttempts = max(1, maxAttempts)
      self.retryAfter = retryAfter
    }
  }

  /// Fetches and saves `ids`. Throwing counts as a failed attempt for every ID in the batch.
  public typealias Fetch = @Sendable ([ID]) async throws -> ObjectFetchOutcome<ID>

  private struct Waiter {
    var remaining: Set<ID>
    var resolved: Set<ID> = []
    let continuation: CheckedContinuation<Set<ID>, Never>
  }

  private let policy: Policy
  private let fetch: Fetch
  private let now: @MainActor () -> ContinuousClock.Instant

  private var queued: [ID] = []
  private var inFlight: Set<ID> = []
  private var attempts: [ID: Int] = [:]
  private var quietUntil: [ID: ContinuousClock.Instant] = [:]
  private var waiters: [Waiter] = []
  private var drain: Task<Void, Never>?
  /// Bumped by `reset`; a fetch that finishes afterwards changes nothing.
  private var generation: UInt64 = 0

  public init(
    policy: Policy = Policy(),
    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
    fetch: @escaping Fetch
  ) {
    self.policy = policy
    self.now = now
    self.fetch = fetch
  }

  /// Fetches whichever of `ids` may be asked for now and waits for the outcome.
  /// Returns the IDs the remote resolved in this call; the rest were absent,
  /// failed, or are being left alone.
  @discardableResult
  public func ensure(_ ids: [ID]) async -> Set<ID> {
    let wanted = Set(ids).filter(mayAsk)
    guard !wanted.isEmpty else { return [] }
    for id in ids where wanted.contains(id) && !inFlight.contains(id) && !queued.contains(id) {
      queued.append(id)
    }
    return await withCheckedContinuation { continuation in
      waiters.append(Waiter(remaining: wanted, continuation: continuation))
      startDraining()
    }
  }

  /// Forgets attempt history and releases everyone waiting.
  public func reset() {
    generation &+= 1
    drain?.cancel()
    drain = nil
    queued.removeAll()
    inFlight.removeAll()
    attempts.removeAll()
    quietUntil.removeAll()
    let released = waiters
    waiters.removeAll()
    for waiter in released {
      waiter.continuation.resume(returning: waiter.resolved)
    }
  }

  private func mayAsk(_ id: ID) -> Bool {
    guard let until = quietUntil[id] else { return true }
    guard now() >= until else { return false }
    quietUntil[id] = nil
    attempts[id] = nil
    return true
  }

  private func startDraining() {
    guard drain == nil else { return }
    let startedIn = generation
    drain = Task { [weak self, policy] in
      try? await Task.sleep(for: policy.coalesceWindow)
      while let self, let batch = self.nextBatch(generation: startedIn) {
        let outcome = (try? await self.fetch(batch)) ?? ObjectFetchOutcome(failed: Set(batch))
        self.finish(batch, outcome, generation: startedIn)
      }
    }
  }

  private func nextBatch(generation startedIn: UInt64) -> [ID]? {
    guard startedIn == generation else { return nil }
    guard !queued.isEmpty else {
      drain = nil
      return nil
    }
    let batch = Array(queued.prefix(policy.batchSize))
    queued.removeFirst(batch.count)
    inFlight.formUnion(batch)
    return batch
  }

  private func finish(_ batch: [ID], _ outcome: ObjectFetchOutcome<ID>, generation startedIn: UInt64) {
    guard startedIn == generation else { return }
    inFlight.subtract(batch)
    let resolved = outcome.resolved
    for id in batch {
      attempts[id, default: 0] += 1
      let absent = !resolved.contains(id) && !outcome.failed.contains(id)
      if absent || attempts[id, default: 0] >= policy.maxAttempts {
        quietUntil[id] = now().advanced(by: policy.retryAfter)
      }
    }

    let settled = Set(batch)
    var stillWaiting: [Waiter] = []
    for var waiter in waiters {
      waiter.resolved.formUnion(waiter.remaining.intersection(resolved))
      waiter.remaining.subtract(settled)
      if waiter.remaining.isEmpty {
        waiter.continuation.resume(returning: waiter.resolved)
      } else {
        stillWaiting.append(waiter)
      }
    }
    waiters = stillWaiting
  }
}
