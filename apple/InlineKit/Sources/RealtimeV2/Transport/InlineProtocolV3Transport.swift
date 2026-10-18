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
  private var connectionAuthority: AuthInvalidationReceipt?
  private var updatesTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var activePingNonce: UInt64?
  private var startTask: Task<Void, Never>?
  private var rotationTask: Task<Void, Never>?
  private var preferenceTask: Task<Void, Never>?
  private var startGeneration: UInt64 = 0
  private var starting = false
  private var startAuthority: AuthAccountMutationToken?
  private var startCredentials: InlineProtocolSessionCredentials?
  private var startBearerToken: String?
  private var startInvalidationReceipt: AuthInvalidationReceipt?

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
    guard connection == nil, !starting, auth.hasPendingAccountTransition() == false else { return }
    let snapshot = auth.snapshot()
    guard let credentials = snapshot.inlineProtocol else { return }
    guard let authority = try? auth.beginAccountMutation() else { return }
    guard let invalidationReceipt = try? auth.makeInvalidationReceipt() else { return }
    starting = true
    startAuthority = authority
    startCredentials = credentials
    startBearerToken = snapshot.token
    startInvalidationReceipt = invalidationReceipt
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
    guard let authority = startAuthority, let startingCredentials = startCredentials,
          let invalidationReceipt = startInvalidationReceipt
    else { return }
    let bearerToken = startBearerToken
    log.debug("Inline Protocol transport start requested")
    await channel.send(.connecting)
    var candidate: InlineProtocolV3Connection?
    do {
      try requireCurrentStart(generation)
      var credentials = startingCredentials
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
          if terminalError == .sessionRevoked {
            throw InlineProtocolV3ConnectionError.sessionRevoked
          }
          if Self.authenticationInvalidationReason(for: error) != nil { throw error }
          guard error as? InlineProtocolV3ConnectionError == .authorizationInvalidated ||
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
          try await auth.saveInlineProtocolCredentials(credentials, authority: authority)
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
        try await auth.saveInlineProtocolCredentials(credentials, authority: authority)
        try requireCurrentStart(generation)
        log.debug("Replacement temporary authorization verified and stored")
      } else if candidate == nil {
        // Application traffic must never fall back to the permanent authorization key. A client
        // without a usable temporary key must have pinned roots available to create and bind one.
        throw InlineProtocolV3ConnectionError.invalidKey
      }
      try requireCurrentStart(generation)
      guard let candidate else { throw InlineProtocolV3ConnectionError.invalidKey }
      var capabilities: RealtimeV3Response?
      if AgentActivityFeature.isEnabled {
        // V3 authenticates before the legacy handshake. Advertise per-socket
        // presentation support here, including on reconnect with a cached key.
        let response = try await candidate.invoke(.with {
          $0.body = .connectionInit(.with { $0.supportsWorking = true })
        })
        if case .rpcError = response.body {
          // Older servers do not handle this optional application message yet.
          // Authentication was independently verified above; keep the connection.
          log.debug("Server did not accept optional presentation capabilities")
        }
        capabilities = response
      }
      try requireCurrentStart(generation)
      connectionAuthority = invalidationReceipt
      connection = candidate
      startUpdates(candidate)
      startRotationMonitor(candidate)
      log.debug("Inline Protocol transport connected")
      await channel.send(.connected)
      try requireCurrentStart(generation)
      candidateStartDidFinish(generation: generation)
      requestTransportPreference(from: candidate, initResponse: capabilities)
    } catch {
      if let candidate { await candidate.close() }
      guard generation == startGeneration else { return }
      candidateStartDidFinish(generation: generation)
      connection = nil
      connectionAuthority = nil
      if error is CancellationError || Task.isCancelled { return }
      // A retired account's late startup failure must not invalidate the replacement account.
      guard (try? auth.validateAccountMutation(authority)) != nil,
            !auth.hasPendingAccountTransition(),
            Self.matchesAccount(auth.snapshot(), credentials: startingCredentials, bearerToken: bearerToken)
      else { return }
      logStartFailure(error)
      if Self.authenticationInvalidationReason(for: error) != nil {
        await emitAuthenticationInvalidated(error, generation: generation, authority: invalidationReceipt)
        return
      }
      await channel.send(.disconnected(errorDescription: String(describing: error)))
    }
  }

  public func stop() async {
    log.debug("Inline Protocol transport stop requested")
    startGeneration = startGeneration &+ 1
    starting = false
    startAuthority = nil
    startCredentials = nil
    startBearerToken = nil
    startInvalidationReceipt = nil
    connectionAuthority = nil
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
    preferenceTask?.cancel()
    preferenceTask = nil
    if let connection { await connection.close() }
    connection = nil
    await channel.send(.disconnected(errorDescription: "stopped"))
    log.debug("Inline Protocol transport stopped")
  }

  private func requireCurrentStart(_ generation: UInt64) throws {
    guard generation == startGeneration, starting, !Task.isCancelled,
          auth.hasPendingAccountTransition() == false
    else {
      throw CancellationError()
    }
    guard let startAuthority else { throw CancellationError() }
    try auth.validateAccountMutation(startAuthority)
    guard let startCredentials,
          Self.matchesAccount(auth.snapshot(), credentials: startCredentials, bearerToken: startBearerToken),
          let startInvalidationReceipt, auth.isCurrent(startInvalidationReceipt)
    else { throw CancellationError() }
  }

  private func candidateStartDidFinish(generation: UInt64) {
    guard generation == startGeneration else { return }
    starting = false
    startAuthority = nil
    startCredentials = nil
    startBearerToken = nil
    startInvalidationReceipt = nil
    startTask = nil
  }

  static func matchesAccount(
    _ snapshot: AuthSnapshot,
    credentials: InlineProtocolSessionCredentials,
    bearerToken: String?
  ) -> Bool {
    // Ordinary same-user bearer replacement intentionally need not retire every account
    // mutation lease. Transport authority is stricter: a late failure belongs to this exact
    // session and source token, while temporary-key/salt refresh is still the same account.
    guard snapshot.token == bearerToken, let current = snapshot.inlineProtocol else { return false }
    return current.userId == credentials.userId && current.accountSessionId == credentials.accountSessionId &&
      current.permanent.keyID == credentials.permanent.keyID && current.permanent.key == credentials.permanent.key
  }

  public func send(_ message: ClientMessage) async throws {
    guard let connection, let connectionAuthority, auth.isCurrent(connectionAuthority) else {
      throw TransportError.notConnected
    }
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
    updatesTask = Task { [weak self] in
      for await update in connection.updates {
        guard !Task.isCancelled else { return }
        await self?.forwardUpdate(update, source: connection)
      }
      await self?.connectionEnded(connection)
    }
  }

  private func forwardUpdate(_ update: RealtimeV3Update, source: InlineProtocolV3Connection) async {
    guard connection === source, let connectionAuthority, auth.isCurrent(connectionAuthority) else { return }
    var server = ServerProtocolMessage()
    server.body = .message(update.message)
    await channel.send(.message(server))
  }

  /// Every V3 open reports the operator's transport choice for upgraded bearer sessions. Unless
  /// presentation support already required init before connecting, ask once connected so the
  /// preference never delays startup.
  private func requestTransportPreference(
    from source: InlineProtocolV3Connection,
    initResponse: RealtimeV3Response?
  ) {
    preferenceTask?.cancel()
    preferenceTask = Task { [weak self] in
      let response: RealtimeV3Response
      if let initResponse {
        response = initResponse
      } else {
        do {
          response = try await source.invoke(.with { $0.body = .connectionInit(.init()) })
        } catch {
          // Optional: the stored preference stays in effect until a later open reports one.
          return
        }
      }
      await self?.reportTransportPreference(response, source: source)
    }
  }

  private func reportTransportPreference(_ response: RealtimeV3Response, source: InlineProtocolV3Connection) async {
    guard !Task.isCancelled, connection === source, let connectionAuthority, auth.isCurrent(connectionAuthority),
          case let .connectionOpen(open) = response.body
    else { return }
    await channel.send(.transportPreference(
      prefersLegacy: UpgradedSessionTransportPreference.prefersLegacy(open)
    ))
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
    guard connection === endedConnection, let authority = connectionAuthority else { return }
    let generation = startGeneration
    rotationTask?.cancel()
    rotationTask = nil
    preferenceTask?.cancel()
    preferenceTask = nil
    pingTask?.cancel()
    pingTask = nil
    activePingNonce = nil
    log.debug("Inline Protocol transport receive loop ended")
    connection = nil
    connectionAuthority = nil
    await handleConnectionClosure(generation: generation, authority: authority) {
      await endedConnection.terminationError
    }
  }

  // Keep the asynchronous termination read inside this callback so account replacement and
  // stop/restart must be revalidated after it completes, not just when the receive loop ends.
  func handleConnectionClosure(
    generation: UInt64,
    authority: AuthInvalidationReceipt,
    terminationError: @Sendable () async -> InlineProtocolV3ConnectionError?
  ) async {
    let terminationError = await terminationError()
    guard generation == startGeneration, auth.isCurrent(authority) else { return }
    if terminationError == .sessionRevoked {
      await emitAuthenticationInvalidated(
        InlineProtocolV3ConnectionError.sessionRevoked, generation: generation, authority: authority
      )
      return
    }
    if terminationError == .authorizationInvalidated {
      // A live temporary key can disappear or expire while the permanent account authority
      // remains valid. Reconnect through performStart, which verifies the cached temporary key
      // and regenerates it once using the permanent key before reporting terminal invalidation.
      log.warning("Inline Protocol live authorization closed; rechecking permanent authority")
    }
    await channel.send(Self.liveClosureEvent(for: terminationError))
  }

  static func liveClosureEvent(for error: InlineProtocolV3ConnectionError?) -> TransportEvent {
    .disconnected(errorDescription: error == .authorizationInvalidated
      ? "authorization_recheck"
      : "connection_closed")
  }

  static func authenticationInvalidationReason(
    for error: any Error
  ) -> InlineProtocol.ConnectionError.Reason? {
    guard error as? InlineProtocolV3ConnectionError == .sessionRevoked else {
      return nil
    }
    return .sessionRevoked
  }

  private func emitAuthenticationInvalidated(
    _ error: any Error,
    generation: UInt64,
    authority: AuthInvalidationReceipt
  ) async {
    guard generation == startGeneration, auth.isCurrent(authority),
          let reason = Self.authenticationInvalidationReason(for: error)
    else { return }
    log.warning("Inline Protocol authorization invalidated reason=\(reason)")
    await channel.send(.authInvalidated(authority))
    guard generation == startGeneration, auth.isCurrent(authority) else { return }
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
      .sessionRevoked,
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
    case .inboundMessageTooLarge,
      .invalidKey,
      .protocolFailure,
      .unexpectedResponse:
      return .error
    }
  }
}

