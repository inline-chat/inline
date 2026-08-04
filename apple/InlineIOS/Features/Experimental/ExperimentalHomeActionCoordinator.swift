import InlineKit
import Observation

@MainActor
@Observable
final class ExperimentalHomeActionCoordinator {
  @ObservationIgnored
  private var pendingPeers = Set<Peer>()
  @ObservationIgnored
  private var deferredPinUpdates: [Peer: Bool] = [:]

  func deferPinUpdate(peer: Peer, pinned: Bool) {
    deferredPinUpdates[peer] = pinned
  }

  func takeDeferredPinUpdate(peer: Peer) -> Bool? {
    deferredPinUpdates.removeValue(forKey: peer)
  }

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
