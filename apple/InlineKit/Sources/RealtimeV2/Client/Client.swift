import AsyncAlgorithms
import Auth
import Foundation
import InlineProtocol
import Logger

/// Handles protocol messaging and RPC lifecycle over a live transport connection.
actor ProtocolSession: ProtocolSessionType {
  private let log = Log.scoped("RealtimeV2.ProtocolSession")
  private let transport: Transport
  private let auth: AuthHandle

  // Events
  nonisolated let events = AsyncChannel<ProtocolSessionEvent>()

  // State
  var state: ClientState = .connecting

  // RPC continuations keyed by message id for low-level, special-case RPC calls
  private var rpcContinuations: [UInt64: CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>] = [:]

  // Message sequencing and ID generation
  private var seq: UInt32 = 0
  private let epoch = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00:00 UTC
  private var lastTimestamp: UInt32 = 0
  private var sequence: UInt32 = 0

  private var listenerTask: Task<Void, Never>?

  init(transport: Transport, auth: AuthHandle) {
    self.transport = transport
    self.auth = auth
  }

  deinit {
    listenerTask?.cancel()
    listenerTask = nil
  }

  func reset() {
    seq = 0
    lastTimestamp = 0
    sequence = 0
    cancelAllRpcContinuations(with: ProtocolSessionError.stopped)
    state = .connecting
  }

  // MARK: - Startup

  func start() {
    guard listenerTask == nil else { return }
    listenerTask = Task { [weak self] in
      await self?.startListeners()
    }
  }

  // MARK: - Listeners

  /// Start listening for transport events to handle protocol messages
  private func startListeners() async {
    log.trace("Starting protocol session transport events listener")
    for await event in transport.events {
      guard !Task.isCancelled else { return }

      switch event {
      case .connected:
        log.trace("Protocol session: transport connected")
        await events.send(.transportConnected)

      case .connecting:
        await events.send(.transportConnecting)

      case let .disconnected(errorDescription):
        log.trace("Protocol session: transport disconnected")
        reset()
        await events.send(.transportDisconnected(errorDescription: errorDescription))

      case let .message(message):
        log.trace("Protocol session received transport message: \(message)")
        await handleTransportMessage(message)
      }
    }
  }

  /// Handle incoming transport messages
  private func handleTransportMessage(_ message: ServerProtocolMessage) async {
    switch message.body {
    case .connectionOpen:
      state = .open
      log.info("Protocol session: connection established")
      await events.send(.protocolOpen)

    case let .rpcResult(result):
      completeRpcResult(msgId: result.reqMsgID, rpcResult: result.result)
      await events.send(.rpcResult(msgId: result.reqMsgID, rpcResult: result.result))

    case let .rpcError(error):
      completeRpcError(msgId: error.reqMsgID, rpcError: error)
      await events.send(.rpcError(msgId: error.reqMsgID, rpcError: error))

    case let .ack(ack):
      log.trace("Received ack: \(ack.msgID)")
      await events.send(.ack(msgId: ack.msgID))

    case let .message(serverMessage):
      log.trace("Received server message: \(serverMessage)")
      switch serverMessage.payload {
      case let .update(updatesPayload):
        await events.send(.updates(updates: updatesPayload))
      default:
        log.trace("Protocol session: unhandled message type: \(String(describing: serverMessage.payload))")
      }

    case let .pong(pong):
      log.trace("Received pong: \(pong.nonce)")
      await events.send(.pong(nonce: pong.nonce))

    default:
      log.trace("Protocol session: unhandled message type: \(String(describing: message.body))")
    }
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
    log.trace("sending connection init")

    var token = auth.token()
    if token == nil {
      await auth.refreshFromStorage()
      token = auth.token()
    }

    guard let token else {
      log.error("No token available for connection init")
      throw ProtocolSessionError.notAuthorized
    }

    let msg = wrapMessage(body: .connectionInit(.with {
      $0.token = token
      $0.buildNumber = getBuildNumber()
      /// Layer 2 Changes:
      /// - Contains a fix that doesn't send updates on send message back into the same session.
      $0.layer = 2
    }))

    do {
      try await transport.send(msg)
    } catch let error as TransportError {
      switch error {
      case .notConnected:
        throw ProtocolSessionError.notConnected
      }
    } catch {
      throw error
    }
    log.trace("connection init sent successfully")
  }

  func startHandshake() async {
    do {
      try await sendConnectionInit()
      log.trace("Sent authentication message")
    } catch let error as ProtocolSessionError {
      switch error {
      case .notAuthorized:
        await events.send(.authFailed)
      default:
        await events.send(.transportDisconnected(errorDescription: "handshake_failed"))
      }
    } catch {
      await events.send(.transportDisconnected(errorDescription: "handshake_failed"))
    }
  }

  // MARK: - Public API

  func startTransport() async {
    await transport.start()
  }

  func stopTransport() async {
    await transport.stop()
    reset()
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
}

// MARK: - Errors

enum ProtocolSessionError: Error {
  case notAuthorized
  case notConnected
  case rpcError(errorCode: String, message: String, code: Int)
  case stopped
  case timeout
}

// MARK: - RPC Extension

extension ProtocolSession {
  // MARK: - RPC Calls

  @discardableResult
  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 {
    let message = wrapMessage(body: .rpcCall(.with {
      $0.method = method
      $0.input = input
    }))

    do {
      try await transport.send(message)
    } catch let error as TransportError {
      switch error {
      case .notConnected:
        throw ProtocolSessionError.notConnected
      }
    } catch {
      throw error
    }

    return message.id
  }

  /// Low-level RPC that waits for the server response or error using continuations.
  /// This is independent of the higher-level transactions system in `RealtimeV2`.
  @discardableResult
  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration? = .seconds(15)
  ) async throws -> InlineProtocol.RpcResult
    .OneOf_Result?
  {
    let message = wrapMessage(body: .rpcCall(.with {
      $0.method = method
      $0.input = input
    }))

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
      InlineProtocol.RpcResult.OneOf_Result?,
      any Error
    >) in
      // Store continuation first to avoid race if result arrives very fast
      storeRpcContinuation(for: message.id, continuation: continuation)

      Task {
        do {
          do {
            try await self.transport.send(message)
          } catch let error as TransportError {
            switch error {
            case .notConnected:
              await self.failRpcContinuation(for: message.id, error: ProtocolSessionError.notConnected)
              return
            }
          }
        } catch {
          await self.failRpcContinuation(for: message.id, error: error)
        }
      }

      if let timeout {
        Task { [weak self] in
          guard let self else { return }
          await self.timeOutRpcContinuation(after: timeout, msgId: message.id)
        }
      }
    }
  }

  private func timeOutRpcContinuation(after timeout: Duration, msgId: UInt64) async {
    try? await Task.sleep(for: timeout)
    guard !Task.isCancelled else { return }
    if hasPendingRpcContinuation(for: msgId) {
      await failRpcContinuation(for: msgId, error: ProtocolSessionError.timeout)
    }
  }

  // MARK: - Continuations (RPC)

  private func storeRpcContinuation(
    for msgId: UInt64,
    continuation: CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>
  ) {
    rpcContinuations[msgId] = continuation
  }

  private func getAndRemoveRpcContinuation(for msgId: UInt64)
    -> CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>?
  {
    let continuation = rpcContinuations[msgId]
    rpcContinuations.removeValue(forKey: msgId)
    return continuation
  }

  private func completeRpcResult(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?) {
    getAndRemoveRpcContinuation(for: msgId)?.resume(returning: rpcResult)
  }

  private func completeRpcError(msgId: UInt64, rpcError: InlineProtocol.RpcError) {
    let codeString = String(describing: rpcError.errorCode)
    let error = ProtocolSessionError.rpcError(errorCode: codeString, message: rpcError.message, code: Int(rpcError.code))
    getAndRemoveRpcContinuation(for: msgId)?.resume(throwing: error)
  }

  private func failRpcContinuation(for msgId: UInt64, error: any Error) async {
    getAndRemoveRpcContinuation(for: msgId)?.resume(throwing: error)
  }

  private func hasPendingRpcContinuation(for msgId: UInt64) -> Bool {
    rpcContinuations[msgId] != nil
  }

  private func cancelAllRpcContinuations(with error: any Error = ProtocolSessionError.stopped) {
    for (_, continuation) in rpcContinuations {
      continuation.resume(throwing: error)
    }
    rpcContinuations.removeAll()
  }
}
