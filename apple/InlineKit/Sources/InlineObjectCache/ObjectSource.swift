/// Where an `ObjectStore` gets its records. The store knows nothing about
/// databases or networks; a host adapts its storage to this.
public protocol ObjectSource<ID, Record>: Sendable {
  associatedtype ID: Hashable & Sendable
  /// Groups IDs whose records change together, such as "all users". Freshness is tracked per kind.
  associatedtype Kind: Hashable & Sendable
  associatedtype Record: Equatable & Sendable

  func kind(of id: ID) -> Kind

  /// Reads on the calling thread. An ID absent from the result does not exist.
  func readNow(_ ids: [ID]) throws -> [ID: Record]

  /// Reads without blocking the caller's thread. An ID absent from the result does not exist.
  func read(_ ids: [ID]) async throws -> [ID: Record]
}

/// Bounds for one `ObjectStore`.
public struct ObjectStoreLimits<Kind: Hashable & Sendable>: Sendable {
  /// Records of a kind that are re-read after every write to that kind, most
  /// recently used first. Records past this are marked stale and re-read when next requested.
  public var tracked: @Sendable (Kind) -> Int

  /// Records of all kinds kept in memory. Past this, the least recently used
  /// are dropped until `memory * evictionKeepRatio` remain.
  public var memory: Int

  /// Share of `memory` kept by one eviction pass. Lower evicts less often but in bigger steps.
  public var evictionKeepRatio: Double

  public init(tracked: @escaping @Sendable (Kind) -> Int, memory: Int, evictionKeepRatio: Double = 0.75) {
    self.tracked = tracked
    self.memory = memory
    self.evictionKeepRatio = evictionKeepRatio
  }
}
