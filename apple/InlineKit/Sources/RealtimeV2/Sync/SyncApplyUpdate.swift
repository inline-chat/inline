import InlineProtocol

/// Protocol for applying updates within the Sync actor context
public protocol ApplyUpdates: Sendable {
  /// Apply a batch of updates to the database
  func apply(updates: [InlineProtocol.Update]) async
}
