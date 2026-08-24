import AsyncAlgorithms
import Auth
import Foundation
import InlineConfig
import InlineProtocol
import Logger

struct InlineProtocolV3RPCMultiplexer: Sendable {
  typealias Completion = @Sendable (Result<RealtimeV3Response, any Error>) async -> Void
  typealias BeginInvoke = @Sendable (
    RealtimeV3Request,
    @escaping @Sendable () async -> Void,
    @escaping Completion
  ) async throws -> Void
  typealias Deliver = @Sendable (
    UInt64,
    InlineProtocol.Method,
    Result<RealtimeV3Response, any Error>
  ) async -> Void

  let beginInvoke: BeginInvoke
  let acknowledge: @Sendable (UInt64, InlineProtocol.Method) async -> Void
  let deliver: Deliver

  /// Writes one request and returns independently of its eventual response.
  func dispatch(messageID: UInt64, call: RpcCall) async throws {
    var envelope = RealtimeV3Request()
    envelope.body = .rpc(call)
    try await beginInvoke(
      envelope,
      { await acknowledge(messageID, call.method) },
      { result in await deliver(messageID, call.method, result) }
    )
  }
}

struct InlineProtocolV3ProbeDispatcher: Sendable {
  typealias BeginProbe = @Sendable (Int64) async throws -> Void
  typealias Deliver = @Sendable (UInt64, Result<Void, any Error>) async -> Void

  let beginProbe: BeginProbe
  let deliver: Deliver

  /// Starts the authenticated probe without making the legacy heartbeat caller wait for its pong.
  func dispatch(nonce: UInt64) -> Task<Void, Never> {
    Task {
      do {
        try await beginProbe(Int64(bitPattern: nonce))
        await deliver(nonce, .success(()))
      } catch {
        await deliver(nonce, .failure(error))
      }
    }
  }
}

