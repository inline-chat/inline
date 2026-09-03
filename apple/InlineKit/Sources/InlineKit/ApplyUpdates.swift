import Auth
import InlineProtocol
import RealtimeV2

struct InlineApplyUpdates: ApplyUpdates {
  private let engine: UpdatesEngine

  init(engine: UpdatesEngine = .shared) {
    self.engine = engine
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    await engine.applyBatch(updates: updates, source: source, sidecars: sidecars)
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?,
    mutationToken: AuthAccountMutationToken?
  ) async -> UpdateApplyResult {
    await engine.applyBatch(
      updates: updates,
      source: source,
      sidecars: sidecars,
      bucketCommit: bucketCommit,
      mutationToken: mutationToken
    )
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?
  ) async -> UpdateApplyResult {
    await engine.applyBatch(
      updates: updates,
      source: source,
      sidecars: sidecars,
      bucketCommit: bucketCommit
    )
  }

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> BucketState? {
    await engine.applyChatRepair(snapshot)
  }

  func repairSpace(_ snapshot: SpaceRepairSnapshot) async -> BucketState? {
    await engine.applySpaceRepair(snapshot)
  }

  func repairUser(_ snapshot: UserRepairSnapshot) async -> UserRepairOutcome? {
    await engine.applyUserRepair(snapshot)
  }

  func persistUserBootstrapProjection(
    _ snapshot: UserBootstrapProjectionSnapshot
  ) async -> UserBootstrapProjectionPersistence? {
    await engine.persistUserBootstrapProjection(snapshot)
  }

  func finalizeUserRepair(
    _ finalization: UserRepairFinalization,
    resolvedTargets: [BucketKey: UserRepairTargetResolution]
  ) async -> BucketState? {
    await engine.finalizeUserRepair(
      finalization,
      resolvedTargets: resolvedTargets
    )
  }
}
