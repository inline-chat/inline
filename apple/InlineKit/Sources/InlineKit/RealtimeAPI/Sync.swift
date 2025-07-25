import InlineProtocol

/// Manage update events lifecycle and call apply here
public actor Sync: Sendable {
  private var engine = UpdatesEngine.shared
  private weak var realtime: RealtimeAPI?

  init() {}

  public func configure(realtime: RealtimeAPI?) {
    self.realtime = realtime
  }

  public func handle(updates: UpdatesPayload) {
    // Handle the updates payload
  }
}

public protocol SyncDelegate: AnyObject {
  /// Called when the sync process starts to revoer
  func syncDidStart()

  /// Called when the sync process finishes and we're processing updates in realtime
  func syncDidFinish()
}
