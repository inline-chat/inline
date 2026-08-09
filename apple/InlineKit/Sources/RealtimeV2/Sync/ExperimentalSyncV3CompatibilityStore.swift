/// An intentionally unwired executable model of the Sync V3 atomic-commit contract.
///
/// This is not a second sync engine. It gives migration work a small oracle for the
/// invariants that the current split `ApplyUpdates` / `SyncStorage` boundary cannot prove.
actor ExperimentalSyncV3CompatibilityStore {
  enum Writer: Sendable, Equatable {
    case legacy
    case v3
  }

  struct Lease: Sendable, Equatable {
    let generation: UInt64
    let writer: Writer
  }

  enum FailurePoint: Sendable, CaseIterable {
    case afterSidecars
    case afterFirstEnvelope
    case beforeCursor
    case afterCursorBeforeCommit
  }

  enum CommitResult: Sendable, Equatable {
    case applied
    case replayed
  }

  enum CommitError: Error, Sendable, Equatable {
    case staleGeneration(expected: UInt64, actual: UInt64)
    case wrongWriter
    case wrongBucket
    case staleOrFutureStart(expected: Int64, actual: Int64)
    case invalidEnd(start: Int64, end: Int64)
    case nonContiguous(expectedPrevious: Int64, actualPrevious: Int64, sequence: Int64)
    case invalidSequence(expected: Int64, actual: Int64)
    case unaccountedSequence(expectedEnd: Int64, actualEnd: Int64)
    case unknownDurableKind(Int32)
    case missingDependency(Int64)
    case conflictingReplay
    case injectedFailure(FailurePoint)
  }

  struct Bucket: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
      case user
      case chat(Int64)
      case space(Int64)
    }

    let accountID: Int64
    let kind: Kind
  }

  enum Semantic: Sendable, Equatable {
    case model(id: Int64, dependsOn: Int64? = nil)
    case noEffect(receipt: String)
    case durableEffect(id: String)
    case unknown(kind: Int32)
  }

  struct Envelope: Sendable, Equatable {
    let bucket: Bucket
    let previousSequence: Int64
    let sequence: Int64
    let semantic: Semantic
  }

  struct Page: Sendable, Equatable {
    let id: String
    let bucket: Bucket
    let startSequence: Int64
    let endSequence: Int64
    let sidecarModelIDs: Set<Int64>
    let envelopes: [Envelope]
  }

  enum RepairMode: Sendable, Equatable {
    case merge
    case replace
  }

  struct Repair: Sendable, Equatable {
    let id: String
    let bucket: Bucket
    let throughSequence: Int64
    let modelIDs: Set<Int64>
    let coverageReceipt: String
    let mode: RepairMode
  }

  struct Snapshot: Sendable, Equatable {
    var sequence: Int64
    var modelIDs: Set<Int64>
    var noEffectReceipts: Set<String>
    var pendingEffectIDs: Set<String>
    var coverageReceipts: Set<String>
    var committedUnitIDs: [String: Int64]

    static let empty = Snapshot(
      sequence: 0,
      modelIDs: [],
      noEffectReceipts: [],
      pendingEffectIDs: [],
      coverageReceipts: [],
      committedUnitIDs: [:]
    )
  }

  private let bucket: Bucket
  private var generation: UInt64
  private var state: Snapshot

  init(bucket: Bucket, generation: UInt64 = 1, state: Snapshot = .empty) {
    self.bucket = bucket
    self.generation = generation
    self.state = state
  }

  func snapshot() -> Snapshot {
    state
  }

  func replaceGeneration(with generation: UInt64) {
    self.generation = generation
  }

  func commit(
    _ page: Page,
    lease: Lease,
    injecting failurePoint: FailurePoint? = nil
  ) throws -> CommitResult {
    try validate(lease: lease, unitBucket: page.bucket)

    if let committedEnd = state.committedUnitIDs[page.id] {
      guard committedEnd == page.endSequence, page.endSequence <= state.sequence else {
        throw CommitError.conflictingReplay
      }
      return .replayed
    }

    guard page.startSequence == state.sequence else {
      throw CommitError.staleOrFutureStart(expected: state.sequence, actual: page.startSequence)
    }
    guard page.endSequence >= page.startSequence else {
      throw CommitError.invalidEnd(start: page.startSequence, end: page.endSequence)
    }

    var staged = state
    staged.modelIDs.formUnion(page.sidecarModelIDs)
    try failIfRequested(.afterSidecars, requested: failurePoint)

    var expectedPrevious = page.startSequence
    for (index, envelope) in page.envelopes.enumerated() {
      guard envelope.bucket == bucket else { throw CommitError.wrongBucket }
      guard envelope.previousSequence == expectedPrevious else {
        throw CommitError.nonContiguous(
          expectedPrevious: expectedPrevious,
          actualPrevious: envelope.previousSequence,
          sequence: envelope.sequence
        )
      }
      guard envelope.sequence == expectedPrevious + 1 else {
        throw CommitError.invalidSequence(expected: expectedPrevious + 1, actual: envelope.sequence)
      }

      switch envelope.semantic {
      case let .model(id, dependency):
        if let dependency, !staged.modelIDs.contains(dependency) {
          throw CommitError.missingDependency(dependency)
        }
        staged.modelIDs.insert(id)
      case let .noEffect(receipt):
        staged.noEffectReceipts.insert(receipt)
      case let .durableEffect(id):
        staged.pendingEffectIDs.insert(id)
      case let .unknown(kind):
        throw CommitError.unknownDurableKind(kind)
      }

      expectedPrevious = envelope.sequence
      if index == 0 {
        try failIfRequested(.afterFirstEnvelope, requested: failurePoint)
      }
    }

    guard expectedPrevious == page.endSequence else {
      throw CommitError.unaccountedSequence(expectedEnd: page.endSequence, actualEnd: expectedPrevious)
    }
    try failIfRequested(.beforeCursor, requested: failurePoint)
    staged.sequence = page.endSequence
    staged.committedUnitIDs[page.id] = page.endSequence
    try failIfRequested(.afterCursorBeforeCommit, requested: failurePoint)

    state = staged
    return .applied
  }

  func commitRepair(
    _ repair: Repair,
    lease: Lease,
    injecting failurePoint: FailurePoint? = nil
  ) throws -> CommitResult {
    try validate(lease: lease, unitBucket: repair.bucket)

    if let committedEnd = state.committedUnitIDs[repair.id] {
      guard committedEnd == repair.throughSequence, repair.throughSequence <= state.sequence else {
        throw CommitError.conflictingReplay
      }
      return .replayed
    }

    guard repair.throughSequence > state.sequence else {
      throw CommitError.staleOrFutureStart(expected: state.sequence + 1, actual: repair.throughSequence)
    }

    var staged = state
    if repair.mode == .replace {
      staged.modelIDs = repair.modelIDs
    } else {
      staged.modelIDs.formUnion(repair.modelIDs)
    }
    try failIfRequested(.afterSidecars, requested: failurePoint)
    staged.coverageReceipts.insert(repair.coverageReceipt)
    try failIfRequested(.beforeCursor, requested: failurePoint)
    staged.sequence = repair.throughSequence
    staged.committedUnitIDs[repair.id] = repair.throughSequence
    try failIfRequested(.afterCursorBeforeCommit, requested: failurePoint)

    state = staged
    return .applied
  }

  private func validate(lease: Lease, unitBucket: Bucket) throws {
    guard lease.generation == generation else {
      throw CommitError.staleGeneration(expected: generation, actual: lease.generation)
    }
    guard lease.writer == .v3 else { throw CommitError.wrongWriter }
    guard unitBucket == bucket else { throw CommitError.wrongBucket }
  }

  private func failIfRequested(_ point: FailurePoint, requested: FailurePoint?) throws {
    if requested == point {
      throw CommitError.injectedFailure(point)
    }
  }
}
