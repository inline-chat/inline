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
  nonisolated let events = AsyncChannel<ProtocolSessionEventEnvelope>()

  // State
  var state: ClientState = .connecting

  // RPC continuations keyed by message id for low-level, special-case RPC calls
  private struct PendingDirectRpcContinuation {
    let continuation: CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>
    let readOnly: Bool
    var attempted: Bool
  }

  private var rpcContinuations: [UInt64: PendingDirectRpcContinuation] = [:]
  private static let maxPendingDirectRPCs = 64

  // Message sequencing and ID generation
  private var seq: UInt32 = 0
  private let epoch = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00:00 UTC
  private var lastTimestamp: UInt32 = 0
  private var sequence: UInt32 = 0
  private var transportSessionID: UInt64?
  private var handshakeSessionID: UInt64?
  private var nextAccountEventID: UInt64 = 0
  private var pendingAccountEvents: [UInt64: ProtocolSessionEventEnvelope] = [:]

  private var listenerTask: Task<Void, Never>?

  init(transport: Transport, auth: AuthHandle) {
    self.transport = transport
    self.auth = auth
  }

  deinit {
    listenerTask?.cancel()
    listenerTask = nil
  }

  func reset() async {
    seq = 0
    cancelAllRpcContinuations()
    handshakeSessionID = nil
    state = .connecting
    await releasePendingAccountEvents()
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
        guard let transportSessionID else {
          log.warning("Ignoring transport connected without an active session")
          continue
        }
        log.trace("Protocol session: transport connected")
        await emitLifecycleEvent(.transportConnected(sessionID: transportSessionID))

      case .connecting:
        guard let transportSessionID else {
          log.warning("Ignoring transport connecting without an active session")
          continue
        }
        await emitLifecycleEvent(.transportConnecting(sessionID: transportSessionID))

      case let .disconnected(errorDescription):
        guard let disconnectedSessionID = transportSessionID else {
          log.trace("Ignoring transport disconnected without an active session")
          continue
        }
        transportSessionID = nil
        log.trace("Protocol session: transport disconnected")
        await reset()
        await emitLifecycleEvent(.transportDisconnected(
          sessionID: disconnectedSessionID,
          errorDescription: errorDescription
        ))

      case let .message(message):
        log.trace("Protocol session received transport message: \(message)")
        await handleTransportMessage(message)

      case let .rpcCommitOutcomeUnknown(msgId):
        await emitAccountEvent(.rpcCommitOutcomeUnknown(msgId: msgId))
        await failRpcContinuation(for: msgId, error: ProtocolSessionError.commitOutcomeUnknown)
      }
    }
  }

  private func emitLifecycleEvent(_ event: ProtocolSessionEvent) async {
    await events.send(.lifecycle(event))
  }

  private func emitAccountEvent(_ event: ProtocolSessionEvent) async {
    nextAccountEventID &+= 1
    let eventID = nextAccountEventID
    let envelope = ProtocolSessionEventEnvelope.account(event)
    pendingAccountEvents[eventID] = envelope
    await events.send(envelope)
    await envelope.waitUntilProcessed()
    pendingAccountEvents.removeValue(forKey: eventID)
  }

  private func releasePendingAccountEvents() async {
    let pending = Array(pendingAccountEvents.values)
    pendingAccountEvents.removeAll()
    for envelope in pending {
      await envelope.markProcessed()
    }
  }

  /// Handle incoming transport messages
  private func handleTransportMessage(_ message: ServerProtocolMessage) async {
    switch message.body {
    case .connectionOpen:
      guard let handshakeSessionID else {
        log.warning("Ignoring connection open without an active handshake")
        return
      }
      await markOpen(sessionID: handshakeSessionID)

    case let .rpcResult(result):
      await emitAccountEvent(.rpcResult(msgId: result.reqMsgID, rpcResult: result.result))
      completeRpcResult(msgId: result.reqMsgID, rpcResult: result.result)

    case let .rpcError(error):
      await emitAccountEvent(.rpcError(msgId: error.reqMsgID, rpcError: error))
      completeRpcError(msgId: error.reqMsgID, rpcError: error)

    case let .ack(ack):
      log.trace("Received ack: \(ack.msgID)")
      await emitAccountEvent(.ack(msgId: ack.msgID))

    case let .message(serverMessage):
      log.trace("Received server message: \(serverMessage)")
      switch serverMessage.payload {
      case let .update(updatesPayload):
        await emitAccountEvent(.updates(updates: updatesPayload))
      case let .grid(gridEvent):
        await emitAccountEvent(.grid(event: gridEvent))
      default:
        log.trace("Protocol session: unhandled message type: \(String(describing: serverMessage.payload))")
      }

    case let .pong(pong):
      log.trace("Received pong: \(pong.nonce)")
      await emitLifecycleEvent(.pong(nonce: pong.nonce))

    case let .connectionError(error):
      log.error("Protocol session: server rejected connection init reason=\(error.reason)")
      await emitAccountEvent(.connectionError(reason: error.reason))

    default:
      log.trace("Protocol session: unhandled message type: \(String(describing: message.body))")
    }
  }

  // MARK: - ID Generation

  /// Generate a unique message ID using timestamp and sequence
  private func generateId() -> UInt64 {
    let timestamp = max(currentTimestamp(), lastTimestamp)

    if timestamp <= lastTimestamp {
      sequence &+= 1
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
    seq &+= 1
  }

  private func getBuildNumber() -> Int32 {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
      .flatMap { Int32($0) } ?? 0
  }

  private func getOSVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
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

    guard token != nil || auth.inlineProtocolCredentials() != nil else {
      log.error("No token available for connection init")
      throw ProtocolSessionError.notAuthorized
    }

    let msg = wrapMessage(body: .connectionInit(.with {
      $0.token = token ?? ""
      $0.buildNumber = getBuildNumber()
      #if os(macOS)
      $0.osVersion = getOSVersion()
      #endif
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

  func startHandshake(sessionID: UInt64) async {
    handshakeSessionID = sessionID
    if await transport.isApplicationAuthenticatedOnConnect() {
      guard !Task.isCancelled, handshakeSessionID == sessionID else { return }
      await markOpen(sessionID: sessionID)
      return
    }

    do {
      try await sendConnectionInit()
      log.trace("Sent authentication message")
    } catch let error as ProtocolSessionError {
      guard !Task.isCancelled else { return }
      switch error {
      case .notAuthorized:
          await emitAccountEvent(.authFailed)
      default:
        await emitLifecycleEvent(.transportDisconnected(
          sessionID: sessionID,
          errorDescription: "handshake_failed"
        ))
      }
    } catch {
      guard !Task.isCancelled else { return }
      await emitLifecycleEvent(.transportDisconnected(
        sessionID: sessionID,
        errorDescription: "handshake_failed"
      ))
    }
  }

  private func markOpen(sessionID: UInt64) async {
    guard handshakeSessionID == sessionID else {
      log.warning("Ignoring stale protocol open session=\(sessionID)")
      return
    }
    handshakeSessionID = nil
    state = .open
    log.info("Protocol session: connection established session=\(sessionID)")
    await emitLifecycleEvent(.protocolOpen(sessionID: sessionID))
  }

  // MARK: - Public API

  func startTransport(sessionID: UInt64) async {
    transportSessionID = sessionID
    await transport.start()
  }

  func stopTransport() async {
    transportSessionID = nil
    await reset()
    await transport.stop()
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
  case rpcError(errorCode: InlineProtocol.RpcError.Code, message: String, code: Int)
  case stopped
  case timeout
  case commitOutcomeUnknown
  case capacityExceeded
}

// MARK: - RPC Extension

extension ProtocolSession {
  // MARK: - RPC Calls

  @discardableResult
  func sendRpc(method: InlineProtocol.Method, input: RpcCall.OneOf_Input?) async throws -> UInt64 {
    try await sendRpc(method: method, input: input) { _ in }
  }

  /// Registers higher-level request ownership before the transport write. A fast transport may
  /// deliver a response as soon as bytes reach the wire, so post-send registration loses results.
  @discardableResult
  func sendRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    beforeSend: @escaping @Sendable (UInt64) async throws -> Void
  ) async throws -> UInt64 {
    let message = wrapMessage(body: .rpcCall(.with {
      $0.method = method
      $0.input = input
    }))

    try await beforeSend(message.id)

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
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    try Task.checkCancellation()
    guard rpcContinuations.count < Self.maxPendingDirectRPCs else {
      throw ProtocolSessionError.capacityExceeded
    }
    let message = wrapMessage(body: .rpcCall(.with {
      $0.method = method
      $0.input = input
    }))

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
        InlineProtocol.RpcResult.OneOf_Result?,
        any Error
      >) in
        // Store continuation first to avoid race if result arrives very fast.
        storeRpcContinuation(for: message.id, method: method, continuation: continuation)
        if Task.isCancelled {
          cancelRpcContinuation(for: message.id)
          return
        }

        Task {
          // Admission is the irreversible boundary for direct RPCs. Mark it on
          // this actor before awaiting the transport so cancellation can never
          // race a send that has already begun and report a false not-sent
          // cancellation.
          guard self.beginRpcDispatch(for: message.id) else { return }
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
    } onCancel: {
      Task { await self.cancelRpcContinuation(for: message.id) }
    }
  }

  private func timeOutRpcContinuation(after timeout: Duration, msgId: UInt64) async {
    try? await Task.sleep(for: timeout)
    guard !Task.isCancelled else { return }
    if rpcContinuations[msgId] != nil {
      let pending = rpcContinuations[msgId]
      let error: ProtocolSessionError = pending?.attempted == true && pending?.readOnly == false
        ? .commitOutcomeUnknown
        : .timeout
      await failRpcContinuation(for: msgId, error: error)
    }
  }

  // MARK: - Continuations (RPC)

  private func storeRpcContinuation(
    for msgId: UInt64,
    method: InlineProtocol.Method,
    continuation: CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>
    ) {
    rpcContinuations[msgId] = PendingDirectRpcContinuation(
      continuation: continuation,
      readOnly: inlineProtocolRpcMethodIsReadOnly(method),
      attempted: false
    )
  }

  private func beginRpcDispatch(for msgId: UInt64) -> Bool {
    guard var pending = rpcContinuations[msgId] else { return false }
    pending.attempted = true
    rpcContinuations[msgId] = pending
    return true
  }

  private func getAndRemoveRpcContinuation(
    for msgId: UInt64
  ) -> CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>? {
    let continuation = rpcContinuations[msgId]?.continuation
    rpcContinuations.removeValue(forKey: msgId)
    return continuation
  }

  private func completeRpcResult(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?) {
    getAndRemoveRpcContinuation(for: msgId)?.resume(returning: rpcResult)
  }

  private func completeRpcError(msgId: UInt64, rpcError: InlineProtocol.RpcError) {
    let error = ProtocolSessionError.rpcError(
      errorCode: rpcError.errorCode,
      message: rpcError.message,
      code: Int(rpcError.code)
    )
    getAndRemoveRpcContinuation(for: msgId)?.resume(throwing: error)
  }

  private func failRpcContinuation(for msgId: UInt64, error: any Error) async {
    getAndRemoveRpcContinuation(for: msgId)?.resume(throwing: error)
  }

  private func cancelRpcContinuation(for msgId: UInt64) {
    guard let pending = rpcContinuations.removeValue(forKey: msgId) else { return }
    pending.continuation.resume(
      throwing: pending.attempted && !pending.readOnly
        ? ProtocolSessionError.commitOutcomeUnknown
        : CancellationError()
    )
  }

  private func cancelAllRpcContinuations() {
    for (_, pending) in rpcContinuations {
      pending.continuation.resume(
        throwing: pending.attempted && !pending.readOnly
          ? ProtocolSessionError.commitOutcomeUnknown
          : ProtocolSessionError.stopped
      )
    }
    rpcContinuations.removeAll()
  }
}

func inlineProtocolRpcMethodIsReadOnly(_ method: InlineProtocol.Method) -> Bool {
  switch method {
  case .getMe, .getPeerPhoto, .getChatHistory, .getSpaceMembers,
       .getChatParticipants, .getChats, .getUserSettings, .getUpdatesState,
       .getChat, .getUpdates, .searchMessages, .listBots, .revealBotToken,
       .getMessages, .getBotCommands, .getPeerBotCommands, .getBotPresence,
       .getSessions, .checkUsername, .getSpaceURLPreviewExclusions,
       .getUserGroups, .getSpaceSettings, .getThreadReferences,
       .getThreadSubthreads, .getPeerBots, .getMyBotCapabilities, .getGrid,
       .getGridHome, .getExternalProfilePhoto, .getChatTranscript,
       .searchExternalResources, .listConnectors, .searchUsers,
       .resolveURLPreview, .getBotAgent, .listBotAgents, .getConnectorConfig,
       .getUploadState:
    true
  default:
    false
  }
}
