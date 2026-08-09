import Foundation
import InlineKit

/// Stable identity for one translation result. The account is intentionally
/// owned by `TranslationJobRuntime`, so jobs cannot drift between sessions.
public struct TranslationJobIdentity: Hashable, Sendable {
  public let peer: Peer
  public let chatID: Int64
  public let messageID: Int64
  public let messageRevision: Int64
  public let language: String

  public init(
    peer: Peer,
    chatID: Int64,
    messageID: Int64,
    messageRevision: Int64,
    language: String
  ) {
    self.peer = peer
    self.chatID = chatID
    self.messageID = messageID
    self.messageRevision = messageRevision
    self.language = language
  }
}

public enum TranslationJobPriority: Int, Sendable, Comparable {
  case background
  case visiblePreview
  case openChat

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct TranslationJob: Hashable, Sendable {
  public let identity: TranslationJobIdentity
  public let priority: TranslationJobPriority

  public init(identity: TranslationJobIdentity, priority: TranslationJobPriority) {
    self.identity = identity
    self.priority = priority
  }
}

public actor TranslationJobRuntime {
  public struct Configuration: Sendable {
    public let batchLimit: Int
    public let maximumAttempts: Int
    public let persistenceTimeout: Duration
    public let baseRetryDelay: Duration
    public let maximumRetryDelay: Duration

    public init(
      batchLimit: Int = 24,
      maximumAttempts: Int = 3,
      persistenceTimeout: Duration = .seconds(2),
      baseRetryDelay: Duration = .seconds(2),
      maximumRetryDelay: Duration = .seconds(30)
    ) {
      self.batchLimit = max(1, batchLimit)
      self.maximumAttempts = max(1, maximumAttempts)
      self.persistenceTimeout = persistenceTimeout
      self.baseRetryDelay = baseRetryDelay
      self.maximumRetryDelay = maximumRetryDelay
    }
  }

  public struct Dependencies: Sendable {
    public let loadPersisted: @Sendable ([TranslationJobIdentity]) async throws -> Set<TranslationJobIdentity>
    public let dispatch: @Sendable ([TranslationJobIdentity]) async throws -> Void
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(
      loadPersisted: @escaping @Sendable ([TranslationJobIdentity]) async throws -> Set<TranslationJobIdentity>,
      dispatch: @escaping @Sendable ([TranslationJobIdentity]) async throws -> Void,
      sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
        try await Task.sleep(for: duration)
      }
    ) {
      self.loadPersisted = loadPersisted
      self.dispatch = dispatch
      self.sleep = sleep
    }
  }

  public struct Snapshot: Equatable, Sendable {
    public let accountID: Int64
    public let pending: Int
    public let dispatching: Int
    public let awaitingPersistence: Int
    public let retrying: Int
    public let exhausted: Int
    public let isShutdown: Bool
  }

  public enum RuntimeError: Error, Equatable {
    case shutdown
  }

  private enum Phase: Sendable {
    case pending
    case dispatching
    case awaitingPersistence(deadline: ContinuousClock.Instant)
    case retryAfter(deadline: ContinuousClock.Instant)
    case exhausted
  }

  private struct Record: Sendable {
    var priority: TranslationJobPriority
    var sequence: UInt64
    var attempt: Int
    var phase: Phase
  }

  private let accountID: Int64
  private let configuration: Configuration
  private let dependencies: Dependencies
  private let clock = ContinuousClock()
  private var records: [TranslationJobIdentity: Record] = [:]
  private var nextSequence: UInt64 = 0
  private var worker: Task<Void, Never>?
  private var workerGeneration: UInt64 = 0
  private var workerIsSleeping = false
  private var isShutdown = false

  public init(
    accountID: Int64,
    configuration: Configuration = Configuration(),
    dependencies: Dependencies
  ) {
    self.accountID = accountID
    self.configuration = configuration
    self.dependencies = dependencies
  }

  public func submit(_ jobs: [TranslationJob]) throws {
    guard !isShutdown else { throw RuntimeError.shutdown }

    var insertedPendingWork = false
    for job in jobs {
      if var existing = records[job.identity] {
        existing.priority = max(existing.priority, job.priority)
        records[job.identity] = existing
      } else {
        nextSequence &+= 1
        records[job.identity] = Record(
          priority: job.priority,
          sequence: nextSequence,
          attempt: 0,
          phase: .pending
        )
        insertedPendingWork = true
      }
    }

    if worker == nil {
      startWorker()
    } else if insertedPendingWork, workerIsSleeping {
      restartSleepingWorker()
    }
  }

  /// Database-derived acknowledgement is the only success authority. A network
  /// response merely moves work into the bounded persistence-wait state.
  public func acknowledgePersisted(_ identities: Set<TranslationJobIdentity>) {
    for identity in identities {
      records.removeValue(forKey: identity)
    }
    if records.isEmpty {
      stopSleepingWorker()
    }
  }

  public func snapshot() -> Snapshot {
    var pending = 0
    var dispatching = 0
    var awaitingPersistence = 0
    var retrying = 0
    var exhausted = 0

    for record in records.values {
      switch record.phase {
      case .pending:
        pending += 1
      case .dispatching:
        dispatching += 1
      case .awaitingPersistence:
        awaitingPersistence += 1
      case .retryAfter:
        retrying += 1
      case .exhausted:
        exhausted += 1
      }
    }

    return Snapshot(
      accountID: accountID,
      pending: pending,
      dispatching: dispatching,
      awaitingPersistence: awaitingPersistence,
      retrying: retrying,
      exhausted: exhausted,
      isShutdown: isShutdown
    )
  }

