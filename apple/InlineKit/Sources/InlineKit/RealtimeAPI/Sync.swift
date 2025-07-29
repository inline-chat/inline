import InlineProtocol

/// Manage update events lifecycle and call apply here
public actor Sync: Sendable {
  private var engine = UpdatesEngine.shared
  private weak var realtime: RealtimeAPI?

  init() {}

  public func configure(realtime: RealtimeAPI?) {
    self.realtime = realtime
  }

  public func handle(updates: [InlineProtocol.Update]) {
    // Handle the updates payload
    Task {
      await engine.applyBatch(updates: updates)
    }
  }
}
