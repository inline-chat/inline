import Combine

/// In-memory records with bounded freshness tracking.
///
/// Three ways in, all taking `[ID]`:
/// - `get` answers now, reading unloaded IDs synchronously. For first-frame UI.
/// - `load` reads unloaded and stale IDs without blocking. For everything else.
/// - `warm` starts a `load` and returns; a later `cached` or `get` then hits memory.
///
/// The host calls `noteWrite` when a kind's backing data changed. The most
/// recently used `limits.tracked(kind)` records of that kind are then re-read in
/// one batch and stay fresh; the rest are marked stale and revalidate when next requested.
@MainActor
public final class ObjectStore<Source: ObjectSource> {
  public typealias ID = Source.ID
  public typealias Record = Source.Record
  public typealias Snapshot = ObjectStoreSnapshot<ID, Record>

  /// IDs whose value changed, was first loaded, or was reset.
  public let changes = PassthroughSubject<Set<ID>, Never>()

  private struct Entry {
    /// nil when the source has no such record.
    var record: Record?
    var isFresh: Bool
    /// Start order of the read that produced `record`; an older read never replaces a newer one.
    var readSequence: UInt64
    var lastUsed: UInt64
  }

  private struct ReadToken {
    let sequence: UInt64
    let generation: UInt64
    let writeEpochs: [Source.Kind: UInt64]
    let unseenWritesEpoch: UInt64
  }

  private let source: Source
  private let limits: ObjectStoreLimits<Source.Kind>
  private let onError: @MainActor (any Error) -> Void

  private var entries: [ID: Entry] = [:]
  private var useClock: UInt64 = 0
  private var readSequence: UInt64 = 0
  /// Bumped by `reset`; reads started earlier are discarded.
  private var generation: UInt64 = 0
  /// Bumped on every noted write; a read that straddles one is stored stale.
  private var writeEpochs: [Source.Kind: UInt64] = [:]
  /// Bumped by `noteUnseenWrites`; covers kinds that have no record in memory yet.
  private var unseenWritesEpoch: UInt64 = 0

  private var kindsToRevalidate: Set<Source.Kind> = []
  private var idsToRevalidate: Set<ID> = []
  private var revalidation: Task<Void, Never>?

  public init(
    source: Source,
    limits: ObjectStoreLimits<Source.Kind>,
    onError: @escaping @MainActor (any Error) -> Void = { _ in }
  ) {
    self.source = source
    self.limits = limits
    self.onError = onError
  }

  /// Number of records in memory, including known-missing ones.
  public var count: Int {
    entries.count
  }

  // MARK: - Requests

  /// What is in memory right now. Never reads synchronously; stale values are
  /// returned as they are and revalidated in the background.
  public func cached(_ ids: [ID]) -> Snapshot {
    revalidate(ids.filter { entries[$0]?.isFresh == false })
    return snapshot(ids)
  }

  /// Answers now. Unloaded IDs are read synchronously in one batch; stale values
  /// are returned as they are and revalidated in the background.
  public func get(_ ids: [ID]) -> Snapshot {
    let unloaded = ids.filter { entries[$0] == nil }
    if !unloaded.isEmpty {
      let token = beginRead()
      do {
        try finishRead(token, ids: unloaded, records: source.readNow(unloaded))
      } catch {
        onError(error)
      }
    }
    return cached(ids)
  }

  /// Reads unloaded and stale IDs without blocking, then answers.
  @discardableResult
  public func load(_ ids: [ID]) async -> Snapshot {
    let needed = ids.filter { entries[$0]?.isFresh != true }
    if !needed.isEmpty {
      await read(needed)
    }
    return snapshot(ids)
  }

  /// Starts loading without waiting, so a later `cached` or `get` hits memory.
  public func warm(_ ids: [ID]) {
    guard ids.contains(where: { entries[$0]?.isFresh != true }) else { return }
    Task { await load(ids) }
  }

  /// The record in memory, without counting as a use or scheduling any work.
  public func peek(_ id: ID) -> Record? {
    entries[id]?.record
  }

  // MARK: - Host notifications

  /// The backing data of `kind` changed.
  public func noteWrite(_ kind: Source.Kind) {
    writeEpochs[kind, default: 0] &+= 1
    for (id, entry) in entries where entry.isFresh && source.kind(of: id) == kind {
      entries[id]?.isFresh = false
    }
    kindsToRevalidate.insert(kind)
    startRevalidation()
  }

