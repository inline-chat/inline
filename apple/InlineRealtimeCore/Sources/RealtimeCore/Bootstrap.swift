/// Independent current-state projections; their payloads and durable evidence stay
/// opaque to orchestration. Real import/revalidation remains the writer's job.
public enum BootstrapProjection: Int, CaseIterable, Hashable, Sendable { case chats, me, settings }
public struct ProjectionReceipt<Payload: Equatable & Sendable>: Equatable, Sendable {
  public let evidence: Payload
  public let seeds: [BucketID: SyncPosition]
  public let targets: [BucketID: Int64]
  public init(
    evidence: Payload, seeds: [BucketID: SyncPosition] = [:], targets: [BucketID: Int64] = [:]
  ) {
    self.evidence = evidence
    self.seeds = seeds
    self.targets = targets
  }
}
enum BootstrapRequest: Equatable, Sendable {
  case before
  case projection(BootstrapProjection)
  case after
}
struct Bootstrap<Payload: Equatable & Sendable>: Sendable {
  enum Phase: Sendable {
    case before, projections, after, children, admitting, replaying, checkpoint
  }
  let user: BucketID
  var phase: Phase = .before
  var before: SyncPosition?
  var after: SyncPosition?
  var pending: [BootstrapRequest: OperationID] = [:]
  var retryAt: [BootstrapRequest: Tick] = [:]
  var receipts: [BootstrapProjection: ProjectionReceipt<Payload>] = [:]
  var children: [BucketID: Int64] = [:]
  var latest: [BucketID: UInt64] = [:]
  var reportedBlocked: Set<BucketID> = []
  var discoverAfter = false
  var needsAudit = false
  var blocksUser: Bool {
    switch phase {
    case .replaying, .checkpoint: false
    default: true
    }
  }
}
extension BootstrapRequest: Hashable {}

extension RealtimeCore {
  var bootstrapReady: Bool {
    guard let state = bootstrap else { return false }
    return bootstrapRequests(state).contains {
      state.pending[$0] == nil && (state.retryAt[$0] ?? 0) <= now
    }
  }
  func bootstrapRequests(_ state: Bootstrap<Payload>) -> [BootstrapRequest] {
    switch state.phase {
    case .before: [.before]
    case .projections:
      BootstrapProjection.allCases.filter { state.receipts[$0] == nil }.map { .projection($0) }
    case .after: [.after]
    default: []
    }
  }
  mutating func pumpBootstrap() {
    guard let state = bootstrap else { return }
    if state.needsAudit {
      // Re-audit only after this workflow's admitted work has actually finished.
      // Operation IDs then fence duplicate receipts without overlapping audits.
      guard state.pending.isEmpty, state.phase != .admitting, state.phase != .checkpoint,
        buckets[state.user]?.pending == nil
      else { return }
      bootstrap = Bootstrap(user: state.user)
      bootstrap?.discoverAfter = state.discoverAfter
      bootstrap?.retryAt[.before] = now + configuration.retryDelay
      return
    }
    for (owner, deadline) in state.retryAt where deadline <= now {
      bootstrap?.retryAt.removeValue(forKey: owner)
    }
    for owner in bootstrapRequests(state) {
      guard bootstrap?.pending[owner] == nil, (bootstrap?.retryAt[owner] ?? 0) <= now,
        session.openConnection != nil, reservedRequests < configuration.capacity,
        nextAdmission == .sync
      else { continue }
      bootstrap?.retryAt.removeValue(forKey: owner)
      let request: Request<Payload>
      switch owner {
      case .before, .after: request = .bootstrapCheckpoint
      case .projection(let kind):
        guard let before = state.before else { continue }
        request = .bootstrapProjection(kind, checkpoint: before)
      }
      lastAdmission = .sync
      let operation = transmit(request, owner: .bootstrap(owner))
      bootstrap?.pending[owner] = operation
    }
    guard let current = bootstrap else { return }
    switch current.phase {
    case .children:
      let blocked = Set(
        current.children.compactMap { key, target -> BucketID? in
          guard let bucket = buckets[key], bucket.blocked else { return nil }
          if target > 0 && (bucket.cursor ?? -1) >= target { return nil }
          if target == 0, let latest = current.latest[key], bucket.completedLatest >= latest {
            return nil
          }
          return key
        })
      reportBootstrapBlocked(blocked)
      guard bootstrapChildrenReady(current), let before = current.before, let after = current.after
      else { return }
      let evidence = current.children.keys.reduce(into: [BucketID: SyncPosition]()) {
        $0[$1] = buckets[$1]?.position
      }
      bootstrap?.phase = .admitting
      _ = write(
        .admitBootstrap(
          current.user, before: before, after: after, projections: current.receipts,
          children: evidence))
    case .replaying:
      reportBootstrapBlocked(buckets[current.user]?.blocked == true ? [current.user] : [])
      guard let after = current.after, let before = current.before,
        (buckets[current.user]?.cursor ?? -1) >= after.sequence
      else { return }
      bootstrap?.phase = .checkpoint
      // P1 bounds User replay. It is not a global discovery checkpoint: unrelated
      // changes between P0 and P1 still need discovery from P0's date.
      _ = write(.storeBootstrapCheckpoint(before.date))
    default: break
    }
  }
  mutating func reportBootstrapBlocked(_ blocked: Set<BucketID>) {
    guard bootstrap?.reportedBlocked != blocked else { return }
    bootstrap?.reportedBlocked = blocked
    if !blocked.isEmpty { output.append(.event(.bootstrapBlocked(blocked))) }
  }
  func bootstrapChildrenReady(_ state: Bootstrap<Payload>) -> Bool {
    state.children.allSatisfy { key, target in
      guard let bucket = buckets[key], bucket.position != nil else { return false }
      if target > 0 { return bucket.cursor! >= target }
      guard let required = state.latest[key] else { return false }
      return bucket.completedLatest >= required
    }
  }
  mutating func bootstrapResponse(_ owner: BootstrapRequest, _ response: Response<Payload>) {
    guard let state = bootstrap else { return }
    bootstrap?.pending.removeValue(forKey: owner)
    switch (owner, response) {
    case (.before, .head(let position)) where position.sequence >= 0 && position.date > 0:
      bootstrap?.before = position
      bootstrap?.phase = .projections
    case (.after, .head(let position))
    where position.sequence >= (state.before?.sequence ?? 0)
      && position.date >= (state.before?.date ?? 1):
      bootstrap?.after = position
      bootstrap?.phase = .children
      for kind in BootstrapProjection.allCases {
        guard let receipt = state.receipts[kind] else { continue }
        for key in receipt.seeds.keys.sorted() {
          let seed = receipt.seeds[key]!
          ensureBucket(key)
          if seed.sequence >= (buckets[key]?.cursor ?? 0) {
            buckets[key]?.cursor = seed.sequence
            let date = max(buckets[key]?.date ?? 0, seed.date)
            buckets[key]?.date = date
          }
        }
        for (key, target) in receipt.targets {
          let existing = bootstrap?.children[key]
          bootstrap?.children[key] = existing == 0 || target == 0 ? 0 : max(existing ?? 0, target)
        }
      }
      if repairCycle(parent: state.user, children: Set(bootstrap?.children.keys.map { $0 } ?? [])) {
        bootstrap = Bootstrap(user: state.user)
        bootstrap?.discoverAfter = state.discoverAfter
        bootstrap?.retryAt[.before] = now + configuration.retryDelay
        output.append(.event(.blocked("bootstrap repair dependency cycle; new audit required")))
        return
      }
      for key in bootstrap?.children.keys.sorted() ?? [] {
        let target = bootstrap!.children[key]!
        demand(key, through: target > 0 ? target : nil)
        if target == 0 { bootstrap?.latest[key] = buckets[key]?.latest }
      }
    case (.projection(let kind), .result(let payload)):
      guard let before = state.before else { return }
      let operation = write(.importBootstrapProjection(kind, checkpoint: before, payload))
      bootstrap?.pending[owner] = operation
    default:
      bootstrap?.retryAt[owner] = now + configuration.retryDelay
      output.append(.event(.blocked("invalid bootstrap response; retry retained")))
    }
  }
}

