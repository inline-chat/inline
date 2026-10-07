import AsyncAlgorithms
import InlineProtocol
import RealtimeV2

actor ChatLinkTestTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private nonisolated let startSignal = AsyncStream<Void>.makeStream()
  nonisolated var didStart: AsyncStream<Void> { startSignal.stream }
  private var connected = false
  private(set) var requestedChatID: Int64?

  func isApplicationAuthenticatedOnConnect() async -> Bool { true }
  func start() async {
    await events.send(.connecting)
    startSignal.continuation.yield(())
    startSignal.continuation.finish()
  }
  func allowConnection() async {
    connected = true
    await events.send(.connected)
  }
  func stop() async {
    connected = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }
  func send(_ message: ClientMessage) async throws {
    guard connected else { throw TransportError.notConnected }
    guard case let .rpcCall(call) = message.body, case let .getChat(input) = call.input else { return }
    requestedChatID = input.peerID.chat.chatID
    var result = InlineProtocol.RpcResult()
    result.reqMsgID = message.id
    result.result = .getChat(.with {
      $0.chat = .with { $0.id = input.peerID.chat.chatID; $0.date = 10; $0.seq = 0; $0.peerID.user.userID = 8_409_231 }
      $0.dialog = .with { $0.chatID = input.peerID.chat.chatID; $0.peer.user.userID = 8_409_231 }
      $0.user = .with { $0.id = 8_409_231; $0.firstName = "Cold Bot"; $0.bot = true }
    })
    var response = ServerProtocolMessage()
    response.body = .rpcResult(result)
    await events.send(.message(response))
  }
}
