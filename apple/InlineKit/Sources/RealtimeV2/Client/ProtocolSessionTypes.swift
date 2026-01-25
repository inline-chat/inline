import AsyncAlgorithms
import InlineProtocol

enum ProtocolSessionEvent: Sendable {
  case transportConnecting
  case transportConnected
  case transportDisconnected(errorDescription: String?)

  case protocolOpen
  case authFailed

  case ack(msgId: UInt64)
  case rpcResult(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?)
  case rpcError(msgId: UInt64, rpcError: InlineProtocol.RpcError)
  case updates(updates: InlineProtocol.UpdatesPayload)
  case pong(nonce: UInt64)
}

protocol ProtocolSessionType: AnyObject, Sendable {
  var events: AsyncChannel<ProtocolSessionEvent> { get }

  func startTransport() async
  func stopTransport() async
  func startHandshake() async

  func sendPing(nonce: UInt64) async

  @discardableResult
  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64

  @discardableResult
  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result?
}