  /// Writes may have gone unseen (for example before the host began watching).
  /// Every record in memory is checked once, tracked or not.
  public func noteUnseenWrites() {
    unseenWritesEpoch &+= 1
    for id in entries.keys {
      entries[id]?.isFresh = false
    }
    revalidate(Array(entries.keys))
  }

  /// Forgets everything and discards reads in flight.
  public func reset() {
    generation &+= 1
    revalidation?.cancel()
    revalidation = nil
    kindsToRevalidate.removeAll()
    idsToRevalidate.removeAll()
    let cleared = Set(entries.keys)
    entries.removeAll()
    if !cleared.isEmpty {
      changes.send(cleared)
    }
  }

  // MARK: - Reads

  private func beginRead() -> ReadToken {
    readSequence &+= 1
    return ReadToken(
      sequence: readSequence, generation: generation, writeEpochs: writeEpochs,
      unseenWritesEpoch: unseenWritesEpoch
    )
  }

  private func read(_ ids: [ID]) async {
    let token = beginRead()
    do {
      let records = try await source.read(ids)
      finishRead(token, ids: ids, records: records)
    } catch {
      guard token.generation == generation else { return }
      onError(error)
    }
  }

  private func finishRead(_ token: ReadToken, ids: [ID], records: [ID: Record]) {
    guard token.generation == generation else { return }
    var changed: Set<ID> = []
    var straddledWrite: [ID] = []
    for id in ids {
      let existing = entries[id]
      if let existing, existing.readSequence > token.sequence { continue }
      let record = records[id]
      let kind = source.kind(of: id)
      let isFresh = token.writeEpochs[kind] == writeEpochs[kind]
        && token.unseenWritesEpoch == unseenWritesEpoch
      if existing == nil || existing?.record != record {
        changed.insert(id)
      }
      entries[id] = Entry(
        record: record, isFresh: isFresh, readSequence: token.sequence,
        lastUsed: existing?.lastUsed ?? nextUse()
      )
      if !isFresh {
        straddledWrite.append(id)
      }
    }
    trimToMemoryLimit()
    revalidate(straddledWrite)
    if !changed.isEmpty {
      changes.send(changed)
    }
  }

  private func snapshot(_ ids: [ID]) -> Snapshot {
    var snapshot = Snapshot()
    for id in ids {
      guard var entry = entries[id] else { continue }
      entry.lastUsed = nextUse()
      entries[id] = entry
      if let record = entry.record {
        snapshot.records[id] = record
        snapshot.states[id] = entry.isFresh ? .fresh : .stale
      } else {
        snapshot.states[id] = entry.isFresh ? .missing : .stale
      }
    }
    return snapshot
  }

  private func nextUse() -> UInt64 {
    useClock &+= 1
    return useClock
  }

  private func trimToMemoryLimit() {
    guard entries.count > limits.memory else { return }
    let excess = entries.count - Int(Double(limits.memory) * limits.evictionKeepRatio)
    for (id, _) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }).prefix(excess) {
      entries.removeValue(forKey: id)
    }
  }

  // MARK: - Revalidation

  private func revalidate(_ ids: [ID]) {
    guard !ids.isEmpty else { return }
    idsToRevalidate.formUnion(ids)
    startRevalidation()
  }

  private func startRevalidation() {
    guard revalidation == nil else { return }
    let startedIn = generation
    revalidation = Task { [weak self] in
      // Writes that land during a read are picked up by the next pass, so a
      // burst of writes costs one extra read rather than one read per write.
      while let self, let ids = self.nextRevalidationBatch(generation: startedIn) {
        await self.read(ids)
      }
    }
  }

  private func nextRevalidationBatch(generation startedIn: UInt64) -> [ID]? {
    guard startedIn == generation, !Task.isCancelled else { return nil }
    var ids = idsToRevalidate
    idsToRevalidate.removeAll()
    for kind in kindsToRevalidate {
      let tracked = entries
        .filter { source.kind(of: $0.key) == kind }
        .sorted { $0.value.lastUsed > $1.value.lastUsed }
        .prefix(limits.tracked(kind))
      ids.formUnion(tracked.map(\.key))
    }
    kindsToRevalidate.removeAll()
    ids = ids.filter { entries[$0]?.isFresh == false }
    guard !ids.isEmpty else {
      revalidation = nil
      return nil
    }
    return Array(ids)
  }
}
