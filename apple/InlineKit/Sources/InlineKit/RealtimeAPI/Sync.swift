import InlineProtocol
import Logger

/// Manage update events lifecycle and call apply here
public actor Sync: Sendable {
  private var engine = UpdatesEngine.shared
  private weak var realtime: RealtimeAPI?

  init() {}

  public func configure(realtime: RealtimeAPI?) {
    self.realtime = realtime
  }

  public func handle(updates: [InlineProtocol.Update]) {
    Log.shared.warning("handle updates using realtime V1, this is deprecated and will be removed soon")
    // Handle the updates payload
    Task {
      await engine.applyBatch(updates: updates)
    }
  }
}
