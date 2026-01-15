import AsyncAlgorithms
import Auth
import Foundation
import InlineProtocol
import Logger

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

/// Communicate with the transport and handle auth, generating messages, sequencing, track ACKs, etc.
actor ProtocolClient: ProtocolClientType {
  private let log = Log.scoped("RealtimeV2.ProtocolClient")
  private let transport: Transport
  private let auth: Auth

  // Events
  let events = AsyncChannel<ClientEvent>()

  // State
  var state: ClientState = .connecting

  // RPC continuations keyed by message id for low-level, special-case RPC calls
  private var rpcContinuations: [UInt64: CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>] = [:]

  // Message sequencing and ID generation
  private var seq: UInt32 = 0
  private let epoch = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00:00 UTC
  private var lastTimestamp: UInt32 = 0
  private var sequence: UInt32 = 0

  // Connection

  /// Connection attempt number for handling reconnection delay
  private var connectionAttemptNo: UInt32 = 0

  /// Reconnection task for handling client failure with a local delay
  private var reconnectionTask: Task<Void, Never>?

  /// Authentication timeout task for handling authentication failure after 10s
  private var authenticationTimeoutTask: Task<Void, Never>?

  /// Tasks for managing listeners
  private var tasks: Set<Task<Void, Never>> = []

  /// Ping pong service to keep connection alive
  private let pingPong: PingPongService

  #if canImport(UIKit) || canImport(AppKit)
  private var lifecycleObserversInstalled = false
  #endif
  private var isHandlingForegroundTransition = false

  init(transport: Transport, auth: Auth) {
    self.transport = transport
    self.auth = auth
    pingPong = PingPongService()
    Task { await pingPong.configure(client: self) }

    Task {
      await self.startListeners()
    }

    #if canImport(UIKit) || canImport(AppKit)
    Task { await self.startLifecycleObservers() }
    #endif
  }

  deinit {
    #if canImport(UIKit) || canImport(AppKit)
    NotificationCenter.default.removeObserver(self)
    #endif
  }

  func reset() {
    seq = 0
    lastTimestamp = 0
    connectionAttemptNo = 0
    sequence = 0
    stopAuthenticationTimeout()
    reconnectionTask?.cancel()
    reconnectionTask = nil
    Task { await pingPong.stop() }
    cancelAllRpcContinuations(with: ProtocolClientError.stopped)
  }

  // MARK: - State

  func handleForegroundTransition() async {
    guard auth.getIsLoggedIn() == true else { return }
    guard !isHandlingForegroundTransition else { return }
    isHandlingForegroundTransition = true
    defer { isHandlingForegroundTransition = false }
    log.debug("Foreground transition: resetting reconnection delay")
    connectionAttemptNo = 0
    reconnectionTask?.cancel()
    reconnectionTask = nil
    stopAuthenticationTimeout()

    if state == .open {
      let probeSucceeded = await pingPong.probeConnection(timeout: .seconds(3))
      if probeSucceeded {
        log.debug("Foreground probe succeeded; keeping existing connection")
        return
      }

      log.warning("Foreground probe timed out; reconnecting")
    }

    await transport.handleForegroundTransition()
  }

  private func connectionOpen() async {
    state = .open
    Task { await events.send(.open) }
    stopAuthenticationTimeout()
    reconnectionTask?.cancel()
    reconnectionTask = nil
    connectionAttemptNo = 0
    await pingPong.start()
  }

  private func connecting() async {
    state = .connecting
    Task { await events.send(.connecting) }
    stopAuthenticationTimeout()
    await pingPong.stop()
    cancelAllRpcContinuations(with: ProtocolClientError.notConnected)
  }

  // MARK: - Listeners

  #if canImport(UIKit) || canImport(AppKit)
  private func startLifecycleObservers() {
    guard !lifecycleObserversInstalled else { return }
    lifecycleObserversInstalled = true

    #if canImport(UIKit)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    #elseif canImport(AppKit)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    #endif
  }

  @objc private nonisolated func handleAppDidBecomeActive() {
    Task { await self.handleForegroundTransition() }
  }
  #endif

  /// Start listening for transport events to handle protocol messages
  private func startListeners() async {
    // Transport events
    Task.detached {
      self.log.trace("Starting protocol client transport events listener")
      for await event in self.transport.events {
        guard !Task.isCancelled else { return }

        switch event {
        case .connected:
          self.log.trace("Protocol client: Transport connected")
          Task {
            await self.authenticate()
          }

        case let .message(message):
          self.log.trace("Protocol client received transport message: \(message)")
          Task {
            await self.handleTransportMessage(message)
          }

        case .connecting:
          await self.connecting()

        case .stopping:
          self.log.trace("Protocol client: Transport stopping. Resetting state and clearing RPC calls")
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
      completeRpcResult(msgId: result.reqMsgID, rpcResult: result.result)
      Task { await events.send(.rpcResult(msgId: result.reqMsgID, rpcResult: result.result)) }

    case let .rpcError(error):
      completeRpcError(msgId: error.reqMsgID, rpcError: error)
      Task { await events.send(.rpcError(msgId: error.reqMsgID, rpcError: error)) }

    case let .ack(ack):
      log.trace("Received ack: \(ack.msgID)")
      Task { await events.send(.ack(msgId: ack.msgID)) }

    case let .message(serverMessage):
      log.trace("Received server message: \(serverMessage)")
      switch serverMessage.payload {
      case let .update(updatesPayload):
        Task { await events.send(.updates(updates: updatesPayload)) }
      default:
        log.trace("Protocol client: Unhandled message type: \(String(describing: serverMessage.payload))")
      }

    case let .pong(pong):
      log.trace("Received pong: \(pong.nonce)")
      Task { await pingPong.pong(nonce: pong.nonce) }

    default:
      log.trace("Protocol client: Unhandled message type: \(String(describing: message.body))")
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
      // Reconnect with delay??
    }
  }

  func reconnect(skipDelay: Bool = false) async {
    log.trace("Reconnecting transport")
    await transport.reconnect(skipDelay: skipDelay)
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

    guard let token = auth.getToken() else {
      log.error("No token available for connection init")
      throw ProtocolClientError.notAuthorized
    }

    let msg = wrapMessage(body: .connectionInit(.with {
      $0.token = token
      $0.buildNumber = getBuildNumber()
      /// Layer 2 Changes:
      /// - Contains a fix that doesn't send updates on send message back into the same session.
      $0.layer = 2
    }))

    try await transport.send(msg)
    log.trace("connection init sent successfully")
  }

  /// Send connection init
  private func authenticate() async {
    do {
      try await sendConnectionInit()

      log.trace("Sent authentication message")

      startAuthenticationTimeout()
    } catch {
      log.error("Failed to authenticate, attempting restart", error: error)
      handleClientFailure()
    }
  }

  private func startAuthenticationTimeout() {
    authenticationTimeoutTask = Task.detached(name: "authentication timeout") { [weak self] in
      try? await Task.sleep(for: .seconds(10))

      guard let self else { return }

      guard !Task.isCancelled else { return }

      if await state == .connecting {
        log.error("Authentication timeout. Reconnecting")
        // Skip delay because we already have a delay here
        Task { await self.reconnect(skipDelay: true) }
      }
    }
  }

  private func stopAuthenticationTimeout() {
    authenticationTimeoutTask?.cancel()
    authenticationTimeoutTask = nil
  }

  /// This is when transport works fine but server is not responding to our messages or we have a failure inside the
  /// Client. We need to clear client's state, with a timeout, reconnect and start over.
  private func handleClientFailure() {
    log.debug("Client failure. Reconnecting")
    connectionAttemptNo = connectionAttemptNo &+ 1
    stopAuthenticationTimeout()

    reconnectionTask?.cancel()
    reconnectionTask = Task {
      try? await Task.sleep(for: .seconds(getReconnectionDelay()))

      guard !Task.isCancelled else { return }
      guard state != .open else { return }

      // Skip delay because we already have a delay here
      await self.reconnect(skipDelay: true)
    }
  }

  private func getReconnectionDelay() -> TimeInterval {
    let attemptNo = connectionAttemptNo

    if attemptNo >= 8 {
      return 8.0 + Double.random(in: 0.0 ... 5.0)
    }

    // Custom formula: 0.2 + (attempt^1.5 * 0.4)
    // Produces: 0.6, 1.33, 2.28, 3.4, 4.69, 6.12, 7.68s
    return min(8.0, 0.2 + pow(Double(attemptNo), 1.5) * 0.4)
  }

  // MARK: - Public API

  func startTransport() async {
    await transport.start()
  }

  func stopTransport() async {
    await transport.stop()
  }

  // MARK: - RPC Calls are defined in the `ProtocolClient` extension below
}

// MARK: - Errors

enum ProtocolClientError: Error {
  case notAuthorized
  case notConnected
  case rpcError(errorCode: String, message: String, code: Int)
  case stopped
  case timeout
}

// MARK: - RPC Extension

extension ProtocolClient {
  // MARK: - RPC Calls

  @discardableResult
  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 {
    let message = wrapMessage(body: .rpcCall(.with {
      $0.method = method
      $0.input = input
    }))

    try await transport.send(message)

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
          try await self.transport.send(message)
        } catch {
          await self.failRpcContinuation(for: message.id, error: error)
        }
      }

      if let timeout {
        Task.detached { [weak self] in
          try? await Task.sleep(for: timeout)
          guard let self else { return }
          guard !Task.isCancelled else { return }
          if await hasPendingRpcContinuation(for: message.id) {
            await failRpcContinuation(for: message.id, error: ProtocolClientError.timeout)
          }
        }
      }
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
    let error = ProtocolClientError.rpcError(errorCode: codeString, message: rpcError.message, code: Int(rpcError.code))
    getAndRemoveRpcContinuation(for: msgId)?.resume(throwing: error)
  }

  private func failRpcContinuation(for msgId: UInt64, error: any Error) async {
    getAndRemoveRpcContinuation(for: msgId)?.resume(throwing: error)
  }

  private func hasPendingRpcContinuation(for msgId: UInt64) -> Bool {
    rpcContinuations[msgId] != nil
  }

  private func cancelAllRpcContinuations(with error: any Error = ProtocolClientError.stopped) {
    for (_, continuation) in rpcContinuations {
      continuation.resume(throwing: error)
    }
    rpcContinuations.removeAll()
  }
}
