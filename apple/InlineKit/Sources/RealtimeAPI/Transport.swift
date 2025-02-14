import InlineProtocol

protocol Transport {
  func start() async throws -> Void
  func stop() async

  func send(_ message: ClientMessage) async throws -> Void

  func addStateObserver(
    _ observer: @escaping @Sendable (TransportConnectionState) -> Void
  ) -> Void

  func addMessageHandler(
    _ handler: @escaping @Sendable (ServerProtocolMessage) -> Void
  ) -> Void
}