public actor NegotiatingRealtimeTransport: Transport {
  typealias TransportFactory = @Sendable () -> any Transport

  private enum Kind { case legacy, inlineProtocol }
  private enum State { case idle, starting, connected, disconnected, switching, stopping }

  private let log = Log.scoped("Realtime.TransportSelection")
  private let hasInlineProtocolCredentials: @Sendable () -> Bool
  private let hasLegacyCredentials: @Sendable () -> Bool
  private let makeLegacyTransport: TransportFactory
  private let makeInlineProtocolTransport: TransportFactory
  private let upgrade: (any LegacyProtocolUpgrading)?
  private let transportPreference: UpgradedSessionTransportPreference
  private let fallbackDeadline: Duration
  private let fallbackCooldown: Duration
  private let channel = AsyncChannel<TransportEvent>()
  private var active: (any Transport)?
  private var activeKind: Kind?
  private var state = State.idle
  private var generation: UInt64 = 0
  private var eventTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  private var retryV3After: ContinuousClock.Instant?
  private var sessionRevoked = false
  private var connectionStartedAt: ContinuousClock.Instant?
  private var connectedWasLogged = false

  public nonisolated var events: AsyncChannel<TransportEvent> { channel }

  public init(
    auth: AuthHandle,
    rsaPublicKeys: [InlineProtocolRSAPublicKey] = [],
    automaticallyUpgradeLegacySession: Bool = false,
    transportPreference: UpgradedSessionTransportPreference = .stored(in: .standard)
  ) {
    self.transportPreference = transportPreference
    hasInlineProtocolCredentials = { auth.inlineProtocolCredentials() != nil }
    hasLegacyCredentials = { auth.token() != nil }
    makeLegacyTransport = { WebSocketTransport() }
    makeInlineProtocolTransport = {
      InlineProtocolV3Transport(auth: auth, rsaPublicKeys: rsaPublicKeys)
    }
    upgrade = automaticallyUpgradeLegacySession
      ? LegacyProtocolUpgradeCoordinator(auth: auth, rsaPublicKeys: rsaPublicKeys) : nil
    fallbackDeadline = .seconds(3)
    fallbackCooldown = .seconds(300)
  }

  init(
    hasInlineProtocolCredentials: @escaping @Sendable () -> Bool,
    hasLegacyCredentials: @escaping @Sendable () -> Bool = { false },
    makeLegacyTransport: @escaping TransportFactory,
    makeInlineProtocolTransport: @escaping TransportFactory,
    upgrade: (any LegacyProtocolUpgrading)? = nil,
    transportPreference: UpgradedSessionTransportPreference = .init(prefersLegacy: { false }, record: { _ in }),
    fallbackDeadline: Duration = .seconds(3),
    fallbackCooldown: Duration = .seconds(300)
  ) {
    self.transportPreference = transportPreference
    self.hasInlineProtocolCredentials = hasInlineProtocolCredentials
    self.hasLegacyCredentials = hasLegacyCredentials
    self.makeLegacyTransport = makeLegacyTransport
    self.makeInlineProtocolTransport = makeInlineProtocolTransport
    self.upgrade = upgrade
    self.fallbackDeadline = fallbackDeadline
    self.fallbackCooldown = fallbackCooldown
  }

  public func start() async {
    // Credentials may become available while a V2 connection is carrying requests. Preserve
    // that owner until an actual disconnect; re-selecting here would lose uncertain writes.
    guard state == .idle || state == .disconnected else { return }
    state = .starting
    connectionStartedAt = .now
    connectedWasLogged = false
    // Only a session that still holds a bearer can use V2, so the operator preference and the
    // startup-failure cooldown never apply to native V3 logins.
    let kind: Kind = hasInlineProtocolCredentials() && (
      !hasLegacyCredentials() || (
        !transportPreference.prefersLegacy() && (retryV3After.map { ContinuousClock.now >= $0 } ?? true)
      )
    ) ? .inlineProtocol : .legacy
    if activeKind != kind {
      guard await retireChild() else { return }
      guard state == .starting else { return }
      install(kind)
    }
    guard let active else { return }
    sessionRevoked = false
    armFallbackDeadline()
    await active.start()
  }

  public func stop() async {
    guard state != .stopping else { return }
    state = .stopping
    deadlineTask?.cancel()
    deadlineTask = nil
    await upgrade?.stop()
    // The final stop event is still part of this connection. Keep its receiver alive until
    // child.stop returns; cancelling an AsyncChannel receiver first can strand the sender.
    await active?.stop()
    generation &+= 1
    eventTask?.cancel()
    eventTask = nil
    active = nil
    activeKind = nil
    state = .idle
  }

  public func send(_ message: ClientMessage) async throws {
    guard let active, state == .connected else { throw TransportError.notConnected }
    try await active.send(message)
  }

  public func isApplicationAuthenticatedOnConnect() async -> Bool {
    guard let active else { return false }
    return await active.isApplicationAuthenticatedOnConnect()
  }

  private func install(_ kind: Kind) {
    let transport: any Transport = kind == .inlineProtocol
      ? makeInlineProtocolTransport() : makeLegacyTransport()
    log.debug(kind == .inlineProtocol ? "Selected Inline Protocol transport" : "Selected legacy Realtime V2 transport")
    active = transport
    activeKind = kind
    generation &+= 1
    let current = generation
    eventTask = Task { [weak self] in
      for await event in transport.events {
        guard !Task.isCancelled else { return }
        await self?.receive(event, generation: current)
      }
    }
  }

  private func retireChild() async -> Bool {
    // Invalidate first, then discard-drain final old-child events. Forwarding the old stop
    // would clear ProtocolSession's newly allocated connection ID before the new connect.
    generation &+= 1
    let retiringGeneration = generation
    let retiringChild = active
    let retiringEvents = eventTask
    await retiringChild?.stop()
    retiringEvents?.cancel()
    guard generation == retiringGeneration else { return false }
    eventTask = nil
    active = nil
    activeKind = nil
    return true
  }

  private func receive(_ event: TransportEvent, generation: UInt64) async {
    guard generation == self.generation else { return }
    guard state != .switching else { return }
    switch event {
    case .connected:
      guard state == .starting else { return }
      deadlineTask?.cancel()
      deadlineTask = nil
      state = .connected
      if activeKind == .inlineProtocol { logAuthenticatedConnection() }
    case .disconnected:
      deadlineTask?.cancel()
      deadlineTask = nil
      if canFallback {
        state = .switching
        // Return to the forwarder before stop: it must drain the child's final event.
        Task { [weak self] in await self?.fallback(generation: generation, reason: "startup_failure") }
        return
      }
      if state != .stopping { state = .disconnected }
    case let .message(message):
      if case let .connectionOpen(open) = message.body, activeKind == .legacy, state == .connected {
        transportPreference.record(UpgradedSessionTransportPreference.prefersLegacy(open))
        logAuthenticatedConnection()
      }
      if case let .connectionError(error) = message.body, error.reason == .sessionRevoked {
        sessionRevoked = true
        deadlineTask?.cancel()
        deadlineTask = nil
      }
    case .authInvalidated:
      sessionRevoked = true
      deadlineTask?.cancel()
      deadlineTask = nil
    case let .transportPreference(prefersLegacy):
      transportPreference.record(prefersLegacy)
      if prefersLegacy, activeKind == .inlineProtocol, state == .connected, hasLegacyCredentials() {
        state = .switching
        // Return to the forwarder before stop: it must drain the child's final event.
        Task { [weak self] in await self?.applyLegacyPreference(generation: generation) }
      }
      return
    default:
      break
    }
    await channel.send(event)
    // Wait for the legacy application handshake, so optional key work does not compete with
    // obtaining the usable session and never runs merely because an unauthenticated socket opened.
    if case let .message(message) = event,
       case .connectionOpen = message.body,
       state == .connected, activeKind == .legacy, generation == self.generation {
      await upgrade?.start()
    }
  }

  /// The operator routed upgraded sessions back to V2. The preference arrives with the V3 open,
  /// so reconnect through the connection owner: its normal handshake and backoff then select V2.
  private func applyLegacyPreference(generation: UInt64) async {
    guard generation == self.generation, state == .switching else { return }
    log.warning("event=legacy_v3_fallback protocol=v2 reason=operator_preference duration_ms=\(elapsedMilliseconds())")
    guard await retireChild() else { return }
    guard state == .switching else { return }
    state = .disconnected
    await channel.send(.disconnected(errorDescription: "transport_preference"))
  }

  private var canFallback: Bool {
    (state == .starting || state == .switching) && activeKind == .inlineProtocol &&
      hasLegacyCredentials() && !sessionRevoked
  }

  private func logAuthenticatedConnection() {
    guard !connectedWasLogged else { return }
    connectedWasLogged = true
    let kind = activeKind == .inlineProtocol ? "v3" : "v2"
    RealtimeTelemetryContext.recordProtocol(kind)
    let cohort = hasLegacyCredentials()
      ? (hasInlineProtocolCredentials() ? "upgraded" : "legacy") : "native"
    log.info("event=legacy_v3_connected protocol=\(kind) cohort=\(cohort) duration_ms=\(elapsedMilliseconds())")
  }

  private func elapsedMilliseconds() -> Int64 {
    let duration = connectionStartedAt?.duration(to: .now) ?? .zero
    return duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
  }

  private func armFallbackDeadline() {
    deadlineTask?.cancel()
    guard canFallback else { return }
    let current = generation
    deadlineTask = Task { [weak self, fallbackDeadline] in
      do { try await Task.sleep(for: fallbackDeadline) } catch { return }
      await self?.fallbackDeadlineReached(generation: current)
    }
  }

  private func fallbackDeadlineReached(generation: UInt64) async {
    guard generation == self.generation else { return }
    // Detach the deadline handle before fallback, so it cannot cancel its own child.start.
    deadlineTask = nil
    await fallback(generation: generation, reason: "deadline")
  }

  private func fallback(generation: UInt64, reason: String) async {
    guard generation == self.generation, canFallback else { return }
    state = .switching
    deadlineTask?.cancel()
    deadlineTask = nil
    retryV3After = ContinuousClock.now + fallbackCooldown
    log.warning("event=legacy_v3_fallback protocol=v2 reason=\(reason) duration_ms=\(elapsedMilliseconds())")
    guard await retireChild() else { return }
    guard state == .switching else { return }
    state = .starting
    install(.legacy)
    await active?.start()
  }
}
