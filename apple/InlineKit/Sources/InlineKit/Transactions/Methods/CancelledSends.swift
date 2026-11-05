import Foundation
import Synchronization

/// Sends the user cancelled after they may already have reached the server.
///
/// Once a send has been dispatched, the queue can only detach from it, so the server may still
/// create the message. Its message id update finds the send here: the message is then deleted on
/// the server, and its own new message update is kept out of the local store.
final class CancelledSends: Sendable {
  static let shared = CancelledSends()

  struct Target: Sendable {
    let chatId: Int64
    let peerId: Peer
  }

  private struct Landed: Hashable {
    let chatId: Int64
    let messageId: Int64
  }

  private struct State {
    var pending: [Int64: (target: Target, cancelledAt: Date)] = [:]
    var landed: Set<Landed> = []
  }

  /// A dispatched send lands well within this.
  private static let lifetime: TimeInterval = 10 * 60

  private let state = Mutex(State())

  func record(randomId: Int64, chatId: Int64, peerId: Peer) {
    let now = Date()
    state.withLock { state in
      state.pending = state.pending.filter { now.timeIntervalSince($0.value.cancelledAt) < Self.lifetime }
      state.pending[randomId] = (Target(chatId: chatId, peerId: peerId), now)
    }
  }

  /// The chat a cancelled send landed in, or nil when `randomId` wasn't cancelled.
  func land(randomId: Int64, messageId: Int64) -> Target? {
    state.withLock { state in
      guard let target = state.pending.removeValue(forKey: randomId)?.target else { return nil }
      state.landed.insert(Landed(chatId: target.chatId, messageId: messageId))
      return target
    }
  }

  func isLanded(chatId: Int64, messageId: Int64) -> Bool {
    state.withLock { $0.landed.contains(Landed(chatId: chatId, messageId: messageId)) }
  }
}
