import AsyncAlgorithms
import Foundation
import InlineProtocol

public enum TransportEvent: Sendable {
  /// The transport is attempting to establish a connection.
  case connecting

  /// The transport is fully connected and ready to send/receive messages.
  case connected

  /// The transport disconnected (error description is optional).
  case disconnected(errorDescription: String?)

  /// A message was received from the server.
  case message(ServerProtocolMessage)

  /// The authenticated carrier returned an MTProto service-level deadline result
  /// for this request. The connection remains usable; only this request is uncertain.
  case rpcCommitOutcomeUnknown(msgId: UInt64)

  /// The authenticated carrier proved this request did not enter application execution.
  /// Redelivery may use a fresh carrier message ID without application ambiguity.
  case rpcRejectedBeforeExecution(msgId: UInt64)
}

public enum TransportError: Error {
  case notConnected
  /// The transport rejected admission before accepting request bytes.
  case capacityExceeded
}

public protocol Transport: Sendable {
  /// Unified stream of life-cycle events and inbound server messages.
  var events: AsyncChannel<TransportEvent> { get }

  /// Connect (or reconnect) to the remote endpoint.  Idempotent.
  func start() async

  /// Disconnect the underlying transport (e.g. on user logout).  Implementations
  /// *must not* finish the `events` stream so that existing listeners stay
  /// attached and can observe subsequent `start()`/reconnect cycles.
  func stop() async

  /// Send an encoded `ClientMessage` to the server.  Throws if the transport
  /// is not currently in the `.connected` state.
  func send(_ message: ClientMessage) async throws

  /// Whether `.connected` already represents an application-authenticated session.
  /// Legacy V2 still performs `connectionInit`; V3 verifies its authorization key before
  /// publishing `.connected` and must not synthesize a second asynchronous open handshake.
  func isApplicationAuthenticatedOnConnect() async -> Bool
}

public extension Transport {
  func isApplicationAuthenticatedOnConnect() async -> Bool { false }
}
