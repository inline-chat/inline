/// Logical milliseconds. No clock is read by the engine.
public typealias Tick = Int64

/// Correlation survives reconnect; generation fences account replacement.
public struct OperationID: Hashable, Sendable {
  public let generation: UInt64
  public let serial: UInt64
}
public struct TransactionID: Hashable, Comparable, Sendable {
  public let rawValue: Int64
  public init(_ rawValue: Int64) { self.rawValue = rawValue }
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
public enum BucketKind: Int, Sendable { case user, space, chat }
public struct BucketID: Hashable, Comparable, Sendable {
  public let kind: BucketKind
  public let rawValue: Int64
  public init(_ rawValue: Int64, kind: BucketKind = .chat) {
    self.kind = kind
    self.rawValue = rawValue
  }
  public static let user = BucketID(0, kind: .user)
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.kind == rhs.kind ? lhs.rawValue < rhs.rawValue : lhs.kind.rawValue < rhs.kind.rawValue
  }
}
public enum ReplayPolicy: Equatable, Sendable { case neverReplay, replaySafe }

/// Payload is the application's existing immutable RPC/update value, not an async transaction object.
public struct Transaction<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let id: TransactionID
  public let payload: Payload
  public var replay: ReplayPolicy
  public var lane: String?
  public var requires: Set<TransactionID>
  public init(
    id: TransactionID, payload: Payload, replay: ReplayPolicy = .neverReplay,
    lane: String? = nil, requires: Set<TransactionID> = []
  ) {
    self.id = id
    self.payload = payload
    self.replay = replay
    self.lane = lane
    self.requires = requires
  }
}
public struct Update<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let sequence: Int64
  public let payload: Payload
  public var date: Int64
  public var hasSequence: Bool
  public var supported: Bool
  public init(
    sequence: Int64, payload: Payload, date: Int64 = 0, hasSequence: Bool = true,
    supported: Bool = true
  ) {
    self.sequence = sequence
    self.payload = payload
    self.date = date
    self.hasSequence = hasSequence
    self.supported = supported
  }
}
public struct Page<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let through: Int64
  public let date: Int64
  public let final: Bool
  public let kind: PageKind
  public let updates: [Update<Payload>]
  public let skipped: [SkippedSequence]
  public let sidecars: Payload?
  public init(
    through: Int64, date: Int64, final: Bool, kind: PageKind = .slice,
    updates: [Update<Payload>] = [], skipped: [SkippedSequence] = [], sidecars: Payload? = nil
  ) {
    self.through = through
    self.date = date
    self.final = final
    self.kind = kind
    self.updates = updates
    self.skipped = skipped
    self.sidecars = sidecars
  }
}
public enum DatabaseWork<Payload: Equatable & Sendable>: Equatable, Sendable {
  case importBootstrapProjection(BootstrapProjection, checkpoint: SyncPosition, Payload)
  case admitBootstrap(
    BucketID, before: SyncPosition, after: SyncPosition,
    projections: [BootstrapProjection: ProjectionReceipt<Payload>],
    children: [BucketID: SyncPosition])
  case storeBootstrapCheckpoint(Int64)
  case loadTransactions
  case optimistic(Transaction<Payload>)
  case store(Transaction<Payload>)
  case markDispatching(TransactionID)
  case applyTransaction(TransactionID, Payload)
  case settle(TransactionID, TransactionOutcome)
  case captureBucketAdmission(BucketID, expected: SyncPosition, network: Bool)
  case applyAdmittedPage(BucketID, BucketAdmission, Page<Payload>)
  case loadBucket(BucketID)
  case applyPage(BucketID, expected: SyncPosition, Page<Payload>)
  case importRepair(BucketID, expected: SyncPosition, RepairSnapshot<Payload>)
  case finalizeRepair(
    BucketID, expected: SyncPosition, RepairSnapshot<Payload>, children: [BucketID: SyncPosition])
  case storeCheckpoint(Int64)
}
public enum DatabaseResult<Payload: Equatable & Sendable>: Equatable, Sendable {
  case transactions(TransactionRestoration<Payload>)
  case projection(ProjectionReceipt<Payload>)
  case done
  case admission(BucketAdmission)
  case bucketState(SyncPosition)
  /// Transactional evidence, not a cursor-only read. For repair finalization,
  /// the writer must revalidate every child even if the parent is already newer.
  case committed(SyncPosition)
  case conflict
  case failed
}
public enum TransactionOutcome: Equatable, Sendable {
  case applied, executionUnknown, cancelled, failed, dependencyFailed
}
public enum Request<Payload: Equatable & Sendable>: Equatable, Sendable {
  case bootstrapCheckpoint
  case bootstrapProjection(BootstrapProjection, checkpoint: SyncPosition)
  case transaction(TransactionID, Payload)
  case fetch(BucketID, from: Int64, through: Int64)
  case captureLatest(BucketID)
  case repairSnapshot(BucketID, SyncPosition, RepairReason)
  case discover(after: Int64)
  case direct(Payload)
}
public enum Response<Payload: Equatable & Sendable>: Equatable, Sendable {
  case result(Payload)
  case page(Page<Payload>)
  case head(SyncPosition)
  case repairSnapshot(RepairSnapshot<Payload>)
  case discovery(checkpoint: Int64, targets: [BucketID: Int64])
  /// Authoritative proof that execution did not occur; eligible for later retry.
  case rejectedBeforeExecution
  case rejected
}
public enum SendFailure: Sendable { case knownUnsent, executionUnknown }
public enum Input<Payload: Equatable & Sendable>: Sendable {
  case start(generation: UInt64, transactions: TransactionStartup = .empty)
  case retryRestoration
  case retryBucket(BucketID, generation: UInt64)
  case bootstrap(user: BucketID)
  case connected(OperationID)
  case credentialsFinished(OperationID, CredentialResult)
  case authorizationRevoked(OperationID)
  case disconnected(OperationID)
  case submit(Transaction<Payload>)
  case request(Call<Payload>)
  case cancelCall(CallID)
  case call(Payload)
  case cancel(TransactionID)
  case catchUp(BucketID, through: Int64?)
  case live(BucketID, Update<Payload>, generation: UInt64)
  /// An external writer has already committed this evidence. This is not a write request.
  case snapshot(BucketID, SyncPosition, generation: UInt64)
  case discover(after: Int64)
  case databaseFinished(OperationID, DatabaseResult<Payload>)
  case response(OperationID, Response<Payload>)
  case sendFinished(OperationID)
  case sendFailed(OperationID, SendFailure)
  case timeout
  case stop
}
public enum ClientEvent<Payload: Equatable & Sendable>: Equatable, Sendable {
  case online
  case bootstrapFinished
  case restorationRejected
  case bootstrapBlocked(Set<BucketID>)
  case transactionsReady
  case authorizationRejected
  case transactionFinished(TransactionID, TransactionOutcome)
  case submissionRejected(TransactionID)
  case directFinished(OperationID, Payload?)
  case callFinished(CallID, CallOutcome<Payload>)
  case callRejected(CallID)
  case caughtUp(BucketID, through: Int64)
  case checkpointStored(Int64)
  case blocked(String)
  case drained
}
public enum Output<Payload: Equatable & Sendable>: Equatable, Sendable {
  case connect(OperationID)
  case credentials(OperationID, connection: OperationID, CredentialWork)
  case close(OperationID)
  case transmit(OperationID, connection: OperationID, Request<Payload>)
  case database(OperationID, DatabaseWork<Payload>)
  case cancel(OperationID)
  case event(ClientEvent<Payload>)
  case wait(until: Tick?)
}
public struct Configuration: Sendable {
  public let bucketAdmission: BucketAdmissionPolicy
  public let maxPendingSends: Int
  public let maxQueuedCalls: Int
  public let capacity: Int
  public let requestTimeout: Tick
  public let retryDelay: Tick
  public let maxBufferedUpdates: Int
  public init(
    capacity: Int = 4, requestTimeout: Tick = 100, retryDelay: Tick = 10,
    maxBufferedUpdates: Int = 64, maxQueuedCalls: Int = 256, maxPendingSends: Int = 256,
    bucketAdmission: BucketAdmissionPolicy = .cursorOnly
  ) {
    precondition(capacity > 0 && requestTimeout > 0 && retryDelay > 0 && maxBufferedUpdates > 0)
    precondition(maxQueuedCalls > 0 && maxPendingSends > 0)
    self.maxPendingSends = maxPendingSends
    self.bucketAdmission = bucketAdmission
    self.maxQueuedCalls = maxQueuedCalls
    self.capacity = capacity
    self.requestTimeout = requestTimeout
    self.retryDelay = retryDelay
    self.maxBufferedUpdates = maxBufferedUpdates
  }
}
