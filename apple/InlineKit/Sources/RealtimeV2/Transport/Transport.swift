import Foundation
import InlineProtocol

public enum TransportEvent: Sendable {
  /// The transport is attempting to establish a connection.
  case connecting

  /// The transport is fully connected and ready to send/receive messages.
  case connected

  /// A message was received from the server.
  case message(ServerProtocolMessage)
}

public enum TransportError: Error {
  case notConnected
}

public protocol Transport: Sendable {
  /// Unified stream of life-cycle events and inbound server messages.
  var events: AsyncStream<TransportEvent> { get }

  /// Connect (or reconnect) to the remote endpoint.  Idempotent.
  func start() async

  /// Disconnect the underlying transport (e.g. on user logout).  Implementations
  /// *must not* finish the `events` stream so that existing listeners stay
  /// attached and can observe subsequent `start()`/reconnect cycles.
  func stop() async

  /// Send an encoded `ClientMessage` to the server.  Throws if the transport
  /// is not currently in the `.connected` state.
  func send(_ message: ClientMessage) async throws
}