// Durable receipts advance this workflow only after its own contract accepts them.
extension RealtimeCore {
  mutating func completeBootstrapWrite(
    _ work: DatabaseWork<Payload>, _ result: DatabaseResult<Payload>
  ) -> Bool {
    switch (work, result) {
    case (.admitBootstrap, .failed) where bootstrap?.needsAudit == true:
      bootstrap?.phase = .children
    case (.importBootstrapProjection(let kind, _, _), .projection(let receipt))
    where receipt.seeds.allSatisfy({
      $0.key != bootstrap?.user && $0.value.sequence >= 0 && $0.value.date >= 0
    })
      && receipt.targets.allSatisfy({ $0.key != bootstrap?.user && $0.value >= 0 }):
      bootstrap?.pending.removeValue(forKey: .projection(kind))
      bootstrap?.receipts[kind] = receipt
      if bootstrap?.receipts.count == BootstrapProjection.allCases.count {
        bootstrap?.phase = .after
      }
    case (.admitBootstrap(let user, let before, let after, _, _), .committed(let position))
    where position.sequence >= before.sequence && position.date >= before.date:
      ensureBucket(user)
      if position.sequence >= (buckets[user]?.cursor ?? 0) {
        buckets[user]?.cursor = position.sequence
        let date = max(buckets[user]?.date ?? 0, position.date)
        buckets[user]?.date = date
      }
      bootstrap?.phase = .replaying
      demand(user, through: after.sequence)
    case (.admitBootstrap, .conflict):
      // Projections may remain durable, but their admission evidence is obsolete.
      // Start a new P0/projection audit without inventing a baseline or checkpoint.
      if let previous = bootstrap {
        bootstrap = Bootstrap(user: previous.user)
        bootstrap?.discoverAfter = previous.discoverAfter
        bootstrap?.retryAt[.before] = now + configuration.retryDelay
      }
    case (.storeBootstrapCheckpoint(let checkpoint), .done):
      if bootstrap?.needsAudit == true {
        bootstrap?.phase = .children
        output.append(.event(.checkpointStored(checkpoint)))
        return true
      }
      let discoverAfter = bootstrap?.discoverAfter == true
      bootstrap = nil
      output.append(.event(.checkpointStored(checkpoint)))
      output.append(.event(.bootstrapFinished))
      if discoverAfter { discovery = Discovery(after: checkpoint) }
    default: return false
    }
    return true
  }
}
