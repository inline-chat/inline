import Foundation
import InlineProtocol

/// Pure in-memory implementation that lets unit tests feed pre-canned events
/// and observe outbound messages without touching the network stack.
actor MockTransport: Transport {
  // MARK: Public -----------------------------------------------------------------

  nonisolated var events: AsyncStream<TransportEvent> { stream }

  func start() async {
    guard !started else { return }
    started = true
    continuation.yield(.connecting)
    continuation.yield(.connected)
  }

  func stop() async {
    guard started else { return }
    started = false
  }

  func send(_ message: ClientMessage) async throws {
    sentMessages.append(message)
  }

  // MARK: Testing helpers --------------------------------------------------------

  /// Push an arbitrary event into the stream (used by unit tests).
  func emit(_ event: TransportEvent) {
    continuation.yield(event)
  }

  /// All messages that have been sent by the system under test.
  private(set) var sentMessages: [ClientMessage] = []

  // MARK: Private ----------------------------------------------------------------

  private var started = false

  private let stream: AsyncStream<TransportEvent>
  private let continuation: AsyncStream<TransportEvent>.Continuation

  init() {
    var cont: AsyncStream<TransportEvent>.Continuation!
    stream = AsyncStream<TransportEvent> { c in cont = c }
    continuation = cont
  }
}
