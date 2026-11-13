import Foundation

/// Keeps outgoing messages in admission order per chat while their uploads run
/// in parallel. A send registers when it is admitted, uploads freely, and waits
/// for every earlier send in the same chat to settle (sent, failed, or cancelled)
/// before it calls `sendMessage`. Without this, a small second photo finishes
/// first and the server orders it before the captioned first one.
final class OutgoingSendOrder: @unchecked Sendable {
  static let shared = OutgoingSendOrder()

  private let lock = NSLock()
  /// Admission-ordered transaction ids per chat key.
  private var lanes: [String: [String]] = [:]
  private var laneByTransaction: [String: String] = [:]
  private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

  static func laneKey(chatId: Int64, peerId: Peer) -> String {
    chatId != 0 ? "chat:\(chatId)" : "peer:\(peerId)"
  }

  /// Registers a send at admission. Re-registering an id is a no-op.
  func register(transactionId: String, lane: String) {
    lock.withLock {
      guard laneByTransaction[transactionId] == nil else { return }
      laneByTransaction[transactionId] = lane
      lanes[lane, default: []].append(transactionId)
    }
  }

  /// Settles a send. Idempotent; unknown ids are ignored.
  func finish(transactionId: String) {
    let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
      guard let lane = laneByTransaction.removeValue(forKey: transactionId) else { return [] }
      lanes[lane]?.removeAll { $0 == transactionId }
      if lanes[lane]?.isEmpty == true { lanes[lane] = nil }
      guard let head = lanes[lane]?.first, let waiter = waiters.removeValue(forKey: head) else { return [] }
      return [waiter]
    }
    resumed.forEach { $0.resume() }
  }

  /// Returns once every earlier send in the lane has settled, or on cancellation.
  /// Unregistered ids return immediately so callers outside the queue never block.
  func waitForTurn(transactionId: String) async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready: Bool = lock.withLock {
          guard !Task.isCancelled,
                let lane = laneByTransaction[transactionId],
                lanes[lane]?.first != transactionId
          else { return true }
          waiters[transactionId] = continuation
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      let waiter = lock.withLock { waiters.removeValue(forKey: transactionId) }
      waiter?.resume()
    }
  }

  func isRegistered(transactionId: String) -> Bool {
    lock.withLock { laneByTransaction[transactionId] != nil }
  }
}
