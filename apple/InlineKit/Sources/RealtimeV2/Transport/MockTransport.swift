import AsyncAlgorithms
import Foundation
import InlineProtocol

/// Pure in-memory implementation that lets unit tests feed pre-canned events
/// and observe outbound messages without touching the network stack.
actor MockTransport: Transport {
  // MARK: Public -----------------------------------------------------------------

  nonisolated var events: AsyncChannel<TransportEvent> { channel }

  func start() async {
    guard !started else { return }
    started = true
    await channel.send(.connecting)
    await channel.send(.connected)
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
  func emit(_ event: TransportEvent) async {
    await channel.send(event)
  }

  /// All messages that have been sent by the system under test.
  private(set) var sentMessages: [ClientMessage] = []

  // MARK: Private ----------------------------------------------------------------

  private var started = false

  private let channel: AsyncChannel<TransportEvent>

  init() {
    channel = AsyncChannel<TransportEvent>()
  }
}
