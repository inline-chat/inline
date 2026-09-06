#if os(macOS)
import Foundation
import InlineKit
import Observation

/// Sheet-local acknowledgements prevent resending confirmed work after a partial failure.
@MainActor
@Observable
final class QuickForwardDelivery {
  private(set) var isSending = false
  private(set) var hasStarted = false
  private(set) var completedPeers: Set<Peer> = []
  private(set) var commentedPeers: Set<Peer> = []
  private(set) var errorMessage: String?

  func send(
    to peers: [Peer],
    comment: String,
    sendComment: (Peer, String) async throws -> Void,
    forward: (Peer) async throws -> Void
  ) async -> Bool {
    guard !isSending, !peers.isEmpty else { return false }
    isSending = true
    hasStarted = true
    errorMessage = nil
    defer { isSending = false }

    let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
    var failures: [String] = []
    for peer in peers where !completedPeers.contains(peer) {
      do {
        try Task.checkCancellation()
        if !comment.isEmpty, !commentedPeers.contains(peer) {
          try await sendComment(peer, comment)
          commentedPeers.insert(peer)
        }
        try Task.checkCancellation()
        try await forward(peer)
        completedPeers.insert(peer)
      } catch {
        if error is CancellationError || Task.isCancelled {
          errorMessage = "Forwarding stopped. Some messages may already have arrived. Check before retrying."
          return false
        }
        failures.append(error.localizedDescription)
      }
    }

    if let firstError = failures.first {
      errorMessage = "Could not confirm delivery to \(failures.count) chat(s). \(firstError) Some messages may already have arrived. Check before retrying."
      return false
    }
    return true
  }
}
#endif
