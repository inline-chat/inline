import Auth
import InlineProtocol
import RealtimeV2

struct InlineApplyUpdates: ApplyUpdates {
  init() {}

  func apply(updates: [InlineProtocol.Update]) async {
    await UpdatesEngine.shared.applyBatch(updates: updates)
  }
}
