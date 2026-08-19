import AsyncAlgorithms
import InlineProtocol

enum ProtocolSessionEvent: Sendable {
  case transportConnecting(sessionID: UInt64)
  case transportConnected(sessionID: UInt64)
  case transportDisconnected(sessionID: UInt64, errorDescription: String?)

  case protocolOpen(sessionID: UInt64)
  case authFailed
  case connectionError(reason: InlineProtocol.ConnectionError.Reason)

  case ack(msgId: UInt64)
  case rpcResult(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?)
  case rpcError(msgId: UInt64, rpcError: InlineProtocol.RpcError)
  case rpcCommitOutcomeUnknown(msgId: UInt64)
  case updates(updates: InlineProtocol.UpdatesPayload)
  case grid(event: InlineProtocol.GridEvent)
  case pong(nonce: UInt64)
}

/// Carries the account collector's processing acknowledgement back to the
/// protocol receive owner. Delivery into an async channel is only a handoff;
/// it does not mean an update or transaction result was durably applied.
struct ProtocolSessionEventEnvelope: Sendable {
  let event: ProtocolSessionEvent
  private let processingReceipt: ProtocolSessionEventProcessingReceipt?

  static func lifecycle(_ event: ProtocolSessionEvent) -> Self {
    Self(event: event, processingReceipt: nil)
  }

  static func account(_ event: ProtocolSessionEvent) -> Self {
    Self(event: event, processingReceipt: ProtocolSessionEventProcessingReceipt())
  }

  func waitUntilProcessed() async {
    await processingReceipt?.wait()
  }

  func markProcessed() async {
    await processingReceipt?.finish()
  }
}

private actor ProtocolSessionEventProcessingReceipt {
  private var finished = false
  private var waiter: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !finished else { return }
    await withCheckedContinuation { continuation in
      waiter = continuation
    }
  }

  func finish() {
    guard !finished else { return }
    finished = true
    waiter?.resume()
    waiter = nil
  }
}

protocol ProtocolSessionType: AnyObject, Sendable {
  var events: AsyncChannel<ProtocolSessionEventEnvelope> { get }

  func startTransport(sessionID: UInt64) async
  func stopTransport() async
  func startHandshake(sessionID: UInt64) async

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
