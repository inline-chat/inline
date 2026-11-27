import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
import Testing

@testable import RealtimeV2

private actor ReplyHandlerTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()
  private(set) var handler: TransferReplyHandler?
  private(set) var sent: [ClientMessage] = []

  func setTransferReplyHandler(_ handler: TransferReplyHandler?) { self.handler = handler }
  func start() async {}
  func stop() async {}
  func send(_ message: ClientMessage) async throws { sent.append(message) }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(2)
  while await condition() == false {
    if clock.now >= deadline { return false }
    try? await clock.sleep(for: .milliseconds(5))
  }
  return true
}

@Suite("Transfer reply path")
struct TransferReplyPathTests {
  @Test("a transfer reply completes its call while the ordered event loop is busy")
  func replyBypassesOrderedEvents() async throws {
    let transport = ReplyHandlerTransport()
    let session = ProtocolSession(transport: transport, auth: Auth.mocked(authenticated: true).handle)
    await session.start()
    #expect(await eventually { await transport.handler != nil })

    let call = Task {
      try await session.callRpc(method: .saveUploadPart, input: nil, timeout: .seconds(5))
    }
    #expect(await eventually { await transport.sent.count == 1 })
    let requestID = try #require(await transport.sent.first?.id)

    // Nobody consumes the session's events, so this update holds the ordered loop forever,
    // like a long catch-up would.
    var update = ServerProtocolMessage()
    update.body = .message(.with { $0.update = UpdatesPayload() })
    let blocking = Task { await transport.events.send(.message(update)) }

    var reply = ServerProtocolMessage()
    reply.body = .rpcResult(.with {
      $0.reqMsgID = requestID
      $0.result = .saveUploadPart(SaveUploadPartResult())
    })
    let handler = try #require(await transport.handler)
    #expect(await handler(reply))
    #expect(try await call.value == .saveUploadPart(SaveUploadPartResult()))

    // A reply no direct call waits for goes back to the ordered path.
    var unknown = reply
    unknown.rpcResult.reqMsgID = requestID &+ 1
    #expect(await handler(unknown) == false)
    blocking.cancel()
  }
}
