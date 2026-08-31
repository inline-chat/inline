import Auth
import InlineProtocol
import RealtimeV2

struct InlineApplyUpdates: ApplyUpdates {
  init() {}

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?
  ) async -> UpdateApplyResult {
    await UpdatesEngine.shared.applyBatch(updates: updates, source: source, sidecars: sidecars)
  }

  func apply(
    updates: [InlineProtocol.Update],
    source: UpdateApplySource,
    sidecars: InlineProtocol.UpdateSidecars?,
    bucketCommit: UpdateBucketCommit?,
    mutationToken: AuthAccountMutationToken?
  ) async -> UpdateApplyResult {
    await UpdatesEngine.shared.applyBatch(
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
    await UpdatesEngine.shared.applyBatch(
      updates: updates,
      source: source,
      sidecars: sidecars,
      bucketCommit: bucketCommit
    )
  }

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> BucketState? {
    await UpdatesEngine.shared.applyChatRepair(snapshot)
  }

  func repairSpace(_ snapshot: SpaceRepairSnapshot) async -> BucketState? {
    await UpdatesEngine.shared.applySpaceRepair(snapshot)
  }

  func repairUser(_ snapshot: UserRepairSnapshot) async -> UserRepairOutcome? {
    await UpdatesEngine.shared.applyUserRepair(snapshot)
  }

  func finalizeUserRepair(
    _ finalization: UserRepairFinalization,
    resolvedTargets: [BucketKey: UserRepairTargetResolution]
  ) async -> BucketState? {
    await UpdatesEngine.shared.finalizeUserRepair(
      finalization,
      resolvedTargets: resolvedTargets
    )
  }
}
