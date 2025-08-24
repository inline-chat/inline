import AsyncAlgorithms
import Auth
import Foundation
import InlineProtocol
import Logger

/// Communicate with the transport and handle auth, generating messages, sequencing, track ACKs, etc.
actor ProtocolClient {
  private let log = Log.scoped("RealtimeV2/ProtocolClient")
  private let transport: Transport
  private let auth: Auth

  // Events
  public let events = AsyncChannel<ClientEvent>()

  // State
  public var state: ClientState = .connecting

  // Message sequencing and ID generation
  private var seq: UInt32 = 0
  private let epoch = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00:00 UTC
  private var lastTimestamp: UInt32 = 0
  private var sequence: UInt32 = 0

  /// Message IDs to continuation handlers for pending RPC calls
  private var rpcCalls: [UInt64: CheckedContinuation<RpcResult.OneOf_Result?, any Error>] = [:]

  /// Tasks for managing listeners
  private var tasks: Set<Task<Void, Never>> = []

  /// Ping pong
  private let pingPong: PingPongService

  init(transport: Transport, auth: Auth) {
    self.transport = transport
    self.auth = auth
    pingPong = PingPongService()
    Task { await pingPong.configure(client: self) }

    Task {
      await self.startListeners()
    }
  }

  deinit {
    // Cancel all listener tasks
    for task in tasks {
      task.cancel()
    }
    tasks.removeAll()
  }

  public func reset() {
    cancelPendingRpcCalls(reason: .stopped)
    seq = 0
    lastTimestamp = 0
    sequence = 0
    rpcCalls.removeAll()
    Task { await pingPong.stop() }
  }

  // MARK: - State

  private func connectionOpen() async {
    state = .open
    Task { await events.send(.open) }
    await pingPong.start()
  }

  private func connecting() async {
    state = .connecting
    Task { await events.send(.connecting) }
    await pingPong.stop()
  }

  // MARK: - Listeners

  /// Start listening for transport events to handle protocol messages
  private func startListeners() async {
    // Transport events
    Task.detached {
      self.log.debug("Starting protocol client transport events listener")
      for await event in self.transport.events {
        guard !Task.isCancelled else { return }

        switch event {
          case .connected:
            self.log.debug("Protocol client: Transport connected")
            Task {
              await self.authenticate()
            }

          case let .message(message):
            self.log.debug("Protocol client received transport message: \(message)")
            Task {
              await self.handleTransportMessage(message)
            }

          case .connecting:
            await self.connecting()

          case .stopping:
            self.log.debug("Protocol client: Transport stopping. Resetting state and clearing RPC calls")
            Task {
              await self.reset()
            }
        }
      }
    }.store(in: &tasks)
  }

  /// Handle incoming transport messages
  private func handleTransportMessage(_ message: ServerProtocolMessage) async {
    switch message.body {
      case .connectionOpen:
        await connectionOpen()
        log.info("Protocol client: Connection established")

      case let .rpcResult(result):
        Task { await events.send(.rpcResult(msgId: result.reqMsgID, rpcResult: result.result)) }
        //handleRpcResult(result)

      case let .rpcError(error):
        Task { await events.send(.rpcError(msgId: error.reqMsgID, rpcError: error)) }
        //handleRpcError(error)

      case let .ack(ack):
        log.debug("Received ack: \(ack.msgID)")
        Task { await events.send(.ack(msgId: ack.msgID)) }

      case let .message(serverMessage):
        log.debug("Received server message: \(serverMessage)")
        switch serverMessage.payload {
          case let .update(updatesPayload):
            Task { await events.send(.updates(updates: updatesPayload)) }
          default:
            log.debug("Protocol client: Unhandled message type: \(String(describing: serverMessage.payload))")
        }

      case let .pong(pong):
        log.debug("Received pong: \(pong.nonce)")
        Task { await pingPong.pong(nonce: pong.nonce) }

      // TODO: Handle server messages (updates, notifications, etc.)
      default:
        log.debug("Protocol client: Unhandled message type: \(String(describing: message.body))")
    }
  }

  func sendPing(nonce: UInt64) async {
    let msg = wrapMessage(body: .ping(.with {
      $0.nonce = nonce
    }))
    do {
      try await transport.send(msg)
    } catch {
      log.error("Failed to send ping: \(error)")
    }
  }

  func reconnect() async {
    log.debug("Reconnecting transport")
    await transport.restart(retryDelay: nil)
  }

  // MARK: - ID Generation

  /// Generate a unique message ID using timestamp and sequence
  private func generateId() -> UInt64 {
    let timestamp = currentTimestamp()

    if timestamp == lastTimestamp {
      sequence += 1
    } else {
      sequence = 0
      lastTimestamp = timestamp
    }

    return (UInt64(timestamp) << 32) | UInt64(sequence)
  }

  private func currentTimestamp() -> UInt32 {
    UInt32(Date().timeIntervalSince(epoch))
  }

  // MARK: - Message Wrapping

  private func wrapMessage(body: ClientMessage.OneOf_Body) -> ClientMessage {
    advanceSeq()
    var clientMsg = ClientMessage()
    clientMsg.body = body
    clientMsg.id = generateId()
    clientMsg.seq = seq
    return clientMsg
  }

  private func advanceSeq() {
    seq = seq + 1
  }

  private func getBuildNumber() -> Int32 {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
      .flatMap { Int32($0) } ?? 0
  }

  // MARK: - Connection Initialization

  /// Send connection initialization message with authentication token
  func sendConnectionInit() async throws {
    log.debug("sending connection init")

    guard let token = auth.getToken() else {
      log.error("No token available for connection init")
      throw ProtocolClientError.notAuthorized
    }

    let msg = wrapMessage(body: .connectionInit(.with {
      $0.token = token
      $0.buildNumber = getBuildNumber()
    }))

    try await transport.send(msg)
    log.debug("connection init sent successfully")
  }

  /// Send connection init
  private func authenticate() async {
    do {
      try await sendConnectionInit()
      log.debug("Authentication successful")
    } catch {
      log.error("Failed to authenticate, attempting restart", error: error)
      Task { await transport.restart() }
    }
  }

  // MARK: - Public API

  public func startTransport() async {
    await transport.start()
  }

  public func stopTransport() async {
    await transport.stop()
  }

  // MARK: - RPC Calls

  public func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 {
    let message = wrapMessage(body: .rpcCall(.with {
      $0.method = method
      $0.input = input
    }))

    // FIXME: Should we move it to a task?
    try await transport.send(message)

    return message.id
  }

  /// Send an RPC call and wait for the response
  // func sendRpc(
  //   method: InlineProtocol.Method,
  //   input: RpcCall.OneOf_Input?
  // ) async throws -> RpcResult.OneOf_Result? {
  //   log.debug("sending RPC call for method: \(method)")

  //   let message = wrapMessage(body: .rpcCall(.with {
  //     $0.method = method
  //     $0.input = input
  //   }))

  //   return try await withCheckedThrowingContinuation { continuation in
  //     rpcCalls[message.id] = continuation

  //     // Send the message synchronously in the continuation context
  //     Task.detached { [transport] in
  //       do {
  //         try await transport.send(message)
  //         // Log success, but don't access self here
  //       } catch {
  //         // Remove the continuation and resume with error if sending fails
  //         continuation.resume(throwing: error)
  //       }
  //     }
  //   }
  // }

  // MARK: - Response Handling

  /// Handle incoming RPC result
  func handleRpcResult(_ result: RpcResult) {
    log.debug("received RPC result for message ID: \(result.reqMsgID)")

    guard let continuation = rpcCalls.removeValue(forKey: result.reqMsgID) else {
      log.warning("No pending RPC call found for message ID: \(result.reqMsgID)")
      return
    }

    continuation.resume(returning: result.result)
  }

  /// Handle incoming RPC error
  func handleRpcError(_ error: RpcError) {
    log.debug("received RPC error for message ID: \(error.reqMsgID) - \(error.message)")

    guard let continuation = rpcCalls.removeValue(forKey: error.reqMsgID) else {
      log.warning("No pending RPC call found for error message ID: \(error.reqMsgID)")
      return
    }

    continuation.resume(throwing: ProtocolClientError.rpcError(
      errorCode: String(describing: error.errorCode),
      message: error.message,
      code: Int(error.code)
    ))
  }

  /// Cancel all pending RPC calls with a specific error
  func cancelPendingRpcCalls(reason: ProtocolClientError) {
    log.debug("cancelling \(rpcCalls.count) pending RPC calls")

    for (_, continuation) in rpcCalls {
      continuation.resume(throwing: reason)
    }
    rpcCalls.removeAll()
  }
}

// MARK: - Errors

enum ProtocolClientError: Error {
  case notAuthorized
  case notConnected
  case rpcError(errorCode: String, message: String, code: Int)
  case stopped
}
