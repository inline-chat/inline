import InlineKit
import Observation

@MainActor
@Observable
final class ExperimentalHomeActionCoordinator {
  @ObservationIgnored
  private var pendingPeers = Set<Peer>()

  @discardableResult
  func perform(
    peer: Peer,
    operation: () async throws -> Void
  ) async throws -> Bool {
    guard pendingPeers.insert(peer).inserted else { return false }
    defer { pendingPeers.remove(peer) }

    try await operation()
    return true
  }
}