  /// Account replacement/logout cancels and joins the sole worker before the
  /// runtime reports completion. Callers then discard this runtime instance.
  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    records.removeAll()
    workerGeneration &+= 1
    let task = worker
    worker = nil
    workerIsSleeping = false
    task?.cancel()
    await task?.value
  }

  private func startWorker() {
    guard worker == nil, !isShutdown, hasRunnableWork else { return }
    workerGeneration &+= 1
    let generation = workerGeneration
    worker = Task { [weak self] in
      await self?.runWorker(generation: generation)
    }
  }

  private func restartSleepingWorker() {
    guard workerIsSleeping else { return }
    workerGeneration &+= 1
    worker?.cancel()
    worker = nil
    workerIsSleeping = false
    startWorker()
  }

  private func stopSleepingWorker() {
    guard workerIsSleeping else { return }
    workerGeneration &+= 1
    worker?.cancel()
    worker = nil
    workerIsSleeping = false
  }

  private var hasRunnableWork: Bool {
    records.values.contains { record in
      switch record.phase {
      case .pending, .awaitingPersistence, .retryAfter:
        true
      case .dispatching, .exhausted:
        false
      }
    }
  }

  private func runWorker(generation: UInt64) async {
    defer { workerFinished(generation: generation) }

    while !Task.isCancelled, !isShutdown {
      promoteDueWork()
      let batch = reserveBatch()
      if !batch.isEmpty {
        await execute(batch)
        continue
      }

      guard let delay = delayUntilNextWake() else { return }
      workerIsSleeping = true
      do {
        try await dependencies.sleep(delay)
      } catch {
        workerIsSleeping = false
        return
      }
      workerIsSleeping = false
    }
  }

  private func workerFinished(generation: UInt64) {
    guard workerGeneration == generation else { return }
    worker = nil
    workerIsSleeping = false
  }

  private func promoteDueWork() {
    let now = clock.now
    for (identity, var record) in records {
      let isDue: Bool
      switch record.phase {
      case let .awaitingPersistence(deadline), let .retryAfter(deadline):
        isDue = deadline <= now
      case .pending, .dispatching, .exhausted:
        isDue = false
      }
      guard isDue else { continue }

      if record.attempt >= configuration.maximumAttempts {
        record.phase = .exhausted
      } else {
        record.phase = .pending
      }
      records[identity] = record
    }
  }

  private func reserveBatch() -> [TranslationJobIdentity] {
    let candidates = records.compactMap { identity, record -> (TranslationJobIdentity, Record)? in
      guard case .pending = record.phase else { return nil }
      return (identity, record)
    }
    .sorted { lhs, rhs in
      if lhs.1.priority != rhs.1.priority {
        return lhs.1.priority > rhs.1.priority
      }
      return lhs.1.sequence < rhs.1.sequence
    }
    .prefix(configuration.batchLimit)

    let batch = candidates.map(\.0)
    for identity in batch {
      guard var record = records[identity] else { continue }
      record.attempt += 1
      record.phase = .dispatching
      records[identity] = record
    }
    return batch
  }

  private func execute(_ batch: [TranslationJobIdentity]) async {
    do {
      let alreadyPersisted = try await dependencies.loadPersisted(batch)
      acknowledgePersisted(alreadyPersisted)
      let remaining = batch.filter { records[$0] != nil }
      guard !remaining.isEmpty else { return }

      try Task.checkCancellation()
      try await dependencies.dispatch(remaining)
      let deadline = clock.now.advanced(by: configuration.persistenceTimeout)
      for identity in remaining {
        guard var record = records[identity], case .dispatching = record.phase else { continue }
        record.phase = .awaitingPersistence(deadline: deadline)
        records[identity] = record
      }
    } catch is CancellationError {
      return
    } catch {
      scheduleRetry(for: batch)
    }
  }

  private func scheduleRetry(for batch: [TranslationJobIdentity]) {
    let now = clock.now
    for identity in batch {
      guard var record = records[identity], case .dispatching = record.phase else { continue }
      if record.attempt >= configuration.maximumAttempts {
        record.phase = .exhausted
      } else {
        let exponent = max(0, record.attempt - 1)
        let multiplier = pow(2.0, Double(exponent))
        let baseSeconds = configuration.baseRetryDelay.timeInterval
        let maximumSeconds = configuration.maximumRetryDelay.timeInterval
        let delay = Duration.seconds(min(baseSeconds * multiplier, maximumSeconds))
        record.phase = .retryAfter(deadline: now.advanced(by: delay))
      }
      records[identity] = record
    }
  }

  private func delayUntilNextWake() -> Duration? {
    let now = clock.now
    return records.values.compactMap { record -> Duration? in
      switch record.phase {
      case let .awaitingPersistence(deadline), let .retryAfter(deadline):
        max(.zero, now.duration(to: deadline))
      case .pending:
        .zero
      case .dispatching, .exhausted:
        nil
      }
    }.min()
  }
}

private extension Duration {
  var timeInterval: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  }
}
