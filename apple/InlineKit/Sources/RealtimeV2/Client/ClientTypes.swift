import InlineProtocol

public enum ClientState: Sendable {
  case connecting
  case open
}

/// Events emitted by the client
public enum ClientEvent: Sendable {
  /// When transport is connecting
  case connecting

  /// When transport is connected and authentication is successful
  case open

  /// When an ACK is received for a message
  case ack(msgId: UInt64)

  /// When a RPC result is received for a message
  case rpcResult(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?)

  /// When a RPC error is received for a message
  case rpcError(msgId: UInt64, rpcError: InlineProtocol.RpcError)

  /// When a batch of updates is received from the server
  case updates(updates: InlineProtocol.UpdatesPayload)

  /// When a message is received from the server
  // Probably need to add granularity here and abstract the protocol
  // case message(ServerProtocolMessage)
}
