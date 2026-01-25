import Foundation
import Logger

actor ConnectionManager {
  private let log = Log.scoped("RealtimeV2.ConnectionManager", level: .debug)

  private let session: ProtocolSessionType
  private let policy: ConnectionPolicy
  private let timeProvider: ConnectionTimeProvider

  private let eventStream: AsyncStream<ConnectionEvent>
  private let eventContinuation: AsyncStream<ConnectionEvent>.Continuation
  private let snapshotStream: AsyncStream<ConnectionSnapshot>
  private let snapshotContinuation: AsyncStream<ConnectionSnapshot>.Continuation
  private let sessionEventStream: AsyncStream<ProtocolSessionEvent>
  private let sessionEventContinuation: AsyncStream<ProtocolSessionEvent>.Continuation

  private var state: ConnectionState = .stopped
  private var reason: ConnectionReason = .none
  private var attempt: UInt32 = 0
  private var sessionID: UInt64 = 0
  private var stateSince: Date
  private var constraints: ConnectionConstraints
  private var lastErrorDescription: String?

  private var eventTask: Task<Void, Never>?
  private var sessionTask: Task<Void, Never>?
  private var loopsStarted = false

  private var backoffTask: Task<Void, Never>?
  private var authTimeoutTask: Task<Void, Never>?
  private var connectTimeoutTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var pingTimeoutTask: Task<Void, Never>?
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
    (eventStream, eventContinuation) = AsyncStream.create(ConnectionEvent.self, bufferingPolicy: .unbounded)
    (snapshotStream, snapshotContinuation) = AsyncStream.create(ConnectionSnapshot.self, bufferingPolicy: .unbounded)
    (sessionEventStream, sessionEventContinuation) = AsyncStream.create(ProtocolSessionEvent.self, bufferingPolicy: .unbounded)

  }

  deinit {
    eventTask?.cancel()
    sessionTask?.cancel()
  }

  // MARK: - Public API

  func start() async {
    startLoopsIfNeeded()
    eventContinuation.yield(.start)
  }

  func stop() async {
    eventContinuation.yield(.stop)
  }

  func connectNow() async {
    eventContinuation.yield(.connectNow)
  }

  func setAuthAvailable(_ available: Bool) async {
    eventContinuation.yield(available ? .authAvailable : .authLost)
  }

  func setNetworkAvailable(_ available: Bool) async {
    eventContinuation.yield(available ? .networkAvailable : .networkUnavailable)
  }

  func setAppActive(_ active: Bool) async {
    eventContinuation.yield(active ? .appForeground : .appBackground)
  }

  func setUserWantsConnection(_ wants: Bool) async {
    constraints.userWantsConnection = wants
    eventContinuation.yield(wants ? .connectNow : .stop)
  }

  func snapshots() -> AsyncStream<ConnectionSnapshot> {
    snapshotStream
  }

  func sessionEvents() -> AsyncStream<ProtocolSessionEvent> {
    sessionEventStream
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
    eventTask?.cancel()
    sessionTask?.cancel()
    eventContinuation.finish()
    snapshotContinuation.finish()
    sessionEventContinuation.finish()
    session.events.finish()
    eventTask = nil
    sessionTask = nil
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
      attempt = 0
      cancelBackoff()
      await evaluateConstraints(resetBackoff: true)

    case .authLost:
      constraints.authAvailable = false
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

    case .transportConnecting:
      if state != .connectingTransport {
        await transition(to: .connectingTransport, reason: .none)
      }

    case .transportConnected:
      cancelConnectTimeout()
      guard state == .connectingTransport || state == .authenticating else { return }
      await transition(to: .authenticating, reason: .none)
      startAuthTimeout(sessionID: sessionID)
      await session.startHandshake()

    case let .transportDisconnected(errorDescription):
      lastErrorDescription = errorDescription
      await handleTransportDisconnect(reason: .transportDisconnected)

    case .protocolOpen:
      cancelAuthTimeout()
      attempt = 0
      lastErrorDescription = nil
      guard state == .authenticating || state == .connectingTransport else { return }
      await transition(to: .open, reason: .none)
      startPingLoop(sessionID: sessionID)

    case .protocolAuthFailed:
      lastErrorDescription = "auth_failed"
      await session.stopTransport()
      await handleTransportDisconnect(reason: .authFailed)

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

    let eventStream = self.eventStream
    eventTask = Task { [weak self] in
      guard let self else { return }
      for await event in eventStream {
        await self.handle(event)
      }
    }

    sessionTask = Task { [weak self] in
      guard let self else { return }
      for await event in self.session.events {
        await self.handleSessionEvent(event)
      }
    }
  }

  private func handleSessionEvent(_ event: ProtocolSessionEvent) async {
    switch event {
    case .transportConnecting:
      eventContinuation.yield(.transportConnecting)

    case .transportConnected:
      eventContinuation.yield(.transportConnected)

    case let .transportDisconnected(errorDescription):
      eventContinuation.yield(.transportDisconnected(errorDescription: errorDescription))

    case .protocolOpen:
      eventContinuation.yield(.protocolOpen)

    case .authFailed:
      eventContinuation.yield(.protocolAuthFailed)

    case let .pong(nonce):
      handlePong(nonce: nonce)
      await forwardSessionEvent(event)

    default:
      await forwardSessionEvent(event)
    }
  }

  private func forwardSessionEvent(_ event: ProtocolSessionEvent) async {
    sessionEventContinuation.yield(event)
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

  private func startConnecting() async {
    sessionID = sessionID &+ 1
    cancelAllTimers()
    pendingPingNonce = nil

    await transition(to: .connectingTransport, reason: .none)
    await session.startTransport()
    startConnectTimeout(sessionID: sessionID)
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
    pendingPingNonce = nil
    backgroundGraceActive = false
    await session.stopTransport()
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
      self.eventContinuation.yield(.backoffFired)
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
      self.eventContinuation.yield(.protocolAuthFailed)
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
      await self.session.stopTransport()
      await self.handleConnectTimeout()
    }
  }

  private func handleConnectTimeout() async {
    lastErrorDescription = "connect_timeout"
    await handleTransportDisconnect(reason: .transportDisconnected)
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
      self.eventContinuation.yield(.backgroundGraceExpired)
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
    await session.sendPing(nonce: nonce)

    pingTimeoutTask?.cancel()
    pingTimeoutTask = Task { [weak self] in
      guard let self else { return }
      await self.timeProvider.sleep(for: self.policy.pingTimeout)
      guard !Task.isCancelled else { return }
      guard await self.sessionID == sessionID else { return }
      guard await self.pendingPingNonce == nonce else { return }
      self.eventContinuation.yield(.pingTimeout)
    }
  }

  private func handlePong(nonce: UInt64) {
    guard pendingPingNonce == nonce else { return }
    pendingPingNonce = nil
    pingTimeoutTask?.cancel()
    pingTimeoutTask = nil
  }

  private func cancelAllTimers(exceptBackground: Bool = false) {
    cancelBackoff()
    cancelAuthTimeout()
    cancelConnectTimeout()
    pingTask?.cancel()
    pingTask = nil
    pingTimeoutTask?.cancel()
    pingTimeoutTask = nil
    if !exceptBackground {
      cancelBackgroundGrace()
    }
  }
}
