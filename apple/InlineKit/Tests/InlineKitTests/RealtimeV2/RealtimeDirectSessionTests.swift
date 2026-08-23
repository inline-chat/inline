import AsyncAlgorithms
@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Testing

@Suite("RealtimeDirectSession", .serialized)
struct RealtimeDirectSessionTests {
  @Test("direct session connects, drains unsolicited updates, and never starts sync")
  func directSessionDoesNotStartAccountRuntime() async throws {
    let auth = Auth.mocked(authenticated: true)
    let transport = DirectSessionTestTransport(sendUpdateBeforeResult: true)
    let session = RealtimeDirectSession(transport: transport, auth: auth.handle)

    let result = try await session.callRpcDirect(method: .getMe, input: .getMe(.init()))
    #expect(result == nil)
    #expect(await transport.rpcMethods == [.getMe])

    await session.finish()
  }

  @Test("finish is terminal so a new extension attempt must use a new owner")
  func finishIsTerminal() async throws {
    let auth = Auth.mocked(authenticated: true)
    let session = RealtimeDirectSession(
      transport: DirectSessionTestTransport(sendUpdateBeforeResult: false),
      auth: auth.handle
    )

    _ = try await session.callRpcDirect(method: .getMe, input: .getMe(.init()))
    await session.finish()

    do {
      _ = try await session.callRpcDirect(method: .getMe, input: .getMe(.init()))
      Issue.record("Expected a finished direct session to reject reuse")
    } catch let error as RealtimeDirectRpcError {
      guard case .notConnected = error else {
        Issue.record("Unexpected direct-session error: \(error)")
        return
      }
    }
  }

  @Test("connection admission is bounded before any RPC can execute")
  func connectionAdmissionIsBounded() async {
    let auth = Auth.mocked(authenticated: true)
    let transport = DirectSessionTestTransport(
      sendUpdateBeforeResult: false,
      opens: false
    )
    let session = RealtimeDirectSession(
      transport: transport,
      auth: auth.handle,
      connectionAdmissionTimeout: .milliseconds(20)
    )

    do {
      _ = try await session.callRpcDirect(method: .getMe, input: .getMe(.init()))
      Issue.record("Expected a disconnected transport to reject before RPC execution")
    } catch let error as RealtimeDirectRpcError {
      guard case .notConnected = error else {
        Issue.record("Unexpected direct-session error: \(error)")
        return
      }
    } catch {
      Issue.record("Unexpected direct-session error: \(error)")
    }

    #expect(await transport.rpcMethods.isEmpty)
    await session.finish()
  }
}

private actor DirectSessionTestTransport: Transport {
  nonisolated let events = AsyncChannel<TransportEvent>()

  private let sendUpdateBeforeResult: Bool
  private let opens: Bool
  private var started = false
  private(set) var rpcMethods: [InlineProtocol.Method] = []

  init(sendUpdateBeforeResult: Bool, opens: Bool = true) {
    self.sendUpdateBeforeResult = sendUpdateBeforeResult
    self.opens = opens
  }

  func start() async {
    guard !started else { return }
    started = true
    await events.send(.connecting)
    if opens {
      await events.send(.connected)
    }
  }

  func stop() async {
    guard started else { return }
    started = false
    await events.send(.disconnected(errorDescription: "stopped"))
  }

  func send(_ message: ClientMessage) async throws {
    switch message.body {
      case .connectionInit:
        var open = ServerProtocolMessage()
        open.id = message.id
        open.body = .connectionOpen(.init())
        await events.send(.message(open))

      case let .rpcCall(call):
        rpcMethods.append(call.method)
        if sendUpdateBeforeResult {
          var payload = UpdatesPayload()
          payload.updates = []
          var serverMessage = ServerMessage()
          serverMessage.payload = .update(payload)
          var update = ServerProtocolMessage()
          update.id = message.id &+ 1
          update.body = .message(serverMessage)
          await events.send(.message(update))
        }

        var rpcResult = RpcResult()
        rpcResult.reqMsgID = message.id
        var response = ServerProtocolMessage()
        response.id = message.id
        response.body = .rpcResult(rpcResult)
        await events.send(.message(response))

      default:
        break
    }
  }
}
