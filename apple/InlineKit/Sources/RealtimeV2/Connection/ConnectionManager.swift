import AsyncAlgorithms
import Foundation
import Logger

private struct ConnectionCommand: Sendable {
  let event: ConnectionEvent
  let enqueuedAt: TimeInterval
  let receipt: ConnectionCommandReceipt?
}

private actor ConnectionCommandReceipt {
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

actor ConnectionManager {
  private let log = Log.scoped("RealtimeV2.ConnectionManager", level: .debug)

  private let session: ProtocolSessionType
  private let policy: ConnectionPolicy
  private let timeProvider: ConnectionTimeProvider

  private let snapshotStream: AsyncStream<ConnectionSnapshot>
  private let snapshotContinuation: AsyncStream<ConnectionSnapshot>.Continuation
  // One ordered account collector. Backpressure here preserves the wire order
  // between update application and a later RPC result without creating another
  // observer or replay queue.
  private let sessionEventChannel = AsyncChannel<ProtocolSessionEventEnvelope>()
  private let commandStream: AsyncStream<ConnectionCommand>
  private let commandContinuation: AsyncStream<ConnectionCommand>.Continuation

  private var state: ConnectionState = .stopped
  private var reason: ConnectionReason = .none
  private var attempt: UInt32 = 0
  private var sessionID: UInt64 = 0
  private var stateSince: Date
  private var constraints: ConnectionConstraints
  private var networkQuality: ConnectionNetworkQuality = .good
  private var lastErrorDescription: String?

  private var commandTask: Task<Void, Never>?
  private var sessionTask: Task<Void, Never>?
  private var transportStartTask: Task<Void, Never>?
  private var handshakeTask: Task<Void, Never>?
  private var loopsStarted = false

  private var backoffTask: Task<Void, Never>?
  private var authTimeoutTask: Task<Void, Never>?
  private var connectTimeoutTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var pingTimeoutTask: Task<Void, Never>?
  private var wakeProbeTask: Task<Void, Never>?
  private var probeTimeoutTask: Task<Void, Never>?
  private var probeContinuation: CheckedContinuation<Bool, Never>?
  private var probeNonce: UInt64?
  private var backgroundGraceTask: Task<Void, Never>?
  private var pendingPingNonce: UInt64?
  private var backgroundGraceActive = false

  init(
    session: ProtocolSessionType,
    policy: ConnectionPolicy = ConnectionPolicy(),
    timeProvider: ConnectionTimeProvider = SystemConnectionTimeProvider(),
    constraints: ConnectionConstraints = .initial
  ) {
    self.session = session
    self.policy = policy
    self.timeProvider = timeProvider
    self.constraints = constraints
    stateSince = timeProvider.now()
    (commandStream, commandContinuation) = AsyncStream.create(
      ConnectionCommand.self,
      bufferingPolicy: .unbounded
    )
    (snapshotStream, snapshotContinuation) = AsyncStream.create(
      ConnectionSnapshot.self,
      bufferingPolicy: .bufferingNewest(1)
    )
  }

  deinit {
    commandTask?.cancel()
    sessionTask?.cancel()
    transportStartTask?.cancel()
    handshakeTask?.cancel()
    wakeProbeTask?.cancel()
  }

  // MARK: - Public API

  func start() async {
    await enqueue(.start)
  }

  func stop() async {
    await enqueue(.stop)
  }

  func connectNow() async {
    await enqueue(.connectNow)
  }

  func setAuthAvailable(_ available: Bool) async {
    await enqueue(available ? .authAvailable : .authLost)
  }

  func setNetworkAvailable(_ available: Bool) async {
    await enqueue(available ? .networkAvailable : .networkUnavailable)
  }

  func setNetworkQuality(_ quality: ConnectionNetworkQuality) async {
    networkQuality = quality
  }

  func setAppActive(_ active: Bool) async {
    await enqueue(active ? .appForeground : .appBackground)
  }

  func systemDidWake() async {
    await enqueue(.systemWake)
  }

  func setUserWantsConnection(_ wants: Bool) async {
    await enqueue(wants ? .connectNow : .stop)
  }

  func snapshots() -> AsyncStream<ConnectionSnapshot> {
    snapshotStream
  }

  func sessionEvents() -> AsyncChannel<ProtocolSessionEventEnvelope> {
    sessionEventChannel
  }

  /// Final process teardown only. Normal stop/logout keeps the collector alive
  /// so the same account owner can reconnect.
  func finishSessionEventForwarding() async {
    let task = sessionTask
    sessionTask = nil
    task?.cancel()
    // Wake a ProtocolSession producer that is waiting on the unbuffered source
    // channel. The envelope's cancellation handler below releases its apply
    // receipt when there is no longer an account collector to acknowledge it.
    session.events.finish()
    sessionEventChannel.finish()
    await task?.value
  }

  func currentSnapshot() -> ConnectionSnapshot {
    ConnectionSnapshot(
      state: state,
      reason: reason,
      attempt: attempt,
      since: stateSince,
      sessionID: sessionID,
      constraints: constraints,
      lastErrorDescription: lastErrorDescription
    )
  }

  func shutdownForTesting() async {
    cancelAllTimers()
    backgroundGraceActive = false
    pendingPingNonce = nil
    commandTask?.cancel()
    sessionTask?.cancel()
    transportStartTask?.cancel()
    handshakeTask?.cancel()
    wakeProbeTask?.cancel()
    commandContinuation.finish()
    snapshotContinuation.finish()
    sessionEventChannel.finish()
    session.events.finish()
    commandTask = nil
    sessionTask = nil
    transportStartTask = nil
    handshakeTask = nil
  }

  // MARK: - Event Handling

  private func handle(_ event: ConnectionEvent) async {
    switch event {
    case .start:
      constraints.userWantsConnection = true
      await evaluateConstraints(resetBackoff: false)

    case .stop:
      constraints.userWantsConnection = false
      await transition(to: .stopped, reason: .userStop)
      await stopTransportAndReset()

    case .connectNow:
      constraints.userWantsConnection = true
      attempt = 0
      cancelBackoff()
      await evaluateConstraints(resetBackoff: true)

    case .authAvailable:
      constraints.authAvailable = true
      log.info("Realtime auth constraint applied available=1 state=\(state) session=\(sessionID)")
      attempt = 0
      cancelBackoff()
      await evaluateConstraints(resetBackoff: true)

    case .authLost:
      constraints.authAvailable = false
      log.info("Realtime auth constraint applied available=0 state=\(state) session=\(sessionID)")
      await handleConstraintLoss(reason: .authLost)

    case .networkAvailable:
      constraints.networkAvailable = true
      attempt = 0
      cancelBackoff()
      await evaluateConstraints(resetBackoff: true)

    case .networkUnavailable:
      constraints.networkAvailable = false
      await handleConstraintLoss(reason: .networkUnavailable)

    case .appForeground:
      constraints.appActive = true
      attempt = 0
      cancelBackgroundGrace()
      backgroundGraceActive = false
      cancelBackoff()
      await evaluateConstraints(resetBackoff: true)

    case .appBackground:
      constraints.appActive = false
      if state == .open || state == .connectingTransport || state == .authenticating {
        backgroundGraceActive = true
        scheduleBackgroundGrace()
      } else {
        backgroundGraceActive = false
      }

    case .systemWake:
      constraints.appActive = true
      attempt = 0
      cancelBackgroundGrace()
      backgroundGraceActive = false
      cancelBackoff()
      resetPendingPing()
      await evaluateConstraints(resetBackoff: true)
      if state == .open {
        startWakeProbe(sessionID: sessionID)
      }

    case let .wakeProbeCompleted(eventSessionID, isHealthy):
      guard eventSessionID == sessionID else {
        log.warning(
          "Ignoring stale wake probe event_session=\(eventSessionID) current_session=\(sessionID) state=\(state)"
        )
        return
      }
      wakeProbeTask = nil
      if !isHealthy, state == .open {
        await forceReconnect(reason: .none)
      }

    case let .transportConnecting(eventSessionID):
      guard eventSessionID == sessionID else {
        log.warning(
          "Ignoring stale transport connecting event_session=\(eventSessionID) current_session=\(sessionID) state=\(state)"
        )
        return
      }
      if state != .connectingTransport {
        await transition(to: .connectingTransport, reason: .none)
      }

    case let .transportConnected(eventSessionID):
      guard eventSessionID == sessionID else {
        log.warning(
          "Ignoring stale transport connected event_session=\(eventSessionID) current_session=\(sessionID) state=\(state)"
        )
        return
      }
      cancelConnectTimeout()
      guard state == .connectingTransport || state == .authenticating else { return }
      await transition(to: .authenticating, reason: .none)
      startAuthTimeout(sessionID: sessionID)
      log.info("Realtime authenticated handshake started session=\(sessionID)")
      handshakeTask?.cancel()
      let session = self.session
      let currentSessionID = sessionID
      handshakeTask = Task {
        await session.startHandshake(sessionID: currentSessionID)
      }

    case let .transportDisconnected(eventSessionID, errorDescription):
      guard eventSessionID == sessionID else {
        log.warning(
          "Ignoring stale transport disconnected event_session=\(eventSessionID) current_session=\(sessionID) state=\(state)"
        )
        return
      }
      lastErrorDescription = errorDescription
      await handleTransportDisconnect(reason: .transportDisconnected)

    case let .protocolOpen(openSessionID):
      guard openSessionID == sessionID else {
        log.warning(
          "Ignoring stale protocol open event_session=\(openSessionID) current_session=\(sessionID) state=\(state)"
        )
        return
      }
      guard state == .authenticating || state == .connectingTransport else { return }
      cancelAuthTimeout()
      handshakeTask?.cancel()
      handshakeTask = nil
      attempt = 0
      lastErrorDescription = nil
      await transition(to: .open, reason: .none)
      log.info("Realtime authenticated handshake opened session=\(sessionID)")
      startPingLoop(sessionID: sessionID)

    case .protocolAuthFailed:
      log.error("Realtime authenticated handshake timed out")
      lastErrorDescription = "auth_failed"
      await session.stopTransport()
      await handleTransportDisconnect(reason: .authFailed)

    case .connectTimeout:
      lastErrorDescription = "connect_timeout"
      await session.stopTransport()
      await handleTransportDisconnect(reason: .transportDisconnected)

    case .pingTimeout:
      lastErrorDescription = "ping_timeout"
      await session.stopTransport()
      await handleTransportDisconnect(reason: .pingTimeout)

    case .backoffFired:
      await evaluateConstraints(resetBackoff: false)

    case .backgroundGraceExpired:
      backgroundGraceActive = false
      await transition(to: .backgroundSuspended, reason: .backgroundSuspended)
      await stopTransportAndReset()
    }
  }

  private func startLoopsIfNeeded() {
    guard !loopsStarted else { return }
    loopsStarted = true

    let commandStream = self.commandStream
    commandTask = Task { [weak self] in
      for await command in commandStream {
        guard let self else {
          await command.receipt?.finish()
          return
        }
        await self.handleCommand(command)
      }
    }

    sessionTask = Task { [weak self] in
      guard let self else { return }
      for await envelope in self.session.events {
        guard !Task.isCancelled else {
          await envelope.markProcessed()
          return
        }
        await self.handleSessionEvent(envelope)
      }
    }
  }

  private func enqueue(_ event: ConnectionEvent) async {
    startLoopsIfNeeded()
    let receipt = ConnectionCommandReceipt()
    commandContinuation.yield(ConnectionCommand(
      event: event,
      enqueuedAt: ProcessInfo.processInfo.systemUptime,
      receipt: receipt
    ))
    await receipt.wait()
  }

  /// Session callbacks are already ordered by `sessionTask`. Submit them without waiting for the
  /// command receipt so a stop handler cannot wait on a disconnect callback that is waiting on
  /// the stop handler itself. `commandStream` remains the sole FIFO state-mutation owner.
  private func submit(_ event: ConnectionEvent) {
    startLoopsIfNeeded()
    commandContinuation.yield(ConnectionCommand(
      event: event,
      enqueuedAt: ProcessInfo.processInfo.systemUptime,
      receipt: nil
    ))
  }

  private func handleCommand(_ command: ConnectionCommand) async {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let queueMilliseconds = Int((startedAt - command.enqueuedAt) * 1_000)
    if queueMilliseconds >= 250 {
      log.warning(
        "Connection event delayed event=\(command.event.diagnosticName) queue_ms=\(queueMilliseconds) state=\(state) session=\(sessionID)"
      )
    }

    await handle(command.event)

    let handleMilliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    if handleMilliseconds >= 250 {
      log.warning(
        "Connection event handler slow event=\(command.event.diagnosticName) duration_ms=\(handleMilliseconds) state=\(state) session=\(sessionID)"
      )
    }
    await command.receipt?.finish()
  }

  private func handleSessionEvent(_ envelope: ProtocolSessionEventEnvelope) async {
    let event = envelope.event
    switch event {
    case let .transportConnecting(eventSessionID):
      submit(.transportConnecting(sessionID: eventSessionID))

    case let .transportConnected(eventSessionID):
      submit(.transportConnected(sessionID: eventSessionID))

    case let .transportDisconnected(eventSessionID, errorDescription):
      submit(.transportDisconnected(
        sessionID: eventSessionID,
        errorDescription: errorDescription
      ))

    case let .protocolOpen(openSessionID):
      submit(.protocolOpen(sessionID: openSessionID))

    case .authFailed:
      submit(.authLost)
      await forwardSessionEvent(envelope)

    case let .pong(nonce):
      handlePong(nonce: nonce)
      await envelope.markProcessed()

    default:
      await forwardSessionEvent(envelope)
    }
  }

  private func forwardSessionEvent(_ envelope: ProtocolSessionEventEnvelope) async {
    await withTaskCancellationHandler {
      await sessionEventChannel.send(envelope)
      if Task.isCancelled {
        await envelope.markProcessed()
      }
    } onCancel: {
      // AsyncChannel.send is intentionally unbuffered. If termination cancels
      // this forwarding task while no account collector is receiving, release
      // the source acknowledgement so ProtocolSession cannot remain stranded.
      Task { await envelope.markProcessed() }
    }
  }

  // MARK: - State Transitions

  private func evaluateConstraints(resetBackoff: Bool) async {
    if !constraintsSatisfied() {
      await transition(to: .waitingForConstraints, reason: .constraintUnavailable)
      await stopTransportAndReset()
      return
    }

    switch state {
    case .stopped, .waitingForConstraints, .backgroundSuspended, .backoff:
      if resetBackoff {
        attempt = 0
      }
      await startConnecting()
    case .connectingTransport, .authenticating, .open:
      break
    }
  }

  private func handleConstraintLoss(reason: ConnectionReason) async {
    cancelBackgroundGrace()
    backgroundGraceActive = false
    await transition(to: .waitingForConstraints, reason: reason)
    await stopTransportAndReset()
  }

  private func handleTransportDisconnect(reason: ConnectionReason) async {
    guard state != .stopped, state != .waitingForConstraints, state != .backgroundSuspended, state != .backoff else {
      return
    }
    handshakeTask?.cancel()
    handshakeTask = nil
    cancelAllTimers(exceptBackground: true)

    guard constraintsSatisfied() else {
      await transition(to: .waitingForConstraints, reason: .constraintUnavailable)
      await stopTransportAndReset()
      return
    }

    attempt = attempt &+ 1
    await transition(to: .backoff, reason: reason)
    scheduleBackoff(sessionID: sessionID)
  }

  private func forceReconnect(reason: ConnectionReason) async {
    lastErrorDescription = nil
    attempt = 0
    cancelBackoff()
    await transition(to: .stopped, reason: reason)
    await stopTransportAndReset()
    await evaluateConstraints(resetBackoff: true)
  }

  private func startConnecting() async {
    sessionID = sessionID &+ 1
    cancelAllTimers()
    handshakeTask?.cancel()
    handshakeTask = nil
    pendingPingNonce = nil

    await transition(to: .connectingTransport, reason: .none)
    startConnectTimeout(sessionID: sessionID)
    let session = self.session
    let currentSessionID = sessionID
    transportStartTask?.cancel()
    transportStartTask = Task { [weak self] in
      await session.startTransport(sessionID: currentSessionID)
      await self?.transportStartDidFinish(sessionID: currentSessionID)
    }
  }

  private func transportStartDidFinish(sessionID completedSessionID: UInt64) {
    guard sessionID == completedSessionID else { return }
    transportStartTask = nil
  }

  private func transition(to newState: ConnectionState, reason newReason: ConnectionReason) async {
    guard newState != state || newReason != reason else { return }
    state = newState
    reason = newReason
    stateSince = timeProvider.now()
    snapshotContinuation.yield(currentSnapshot())
    log.debug("Connection state changed state=\(newState) reason=\(newReason) attempt=\(attempt) session=\(sessionID)")
  }

  private func stopTransportAndReset() async {
    cancelAllTimers()
    let stoppingStartTask = transportStartTask
    transportStartTask = nil
    stoppingStartTask?.cancel()
    handshakeTask?.cancel()
    handshakeTask = nil
    pendingPingNonce = nil
    backgroundGraceActive = false
    await session.stopTransport()
    await stoppingStartTask?.value
  }

  private func constraintsSatisfied() -> Bool {
    let appActiveEffective = constraints.appActive || backgroundGraceActive
    return constraints.authAvailable && constraints.networkAvailable && appActiveEffective && constraints.userWantsConnection
  }

  // MARK: - Timers

  private func scheduleBackoff(sessionID: UInt64) {
    cancelBackoff()
    let delay = policy.backoff.delay(attempt)
    backoffTask = Task { [weak self] in
      guard let self else { return }
      await self.timeProvider.sleep(for: delay)
      guard !Task.isCancelled else { return }
      guard await self.sessionID == sessionID else { return }
      await self.enqueue(.backoffFired)
    }
  }

  private func cancelBackoff() {
    backoffTask?.cancel()
    backoffTask = nil
  }

  private func startAuthTimeout(sessionID: UInt64) {
    cancelAuthTimeout()
    authTimeoutTask = Task { [weak self] in
      guard let self else { return }
      await self.timeProvider.sleep(for: self.policy.authTimeout)
      guard !Task.isCancelled else { return }
      guard await self.sessionID == sessionID else { return }
      guard await self.state == .authenticating else { return }
      await self.enqueue(.protocolAuthFailed)
    }
  }

  private func cancelAuthTimeout() {
    authTimeoutTask?.cancel()
    authTimeoutTask = nil
  }

  private func startConnectTimeout(sessionID: UInt64) {
    cancelConnectTimeout()
    connectTimeoutTask = Task { [weak self] in
      guard let self else { return }
      await self.timeProvider.sleep(for: self.policy.connectTimeout)
      guard !Task.isCancelled else { return }
      guard await self.sessionID == sessionID else { return }
      guard await self.state == .connectingTransport else { return }
      await self.enqueue(.connectTimeout)
    }
  }

  private func cancelConnectTimeout() {
    connectTimeoutTask?.cancel()
    connectTimeoutTask = nil
  }

  private func scheduleBackgroundGrace() {
    guard state == .open || state == .connectingTransport || state == .authenticating else { return }
    cancelBackgroundGrace()
    backgroundGraceTask = Task { [weak self] in
      guard let self else { return }
      await self.timeProvider.sleep(for: self.policy.backgroundGrace)
      guard !Task.isCancelled else { return }
      await self.enqueue(.backgroundGraceExpired)
    }
  }

  private func cancelBackgroundGrace() {
    backgroundGraceTask?.cancel()
    backgroundGraceTask = nil
  }

  private func startPingLoop(sessionID: UInt64) {
    pingTask?.cancel()
    pingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.timeProvider.sleep(for: self.policy.pingInterval)
        guard !Task.isCancelled else { return }
        guard await self.sessionID == sessionID else { return }
        guard await self.state == .open else { return }
        await self.sendPingIfNeeded(sessionID: sessionID)
      }
    }
  }

  private func sendPingIfNeeded(sessionID: UInt64) async {
    guard pendingPingNonce == nil else { return }
    let nonce = UInt64.random(in: 0 ... UInt64.max)
    pendingPingNonce = nonce

    pingTimeoutTask?.cancel()
    pingTimeoutTask = Task { [weak self] in
      guard let self else { return }
      let timeout = self.policy.pingTimeout(for: await self.networkQuality)
      await self.timeProvider.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      guard await self.sessionID == sessionID else { return }
      guard await self.pendingPingNonce == nonce else { return }
      await self.enqueue(.pingTimeout)
    }

    await session.sendPing(nonce: nonce)
  }

  private func handlePong(nonce: UInt64) {
    if pendingPingNonce == nonce {
      resetPendingPing()
    }

    if probeNonce == nonce {
      probeNonce = nil
      probeTimeoutTask?.cancel()
      probeTimeoutTask = nil
      if let continuation = probeContinuation {
        probeContinuation = nil
        continuation.resume(returning: true)
      }
    }
  }

  private func probeConnection(timeout: Duration) async -> Bool {
    guard state == .open else { return false }
    if probeContinuation != nil {
      return false
    }

    let nonce = UInt64.random(in: 0 ... UInt64.max)
    probeNonce = nonce

    return await withCheckedContinuation { continuation in
      probeContinuation = continuation

      probeTimeoutTask?.cancel()
      probeTimeoutTask = Task { [weak self] in
        guard let self else { return }
        await self.timeProvider.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        await self.timeoutProbe(nonce: nonce)
      }

      Task { await self.session.sendPing(nonce: nonce) }
    }
  }

  private func startWakeProbe(sessionID: UInt64) {
    cancelWakeProbe()
    let timeout = policy.wakeProbeTimeout
    wakeProbeTask = Task { [weak self] in
      guard let self else { return }
      let isHealthy = await self.probeConnection(timeout: timeout)
      guard !Task.isCancelled else { return }
      await self.submit(.wakeProbeCompleted(sessionID: sessionID, isHealthy: isHealthy))
    }
  }

  private func timeoutProbe(nonce: UInt64) async {
    guard probeNonce == nonce else { return }
    probeNonce = nil
    probeTimeoutTask?.cancel()
    probeTimeoutTask = nil
    if let continuation = probeContinuation {
      probeContinuation = nil
      continuation.resume(returning: false)
    }
  }

  private func cancelProbe() {
    probeTimeoutTask?.cancel()
    probeTimeoutTask = nil
    if let continuation = probeContinuation {
      probeContinuation = nil
      continuation.resume(returning: false)
    }
    probeNonce = nil
  }

  private func cancelWakeProbe() {
    wakeProbeTask?.cancel()
    wakeProbeTask = nil
    cancelProbe()
  }

  private func cancelAllTimers(exceptBackground: Bool = false) {
    cancelBackoff()
    cancelAuthTimeout()
    cancelConnectTimeout()
    cancelWakeProbe()
    pingTask?.cancel()
    pingTask = nil
    pingTimeoutTask?.cancel()
    pingTimeoutTask = nil
    if !exceptBackground {
      cancelBackgroundGrace()
    }
  }

  private func resetPendingPing() {
    pendingPingNonce = nil
    pingTimeoutTask?.cancel()
    pingTimeoutTask = nil
  }
}
