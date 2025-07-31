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

  /// When a message is received from the server
  // Probably need to add granularity here and abstract the protocol
  // case message(ServerProtocolMessage)
}
