import InlineProtocol

public protocol RealtimeUpdatesProtocol: Sendable {
  @Sendable func applyBatch(updates: [InlineProtocol.Update]) async -> Void
}
