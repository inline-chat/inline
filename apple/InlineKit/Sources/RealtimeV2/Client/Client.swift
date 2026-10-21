import InlineConfig
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

  // Direct RPCs. The pure `RequestLedger` owns request state across connections; this actor
  // only runs its I/O (pre-send validation, transport writes, timers) and maps wire IDs.
  struct DirectRequestPayload: Sendable {
    let method: InlineProtocol.Method
    let input: RpcCall.OneOf_Input?
  }

  enum DirectReply: Sendable {
    case result(InlineProtocol.RpcResult.OneOf_Result?)
    case error(InlineProtocol.RpcError)
  }

  typealias DirectLedger = RequestLedger<DirectRequestPayload, DirectReply>

  private struct DirectAttemptKey: Hashable {
    let request: UInt64
    let attempt: UInt64
  }

  private struct PendingDirectRequest {
    let continuation: CheckedContinuation<InlineProtocol.RpcResult.OneOf_Result?, any Error>
    let beforeDispatch: @Sendable () async throws -> Void
    /// Set when `beforeDispatch` rejected the request; resolves the caller with that error.
    var localError: (any Error)?
  }

  private var directLedger = DirectLedger()
  private var directRequests: [UInt64: PendingDirectRequest] = [:]
  private var nextDirectRequestID: UInt64 = 0
  /// Wire message ID → ledger attempt, so replies and carrier receipts find their request.
  private var directWireAttempts: [UInt64: DirectAttemptKey] = [:]
  private var directAttemptWire: [DirectAttemptKey: UInt64] = [:]
  private var directDeadlineTasks: [UInt64: Task<Void, Never>] = [:]
  private var directPrepareTasks: [DirectAttemptKey: Task<Void, Never>] = [:]
  private var directTransmitTasks: [DirectAttemptKey: Task<Void, Never>] = [:]
  private var directWakeTask: Task<Void, Never>?
  private static let maxPendingDirectRPCs = 64
  private static let capacityDiagnosticInterval: TimeInterval = 60
  private var directCapacityRejections = 0
  private var lastDirectCapacityDiagnosticAt = Date.distantPast

  // Message sequencing and ID generation
  private var seq: UInt32 = 0
  private let epoch = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00:00 UTC
  private var lastTimestamp: UInt32 = 0
  private var sequence: UInt32 = 0
  private var transportSessionID: UInt64?
  private var handshakeSessionID: UInt64?
  private var handshakeInvalidationReceipt: AuthInvalidationReceipt?
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
    directConnectionLost()
    handshakeSessionID = nil
    handshakeInvalidationReceipt = nil
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
        if case let .rpcResult(result) = message.body, case .transcribeVoiceDraft = result.result {
          log.trace("Received draft transcription result (content omitted)")
        } else {
          log.trace("Protocol session received transport message: \(message)")
        }
        await handleTransportMessage(message)

      case let .authInvalidated(receipt):
        await emitAccountEvent(.authInvalidated(receipt))

      case let .rpcCommitOutcomeUnknown(msgId):
        await emitAccountEvent(.rpcCommitOutcomeUnknown(msgId: msgId))
        directCarrierOutcomeUnknown(msgId: msgId)

      case let .rpcRejectedBeforeExecution(msgId):
        await emitAccountEvent(.rpcRejectedBeforeExecution(msgId: msgId))
        // The server proved the request never executed, so the ledger re-sends it after a
        // short hold instead of surfacing a transport error to the caller.
        directRejectedBeforeExecution(msgId: msgId)

      case .transportPreference:
        // Transport selection owns this; a direct child transport has no alternative to pick.
        break
      }
    }
  }

  private func emitLifecycleEvent(_ event: ProtocolSessionEvent) async {
    await events.send(.lifecycle(event))
  }

  private func emitAccountEvent(
    _ event: ProtocolSessionEvent,
    originatingSessionID: UInt64? = nil
  ) async {
    nextAccountEventID &+= 1
    let eventID = nextAccountEventID
    let envelope = ProtocolSessionEventEnvelope.account(
      event,
      originatingSessionID: originatingSessionID ?? transportSessionID
    )
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
      directAcknowledged(msgId: ack.msgID)
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
      guard let transportSessionID else {
        log.warning("Ignoring connection error without an active transport session")
        return
      }
      if error.reason == .sessionRevoked {
        guard let receipt = handshakeInvalidationReceipt else {
          log.warning("Ignoring unscoped session revocation without an authenticated handshake")
          return
        }
        await emitAccountEvent(.authInvalidated(receipt), originatingSessionID: transportSessionID)
        return
      }
      await emitAccountEvent(
        .connectionError(reason: error.reason),
        originatingSessionID: transportSessionID
      )

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

    // The receipt must name the exact bearer sent on this handshake, not whichever login is
    // current when a delayed server response reaches the account collector or platform UI.
    let receipt = try auth.makeInvalidationReceipt()
    guard auth.token() == token, auth.isCurrent(receipt) else {
      throw ProtocolSessionError.notAuthorized
    }
    handshakeInvalidationReceipt = receipt

    let msg = wrapMessage(body: .connectionInit(.with {
      $0.token = token ?? ""
      $0.buildNumber = getBuildNumber()
      $0.supportsWorking = AgentActivityFeature.isEnabled
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
      case .capacityExceeded:
        throw ProtocolSessionError.capacityExceeded
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
        await emitAccountEvent(.authFailed, originatingSessionID: sessionID)
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
    // Requests held across the gap dispatch on this session before anyone observes it open.
    applyDirectLedger(directLedger.handle(.connectionOpened(sessionID)))
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
      case .capacityExceeded:
        throw ProtocolSessionError.capacityExceeded
      }
    } catch {
      throw error
    }

    return message.id
  }

  /// Low-level RPC that waits for the server response or error.
  /// This is independent of the higher-level transactions system in `RealtimeV2`.
  ///
  /// The request outlives the connection it is dispatched on: it waits for an open session
  /// instead of failing while the transport is down, and a read-only request whose reply was
  /// lost with a connection is re-sent on the next one. `timeout` is the caller's deadline for
  /// the whole wait; `nil` waits until the session closes.
  @discardableResult
  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration? = .seconds(15)
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    try await callRpc(method: method, input: input, timeout: timeout, beforeDispatch: {})
  }

  func callRpc(
    method: InlineProtocol.Method,
    input: RpcCall.OneOf_Input?,
    timeout: Duration?,
    beforeDispatch: @escaping @Sendable () async throws -> Void
  ) async throws -> InlineProtocol.RpcResult.OneOf_Result? {
    try Task.checkCancellation()
    guard directLedger.pendingCount < Self.maxPendingDirectRPCs else {
      recordDirectCapacityRejection()
      throw ProtocolSessionError.capacityExceeded
    }
    nextDirectRequestID &+= 1
    let requestID = nextDirectRequestID
    let request = DirectLedger.Request(
      id: requestID,
      payload: DirectRequestPayload(method: method, input: input),
      readOnly: inlineProtocolRpcMethodIsReadOnly(method)
    )

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
        InlineProtocol.RpcResult.OneOf_Result?,
        any Error
      >) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        directRequests[requestID] = PendingDirectRequest(
          continuation: continuation,
          beforeDispatch: beforeDispatch
        )
        if let timeout {
          directDeadlineTasks[requestID] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.directDeadlineReached(requestID)
          }
        }
        if !directLedger.isConnected {
          log.debug("Holding direct RPC until a session opens method=\(method)")
        }
        applyDirectLedger(directLedger.handle(.submit(request)))
      }
    } onCancel: {
      Task { await self.cancelDirectRequest(requestID) }
    }
  }

  private func recordDirectCapacityRejection() {
    directCapacityRejections += 1
    let now = Date()
    guard now.timeIntervalSince(lastDirectCapacityDiagnosticAt) >= Self.capacityDiagnosticInterval else {
      return
    }
    PerformanceTrace.breadcrumb(
      "realtime_direct_rpc_capacity",
      category: "realtime.transaction",
      level: .warning,
      data: [
        "direct_capacity_rejections": directCapacityRejections,
        "outstanding": directLedger.pendingCount,
      ]
    )
    directCapacityRejections = 0
    lastDirectCapacityDiagnosticAt = now
  }

  /// Waits for every in-progress pre-send step and transport write owned by direct RPCs.
  func waitForDirectDispatches() async {
    while !directPrepareTasks.isEmpty || !directTransmitTasks.isEmpty {
      let tasks = Array(directPrepareTasks.values) + Array(directTransmitTasks.values)
      for task in tasks {
        await task.value
      }
    }
  }

  /// Resolves every pending direct request. Called when the owner ends this account's
  /// realtime generation; a transport reconnect must not call this.
  func closeDirectRequests() {
    directWakeTask?.cancel()
    directWakeTask = nil
    applyDirectLedger(directLedger.handle(.close))
  }

  // MARK: - Ledger I/O

  private func applyDirectLedger(_ commands: [DirectLedger.Command]) {
    for command in commands {
      switch command {
      case let .prepare(requestID, attempt, _):
        let key = DirectAttemptKey(request: requestID, attempt: attempt)
        directPrepareTasks[key] = Task { await self.prepareDirectAttempt(key) }

      case let .transmit(requestID, attempt, payload):
        let key = DirectAttemptKey(request: requestID, attempt: attempt)
        let message = wrapMessage(body: .rpcCall(.with {
          $0.method = payload.method
          $0.input = payload.input
        }))
        directWireAttempts[message.id] = key
        directAttemptWire[key] = message.id
        directTransmitTasks[key] = Task { await self.transmitDirectAttempt(key, message: message) }

      case let .resolve(requestID, outcome):
        finishDirectRequest(requestID, outcome: outcome)

      case let .wake(after):
        scheduleDirectWake(after: after)
      }
    }
  }

  private func prepareDirectAttempt(_ key: DirectAttemptKey) async {
    defer { directPrepareTasks.removeValue(forKey: key) }
    // A cancelled or expired caller removes its request before this task gets actor time.
    guard let pending = directRequests[key.request] else { return }
    do {
      try await pending.beforeDispatch()
    } catch {
      directRequests[key.request]?.localError = error
      applyDirectLedger(directLedger.handle(.failLocally(key.request)))
      return
    }
    applyDirectLedger(directLedger.handle(.prepared(key.request, key.attempt)))
  }

  private func transmitDirectAttempt(_ key: DirectAttemptKey, message: ClientMessage) async {
    defer { directTransmitTasks.removeValue(forKey: key) }
    do {
      try await transport.send(message)
      applyDirectLedger(directLedger.handle(.sendSucceeded(key.request, key.attempt)))
    } catch let error as TransportError {
      switch error {
      case .notConnected:
        applyDirectLedger(directLedger.handle(.sendFailed(key.request, key.attempt, .notConnected)))
      case .capacityExceeded:
        applyDirectLedger(directLedger.handle(.sendFailed(key.request, key.attempt, .capacityExceeded)))
      }
    } catch {
      log.warning("Direct RPC transport write failed after admission; treating as uncertain: \(error)")
      applyDirectLedger(directLedger.handle(.sendFailed(key.request, key.attempt, .uncertain)))
    }
  }

  private func finishDirectRequest(_ requestID: UInt64, outcome: DirectLedger.Outcome) {
    directDeadlineTasks.removeValue(forKey: requestID)?.cancel()
    let attempts = directAttemptWire.keys.filter { $0.request == requestID }
    for key in attempts {
      if let messageID = directAttemptWire.removeValue(forKey: key) {
        directWireAttempts.removeValue(forKey: messageID)
      }
    }
    guard let pending = directRequests.removeValue(forKey: requestID) else { return }
    switch outcome {
    case let .reply(.result(result)):
      pending.continuation.resume(returning: result)
    case let .reply(.error(rpcError)):
      pending.continuation.resume(throwing: ProtocolSessionError.rpcError(
        errorCode: rpcError.errorCode,
        message: rpcError.message,
        code: Int(rpcError.code)
      ))
    case .notConnected:
      // The caller spent its whole deadline without an open session. This is the honest
      // "offline" outcome; a teardown with a reconnect in between never reaches callers.
      PerformanceTrace.breadcrumb(
        "realtime direct rpc expired while disconnected",
        category: "realtime.rpc",
        level: .warning,
        data: ["held": directLedger.pendingCount]
      )
      pending.continuation.resume(throwing: ProtocolSessionError.notConnected)
    case .timeout:
      pending.continuation.resume(throwing: ProtocolSessionError.timeout)
    case .commitOutcomeUnknown:
      pending.continuation.resume(throwing: ProtocolSessionError.commitOutcomeUnknown)
    case .cancelled:
      pending.continuation.resume(throwing: CancellationError())
    case .stopped:
      pending.continuation.resume(throwing: ProtocolSessionError.stopped)
    case .failedLocally:
      pending.continuation.resume(throwing: pending.localError ?? ProtocolSessionError.notAuthorized)
    }
  }

  private func scheduleDirectWake(after delay: Duration) {
    guard directWakeTask == nil else { return }
    directWakeTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.directWakeFired()
    }
  }

  private func directWakeFired() {
    directWakeTask = nil
    applyDirectLedger(directLedger.handle(.wake))
  }

  private func directDeadlineReached(_ requestID: UInt64) {
    directDeadlineTasks.removeValue(forKey: requestID)
    applyDirectLedger(directLedger.handle(.deadlineReached(requestID)))
  }

  private func cancelDirectRequest(_ requestID: UInt64) {
    applyDirectLedger(directLedger.handle(.cancel(requestID)))
  }

  /// The transport went away. Reads dispatched on it are re-sent on the next session; writes
  /// that may have reached the wire resolve as uncertain; queued requests keep waiting.
  private func directConnectionLost() {
    let before = directLedger.stats
    applyDirectLedger(directLedger.handle(.connectionLost))
    let after = directLedger.stats
    let resent = after.readsResentAfterConnectionLoss - before.readsResentAfterConnectionLoss
    let uncertain = after.writesUncertainAfterConnectionLoss - before.writesUncertainAfterConnectionLoss
    guard resent > 0 || uncertain > 0 || directLedger.pendingCount > 0 else { return }
    PerformanceTrace.breadcrumb(
      "realtime direct rpc connection lost",
      category: "realtime.rpc",
      level: .info,
      data: [
        "resent_reads": resent,
        "uncertain_writes": uncertain,
        "held": directLedger.pendingCount,
      ]
    )
  }

  // MARK: - Inbound

  private func completeRpcResult(msgId: UInt64, rpcResult: InlineProtocol.RpcResult.OneOf_Result?) {
    guard let key = directWireAttempts[msgId] else { return }
    applyDirectLedger(directLedger.handle(.replied(key.request, key.attempt, .result(rpcResult))))
  }

  private func completeRpcError(msgId: UInt64, rpcError: InlineProtocol.RpcError) {
    guard let key = directWireAttempts[msgId] else { return }
    applyDirectLedger(directLedger.handle(.replied(key.request, key.attempt, .error(rpcError))))
  }

  private func directAcknowledged(msgId: UInt64) {
    guard let key = directWireAttempts[msgId] else { return }
    applyDirectLedger(directLedger.handle(.acknowledged(key.request, key.attempt)))
  }

  private func directCarrierOutcomeUnknown(msgId: UInt64) {
    guard let key = directWireAttempts[msgId] else { return }
    applyDirectLedger(directLedger.handle(.commitOutcomeUnknown(key.request, key.attempt)))
  }

  private func directRejectedBeforeExecution(msgId: UInt64) {
    guard let key = directWireAttempts[msgId] else { return }
    applyDirectLedger(directLedger.handle(.rejectedBeforeExecution(key.request, key.attempt)))
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
       .searchExternalResources, .listConnectors, .searchUsers, .getUsers,
       .resolveURLPreview, .getBotAgent, .listBotAgents, .getConnectorConfig, .getSpace,
       .getUploadState, .getFilePart:
    true
  default:
    false
  }
}
