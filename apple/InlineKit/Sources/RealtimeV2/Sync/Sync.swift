import InlineProtocol
import Logger

actor Sync {
  private var log = Log.scoped("RealtimeV2.Sync")
  private var applyUpdates: ApplyUpdates

  init(applyUpdates: ApplyUpdates) {
    self.applyUpdates = applyUpdates
  }

  func process(updates: [InlineProtocol.Update]) async {
    log.debug("applying \(updates.count) updates")
    await applyUpdates.apply(updates: updates)
  }
}
