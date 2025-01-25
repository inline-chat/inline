// MARK: - Custom Error

enum INWebSocketError: Error {
  case encodingFailed

  static let connectionTimeout = WebSocketError.disconnected
}
