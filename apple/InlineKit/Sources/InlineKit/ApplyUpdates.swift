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

  func repairChat(_ snapshot: ChatRepairSnapshot) async -> Bool {
    await UpdatesEngine.shared.applyChatRepair(snapshot)
  }
}