public actor InlineProtocolV3Transport: Transport {
  private let log = Log.scoped("RealtimeV3.Transport")
  private let auth: AuthHandle
  private let url: URL
  private let rsaPublicKeys: [InlineProtocolRSAPublicKey]
  private let localDebugTrustHost: String?
  private let channel = AsyncChannel<TransportEvent>()
  private var connection: InlineProtocolV3Connection?
  private var updatesTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var activePingNonce: UInt64?
  private var startTask: Task<Void, Never>?
  private var rotationTask: Task<Void, Never>?
  private var startGeneration: UInt64 = 0
  private var starting = false

  public nonisolated var events: AsyncChannel<TransportEvent> { channel }

  public init(
    auth: AuthHandle,
    url: URL? = nil,
    rsaPublicKeys: [InlineProtocolRSAPublicKey] = []
  ) {
    self.auth = auth
    self.url = url ?? URL(string: InlineConfig.realtimeServerURL.replacingOccurrences(
      of: "/realtime", with: "/realtime/v3"
    ))!
    self.rsaPublicKeys = rsaPublicKeys
    #if DEBUG
    localDebugTrustHost = ProjectConfig.useProductionApi ? nil : ProjectConfig.devHost
    #else
    localDebugTrustHost = nil
    #endif
  }

  public func start() async {
    guard connection == nil, !starting else { return }
    starting = true
    startGeneration = startGeneration &+ 1
    let generation = startGeneration
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performStart(generation: generation)
    }
    startTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func performStart(generation: UInt64) async {
    log.debug("Inline Protocol transport start requested")
    await channel.send(.connecting)
    var candidate: InlineProtocolV3Connection?
    do {
      try requireCurrentStart(generation)
      guard var credentials = auth.inlineProtocolCredentials() else {
        throw InlineProtocolV3ConnectionError.invalidKey
      }
      if let temporary = credentials.temporary, temporary.expiresAt != nil {
        log.debug("Reconnecting with stored temporary authorization")
        let cached = try await InlineProtocolV3Connection.connect(.reconnect(
          url: url, authorization: temporary
        ))
        candidate = cached
        try requireCurrentStart(generation)
        do {
          try await cached.verifyAuthorization()
          try requireCurrentStart(generation)
          if await cached.temporaryAuthorizationNeedsRotation() {
            log.debug("Stored temporary authorization reached its rotation boundary")
            await cached.close()
            candidate = nil
            try requireCurrentStart(generation)
          } else {
            log.debug("Stored temporary authorization verified")
          }
        } catch {
          let terminalError = await cached.terminationError
          await cached.close()
          candidate = nil
          try requireCurrentStart(generation)
          guard Self.authenticationInvalidationReason(for: error) != nil ||
            terminalError == .authorizationInvalidated
          else {
            log.debug("Stored temporary authorization verification failed transiently; keeping key")
            throw error
          }
          log.warning("Stored temporary authorization was not accepted; regenerating once")
          let replacement = try await makeVerifiedTemporary(permanent: credentials.permanent)
          candidate = replacement
          try requireCurrentStart(generation)
          credentials.temporary = await replacement.authorization
          do {
            try await auth.saveInlineProtocolCredentials(credentials)
          } catch {
            throw error
          }
          try requireCurrentStart(generation)
          log.debug("Replacement temporary authorization verified and stored")
        }
      }
      if candidate == nil, (!rsaPublicKeys.isEmpty || InlineProtocolTrustRoots.supportsLocalDebugDiscovery(
        for: url,
        allowedDevelopmentHost: localDebugTrustHost
      )) {
        log.debug("Creating replacement temporary authorization")
        let replacement = try await makeVerifiedTemporary(permanent: credentials.permanent)
        candidate = replacement
        try requireCurrentStart(generation)
        credentials.temporary = await replacement.authorization
        do {
          try await auth.saveInlineProtocolCredentials(credentials)
        } catch {
          throw error
        }
        try requireCurrentStart(generation)
        log.debug("Replacement temporary authorization verified and stored")
      } else if candidate == nil {
        // Application traffic must never fall back to the permanent authorization key. A client
        // without a usable temporary key must have pinned roots available to create and bind one.
        throw InlineProtocolV3ConnectionError.invalidKey
      }
      try requireCurrentStart(generation)
      guard let candidate else { throw InlineProtocolV3ConnectionError.invalidKey }
      connection = candidate
      startUpdates(candidate)
      startRotationMonitor(candidate)
      log.debug("Inline Protocol transport connected")
      await channel.send(.connected)
      try requireCurrentStart(generation)
      candidateStartDidFinish(generation: generation)
    } catch {
      if let candidate { await candidate.close() }
      guard generation == startGeneration else { return }
      candidateStartDidFinish(generation: generation)
      if error is CancellationError || Task.isCancelled { return }
      logStartFailure(error)
      connection = nil
      if Self.authenticationInvalidationReason(for: error) != nil {
        await emitAuthenticationInvalidated(error)
        return
      }
      await channel.send(.disconnected(errorDescription: String(describing: error)))
    }
  }

  public func stop() async {
    log.debug("Inline Protocol transport stop requested")
    startGeneration = startGeneration &+ 1
    starting = false
    let stoppingStartTask = startTask
    stoppingStartTask?.cancel()
    await stoppingStartTask?.value
    startTask = nil
    updatesTask?.cancel()
    updatesTask = nil
    pingTask?.cancel()
    pingTask = nil
    activePingNonce = nil
    rotationTask?.cancel()
    rotationTask = nil
    if let connection { await connection.close() }
    connection = nil
    await channel.send(.disconnected(errorDescription: "stopped"))
    log.debug("Inline Protocol transport stopped")
  }

  private func requireCurrentStart(_ generation: UInt64) throws {
    guard generation == startGeneration, starting, !Task.isCancelled else {
      throw CancellationError()
    }
  }

  private func candidateStartDidFinish(generation: UInt64) {
    guard generation == startGeneration else { return }
    starting = false
    startTask = nil
  }

  public func send(_ message: ClientMessage) async throws {
    guard let connection else { throw TransportError.notConnected }
    switch message.body {
    case .connectionInit:
      log.debug("Ignoring redundant connection init on authenticated V3 transport")
      return
    case let .rpcCall(call):
      let startedAt = ProcessInfo.processInfo.systemUptime
      log.debug("RPC dispatch started rpc_id=\(message.id) method=\(call.method)")
      do {
        let multiplexer = InlineProtocolV3RPCMultiplexer(
          beginInvoke: { request, acknowledged, completion in
            try await connection.beginInvoke(
              request,
              acknowledged: acknowledged,
              completion: completion
            )
          },
          acknowledge: { [weak self] requestMessageID, method in
            await self?.acknowledgeRPC(
              source: connection,
              requestMessageID: requestMessageID,
              method: method
            )
          },
          deliver: { [weak self] requestMessageID, method, result in
            await self?.completeRPC(
              result,
              source: connection,
              requestMessageID: requestMessageID,
              method: method,
              startedAt: startedAt
            )
          }
        )
        try await multiplexer.dispatch(messageID: message.id, call: call)
        let writeDurationMilliseconds = Int(
          (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        log.debug(
          "RPC written rpc_id=\(message.id) method=\(call.method) duration_ms=\(writeDurationMilliseconds)"
        )
      } catch let error as InlineProtocolV3ConnectionError
        where error == .temporaryAuthorizationRotationDue {
        // The admission gate is authoritative even if a fresh authenticated record moved the
        // clock ahead of the monitor's sleep deadline. Close this carrier and let the existing
        // connection manager perform the normal temporary-key replacement/reconnect sequence.
        await connection.close()
        throw TransportError.notConnected
      } catch let error as InlineProtocolV3ConnectionError
        where error == .requestCapacityExceeded {
        // This is a local admission failure: no record was accepted and the
        // application owner may safely hold the request for later dispatch.
        throw TransportError.capacityExceeded
      } catch {
        let writeDurationMilliseconds = Int(
          (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        )
        log.debug(
          "RPC write failed rpc_id=\(message.id) method=\(call.method) " +
            "duration_ms=\(writeDurationMilliseconds) error=\(String(describing: error))"
        )
        throw error
      }
    case let .ping(ping):
      let generation = startGeneration
      let startedAt = ProcessInfo.processInfo.systemUptime
      log.debug("Authorization probe dispatched generation=\(generation)")
      pingTask?.cancel()
      activePingNonce = ping.nonce
      let dispatcher = InlineProtocolV3ProbeDispatcher(
        beginProbe: { pingID in
          // The connection manager owns the heartbeat deadline. This lower layer only owns
          // authenticated framing, correlation, and terminal socket failure.
          try await connection.verifyAuthorization(pingID: pingID, timeout: nil)
        },
        deliver: { [weak self] nonce, result in
          await self?.completeProbe(
            result,
            source: connection,
            generation: generation,
            nonce: nonce,
            startedAt: startedAt
          )
        }
      )
      pingTask = dispatcher.dispatch(nonce: ping.nonce)
    case .ack:
      return
    case nil:
      return
    }
  }

  public func isApplicationAuthenticatedOnConnect() async -> Bool { true }

  private func completeProbe(
    _ result: Result<Void, any Error>,
    source: InlineProtocolV3Connection,
    generation: UInt64,
    nonce: UInt64,
    startedAt: TimeInterval
  ) async {
    guard connection === source,
          generation == startGeneration,
          activePingNonce == nonce
    else { return }
    pingTask = nil
    activePingNonce = nil
    let durationMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    )
    switch result {
    case .success:
      var pong = Pong()
      pong.nonce = nonce
      var server = ServerProtocolMessage()
      server.body = .pong(pong)
      await channel.send(.message(server))
      log.debug(
        "Authorization probe completed generation=\(generation) duration_ms=\(durationMilliseconds)"
      )
    case let .failure(error):
      guard !(error is CancellationError) else { return }
      log.debug(
        "Authorization probe failed generation=\(generation) duration_ms=\(durationMilliseconds) " +
          "error=\(String(describing: error))"
      )
    }
  }

  private func completeRPC(
    _ completion: Result<RealtimeV3Response, any Error>,
    source: InlineProtocolV3Connection,
    requestMessageID: UInt64,
    method: InlineProtocol.Method,
    startedAt: TimeInterval
  ) async {
    guard connection === source else { return }
    let durationMilliseconds = Int(
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    )

    switch completion {
    case let .success(response):
      var server = ServerProtocolMessage()
      switch response.body {
      case let .rpcResult(result):
        var wrapped = RpcResult()
        wrapped.reqMsgID = requestMessageID
        wrapped.result = result.result
        server.body = .rpcResult(wrapped)
      case var .rpcError(error):
        error.reqMsgID = requestMessageID
        server.body = .rpcError(error)
      default:
        log.error(
          "RPC response invalid rpc_id=\(requestMessageID) method=\(method) duration_ms=\(durationMilliseconds)",
          error: InlineProtocolV3ConnectionError.unexpectedResponse
        )
        await source.close()
        return
      }
      await channel.send(.message(server))
      log.debug(
        "RPC completed rpc_id=\(requestMessageID) method=\(method) duration_ms=\(durationMilliseconds)"
      )
    case let .failure(error):
      if error as? InlineProtocolV3ConnectionError == .rejectedBeforeExecution {
        await channel.send(.rpcRejectedBeforeExecution(msgId: requestMessageID))
        log.warning(
          "RPC rejected before execution rpc_id=\(requestMessageID) method=\(method) duration_ms=\(durationMilliseconds)"
        )
        return
      }
      if error as? InlineProtocolV3ConnectionError == .commitOutcomeUnknown {
        await channel.send(.rpcCommitOutcomeUnknown(msgId: requestMessageID))
        log.warning(
          "RPC commit outcome is unknown rpc_id=\(requestMessageID) method=\(method) duration_ms=\(durationMilliseconds)"
        )
        return
      }
      // Connection termination owns the corresponding disconnected event and transaction replay.
      if await source.terminationError == nil {
        log.error(
          "RPC response failed rpc_id=\(requestMessageID) method=\(method) duration_ms=\(durationMilliseconds)",
          error: error
        )
      } else {
        log.debug(
          "RPC failed rpc_id=\(requestMessageID) method=\(method) duration_ms=\(durationMilliseconds) " +
            "error=\(String(describing: error))"
        )
      }
      await source.close()
    }
  }

  private func acknowledgeRPC(
    source: InlineProtocolV3Connection,
    requestMessageID: UInt64,
    method: InlineProtocol.Method
  ) async {
    guard connection === source else { return }
    var acknowledgement = Ack()
    acknowledgement.msgID = requestMessageID
    var server = ServerProtocolMessage()
    server.body = .ack(acknowledgement)
    await channel.send(.message(server))
    log.debug("RPC acknowledged rpc_id=\(requestMessageID) method=\(method)")
  }

  private func makeVerifiedTemporary(
    permanent: InlineProtocolAuthorization
  ) async throws -> InlineProtocolV3Connection {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let resolvedRsaPublicKeys = try await InlineProtocolTrustRoots.resolve(
      for: url,
      pinnedKeys: rsaPublicKeys,
      allowedDevelopmentHost: localDebugTrustHost
    )
    let rootsResolvedAt = ProcessInfo.processInfo.systemUptime
    let fingerprints = resolvedRsaPublicKeys.map { String($0.fingerprint) }.joined(separator: ",")
    log.debug(
      "Creating temporary authorization scheme=\(url.scheme ?? "unknown") " +
        "host=\(url.host ?? "unknown") key_count=\(resolvedRsaPublicKeys.count) " +
        "fingerprints=\(fingerprints) " +
        "roots_ms=\(Int((rootsResolvedAt - startedAt) * 1_000))"
    )
    let temporary: InlineProtocolV3Connection
    do {
      temporary = try await InlineProtocolV3Connection.connect(.init(
        url: url,
        rsaPublicKeys: resolvedRsaPublicKeys,
        temporary: true
      ))
    } catch {
      log.debug(
        "Temporary authorization handshake failed " +
          "duration_ms=\(Int((ProcessInfo.processInfo.systemUptime - rootsResolvedAt) * 1_000)) " +
          "error=\(String(describing: error))"
      )
      throw error
    }
    let handshakeCompletedAt = ProcessInfo.processInfo.systemUptime
    log.debug(
      "Temporary authorization handshake completed " +
        "duration_ms=\(Int((handshakeCompletedAt - rootsResolvedAt) * 1_000))"
    )
    do {
      try await temporary.bindTemporary(to: permanent)
      let bindingCompletedAt = ProcessInfo.processInfo.systemUptime
      log.debug(
        "Temporary authorization binding completed " +
          "duration_ms=\(Int((bindingCompletedAt - handshakeCompletedAt) * 1_000))"
      )
      try await temporary.verifyAuthorization()
      let verificationCompletedAt = ProcessInfo.processInfo.systemUptime
      log.debug(
        "Temporary authorization verification completed " +
          "duration_ms=\(Int((verificationCompletedAt - bindingCompletedAt) * 1_000)) " +
          "total_ms=\(Int((verificationCompletedAt - startedAt) * 1_000))"
      )
      return temporary
    } catch {
      await temporary.close()
      throw error
    }
  }

  private func startUpdates(_ connection: InlineProtocolV3Connection) {
    updatesTask?.cancel()
    updatesTask = Task { [weak self, channel] in
      for await update in connection.updates {
        guard !Task.isCancelled else { return }
        var server = ServerProtocolMessage()
        server.body = .message(update.message)
        await channel.send(.message(server))
      }
      await self?.connectionEnded(connection)
    }
  }

  private func startRotationMonitor(_ connection: InlineProtocolV3Connection) {
    rotationTask?.cancel()
    rotationTask = Task { [weak self, connection] in
      while !Task.isCancelled {
        guard let delay = await connection.temporaryAuthorizationRotationDelay() else { return }
        do {
          try await Task.sleep(for: delay)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        guard await connection.temporaryAuthorizationNeedsRotation() else { continue }

        await self?.rotationBoundaryReached(connection)
        return
      }
    }
  }

  private func rotationBoundaryReached(_ source: InlineProtocolV3Connection) async {
    guard connection === source else { return }
    log.debug("Temporary authorization rotation boundary reached; draining admitted RPCs")
    // Admission is closed by the connection's authoritative beginPrepared check. This bounded
    // drain only covers low-level RPCs; it deliberately does not claim to lease a multipart
    // upload across the reconnect.
    await source.waitForPendingRequestsToSettle()
    guard connection === source else { return }
    await source.close()
  }

  private func connectionEnded(_ endedConnection: InlineProtocolV3Connection) async {
    guard connection === endedConnection else { return }
    rotationTask?.cancel()
    rotationTask = nil
    pingTask?.cancel()
    pingTask = nil
    activePingNonce = nil
    log.debug("Inline Protocol transport receive loop ended")
    connection = nil
    if let terminationError = await endedConnection.terminationError,
       Self.authenticationInvalidationReason(for: terminationError) != nil {
      await emitAuthenticationInvalidated(terminationError)
      return
    }
    await channel.send(.disconnected(errorDescription: "connection_closed"))
  }

  static func authenticationInvalidationReason(
    for error: any Error
  ) -> InlineProtocol.ConnectionError.Reason? {
    guard error as? InlineProtocolV3ConnectionError == .authorizationInvalidated else {
      return nil
    }
    return .sessionRevoked
  }

  private func emitAuthenticationInvalidated(_ error: any Error) async {
    guard let reason = Self.authenticationInvalidationReason(for: error) else { return }
    log.warning("Inline Protocol authorization invalidated reason=\(reason)")
    var connectionError = InlineProtocol.ConnectionError()
    connectionError.reason = reason
    var server = ServerProtocolMessage()
    server.body = .connectionError(connectionError)
    await channel.send(.message(server))
    await channel.send(.disconnected(errorDescription: "session_revoked"))
  }

  private func logStartFailure(_ error: any Error) {
    switch Self.startFailureLogLevel(for: error) {
    case .error:
      log.error("Inline Protocol connection failed", error: error)
    case .warning:
      log.warning("Inline Protocol connection failed reason=\(String(describing: error))")
    case .debug, .info, .trace:
      log.debug("Inline Protocol connection failed error=\(String(describing: error))")
    }
  }

  static func startFailureLogLevel(for error: any Error) -> LogLevel {
    if error is CancellationError { return .debug }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .cancelled,
        .timedOut,
        .notConnectedToInternet,
        .secureConnectionFailed,
        .networkConnectionLost:
        return .debug
      default:
        return .error
      }
    }
    guard let connectionError = error as? InlineProtocolV3ConnectionError else { return .error }
    switch connectionError {
    case .authorizationInvalidated,
      .closed,
      .commitOutcomeUnknown,
      .rejectedBeforeExecution,
      .requestCapacityExceeded,
      .rpc,
      .temporaryAuthorizationRotationDue:
      return .debug
    case .outboundBufferOverflow,
      .timeout,
      .updateBufferOverflow:
      return .warning
    case .invalidKey,
      .protocolFailure,
      .unexpectedResponse:
      return .error
    }
  }
}

public actor NegotiatingRealtimeTransport: Transport {
  typealias TransportFactory = @Sendable () -> any Transport

  private let log = Log.scoped("Realtime.TransportSelection")
  private let hasInlineProtocolCredentials: @Sendable () -> Bool
  private let makeLegacyTransport: TransportFactory
  private let makeInlineProtocolTransport: TransportFactory
  private let channel = AsyncChannel<TransportEvent>()
  private var active: (any Transport)?
  private var eventTask: Task<Void, Never>?

  public nonisolated var events: AsyncChannel<TransportEvent> { channel }

  public init(auth: AuthHandle, rsaPublicKeys: [InlineProtocolRSAPublicKey] = []) {
    hasInlineProtocolCredentials = { auth.inlineProtocolCredentials() != nil }
    makeLegacyTransport = { WebSocketTransport() }
    makeInlineProtocolTransport = {
      InlineProtocolV3Transport(auth: auth, rsaPublicKeys: rsaPublicKeys)
    }
  }

  init(
    hasInlineProtocolCredentials: @escaping @Sendable () -> Bool,
    makeLegacyTransport: @escaping TransportFactory,
    makeInlineProtocolTransport: @escaping TransportFactory
  ) {
    self.hasInlineProtocolCredentials = hasInlineProtocolCredentials
    self.makeLegacyTransport = makeLegacyTransport
    self.makeInlineProtocolTransport = makeInlineProtocolTransport
  }

  public func start() async {
    if let active {
      // A negotiated child remains the session owner after a transient disconnect. Both child
      // transports are restartable, so drive that owner again instead of treating its presence as
      // proof that it is still connected.
      await active.start()
      return
    }

    let transport: any Transport
    if hasInlineProtocolCredentials() {
      log.debug("Selected Inline Protocol transport")
      transport = makeInlineProtocolTransport()
    } else {
      log.debug("Selected legacy Realtime V2 transport")
      transport = makeLegacyTransport()
    }
    active = transport
    forward(transport.events)
    await transport.start()
  }

  public func stop() async {
    guard let active else { return }
    // A child stop publishes its final disconnected event. Keep the forwarder alive until stop
    // returns so AsyncChannel delivery cannot deadlock on a receiver we cancelled prematurely.
    await active.stop()
    eventTask?.cancel()
    eventTask = nil
    self.active = nil
  }

  public func send(_ message: ClientMessage) async throws {
    guard let active else { throw TransportError.notConnected }
    try await active.send(message)
  }

  public func isApplicationAuthenticatedOnConnect() async -> Bool {
    guard let active else { return false }
    return await active.isApplicationAuthenticatedOnConnect()
  }

  private func forward(_ events: AsyncChannel<TransportEvent>) {
    eventTask?.cancel()
    eventTask = Task { [channel] in
      for await event in events {
        guard !Task.isCancelled else { return }
        await channel.send(event)
      }
    }
  }
}
