import Atomics
import Foundation
import InlineConfig
import InlineProtocol
import Logger
import Network
import Sentry

#if canImport(UIKit)
import UIKit
#endif

enum TransportConnectionState {
  case disconnected
  case connecting
  case connected
}

private enum TransportOrigin: String {
  case connectStart = "connect_start"
  case didOpen = "did_open"
  case connectTimeout = "connect_timeout"
  case receive = "receive"
  case ping = "ping"
  case didClose = "did_close"
  case didComplete = "did_complete"
  case networkPath = "network_path"
  case reconnectScheduled = "reconnect_scheduled"
  case ensureConnected = "ensure_connected"
}

private extension TransportConnectionState {
  var sentryValue: String {
    switch self {
      case .disconnected: "disconnected"
      case .connecting: "connecting"
      case .connected: "connected"
    }
  }
}

/// This is a stateless websocket transport layer that can be used to send and receive messages.
/// We'll provide messages at a higher level. This is a dumb reconnecting transport layer.
/// We'll track the ack'ed messages higher level.
/// scope:
/// - connect to websocket endpoint
/// - provide a send method
/// - provide an onReceive publisher
/// - handle reconnections
/// - handle ping/pong
/// - handle network changes
/// - handle background/foreground changes
/// - handle connection timeout

actor WebSocketTransport: NSObject, Sendable {
  // Tasks
  private var webSocketTask: URLSessionWebSocketTask?
  private var pingPongTask: Task<Void, Never>? = nil
  private var msgTask: Task<Void, Never>? = nil
  private var connectionTimeoutTask: Task<Void, Never>? = nil
  private var reconnectionTask: Task<Void, Never>? = nil

  // State
  private var running = false
  public var connectionState: TransportConnectionState = .disconnected
  private var networkAvailable = true

  // Configuration
  private let urlString: String = {
    if ProjectConfig.useProductionApi {
      return "wss://api.inline.chat/realtime"
    }

    #if targetEnvironment(simulator)
    return "ws://localhost:8000/realtime"
    #elseif DEBUG && os(iOS)
    return "ws://\(ProjectConfig.devHost):8000/realtime"
    #elseif DEBUG && os(macOS)
    return "ws://\(ProjectConfig.devHost):8000/realtime"
    #else
    return "wss://api.inline.chat/realtime"
    #endif
  }()

  private var session: URLSession?

  typealias StateObserverFn = (_ state: TransportConnectionState, _ networkAvailable: Bool) -> Void

  // Internals
  private var stateObservers: [StateObserverFn] = []
  private var messageHandler: ((ServerProtocolMessage) -> Void)? = nil
  private var log = Log.scoped("Realtime_TransportWS")
  private var pathMonitor: NWPathMonitor?
  private let pingInFlight = ManagedAtomic<Bool>(false)
  private var reconnectionToken: UInt64 = 0
  private var scheduledReconnectDelay: TimeInterval? = nil
  private var connectStartedAt: Date?
  private var connectedAt: Date?
  private var lastMessageAt: Date?
  private var lastPingSuccessAt: Date?
  private var lastNetworkChangeAt: Date?

  // Ping timeouts (in seconds)
  private let pingTimeoutNormal: TimeInterval = 6.0 // Wi-Fi / LTE
  private let pingTimeoutConstrained: TimeInterval = 10.0 // 3G / constrained paths

  override init() {
    log.info("Initializing WebSocketTransport")
    // Create session configuration
    let configuration = URLSessionConfiguration.default
    configuration.shouldUseExtendedBackgroundIdleMode = true
    configuration.timeoutIntervalForRequest = 30
    configuration.waitsForConnectivity = false // Don't wait, try immediately
    configuration.httpMaximumConnectionsPerHost = 1 // Allow multiple connections
    configuration.allowsCellularAccess = true
    configuration.isDiscretionary = false // Immediate connection attempt
    configuration.networkServiceType = .responsiveData // For real-time priority

    configuration.tlsMinimumSupportedProtocolVersion = .TLSv12

    session = nil

    super.init()

    // Initialize session with a serial delegate queue to keep callbacks
    // predictable and reduce races across connect/disconnect swaps.
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.name = "WebSocketTransport.delegate"

    session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
  }

  private func startBackgroundObservers() {
    // Add background/foreground observers
    #if os(iOS)
    // Remove any existing observers first
    NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
    #endif
  }

  // Add these properties at the top with other properties
  private var isInBackground = false

  private func setIsInBackground(_ isInBackground: Bool) {
    self.isInBackground = isInBackground
  }

  // Add background handling methods
  #if os(iOS)

  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var backgroundTransitionTime: Date?

  private func wentInBackground() async {
    setIsInBackground(true)

    backgroundTask = await UIApplication.shared
      .beginBackgroundTask { [weak self] in
        Task {
          await self?.endBackgroundTask()
        }
      }

    defer {
      Task { endBackgroundTask() }
    }

    try? await Task.sleep(for: .seconds(25))
    await cleanupBackgroundResources()
  }

  private func disconnectIfInBackground() async {
    // Only disconnect if still in background
    if isInBackground, connectionState == .connected {
      log.trace("Disconnecting due to extended background time")
      await cancelTasks()
      connectionState = .disconnected
      notifyStateChange()
    }
  }

  // Update background handling to be more robust
  @objc private nonisolated func handleAppDidEnterBackground() {
    Task {
      await wentInBackground()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    Task { @MainActor in
      await UIApplication.shared.endBackgroundTask(backgroundTask)
    }
    backgroundTask = .invalid
  }

  private func cleanupBackgroundResources() async {
    // Only disconnect if we've been in background for more than 30 seconds
    if connectionState == .connected {
      log.trace("Disconnecting due to extended background time")
      await cancelTasks()
      connectionState = .disconnected
      notifyStateChange()
    }
  }

  @objc private nonisolated func handleAppWillEnterForeground() {
    Task(priority: .userInitiated) {
      await prepareForForeground()
    }
  }
  #endif

  private var reconnectionAttempts: Int = 0

  private func prepareForForeground() async {
    setIsInBackground(false)

    // Reset reconnection attempts counter for foreground transitions
    reconnectionAttempts = 0

    if connectionState != .connected {
      // Direct connection is faster than going through reconnection logic
      await connect(foregroundTransition: true)
    } else {
      // Verify existing connection
      do {
        try await sendPing(fastTimeout: true)
      } catch {
        log.trace("Ping failed after foreground, reconnecting...")
        await connect(foregroundTransition: true)
      }
    }
  }

  deinit {
    // Remove notification observers
    #if os(iOS)
    NotificationCenter.default.removeObserver(self)
    #endif

    // Create a detached task to ensure stop() is called
    Task.detached { [self] in
      await self.stopAndReset()
    }
  }

  // MARK: - Connection Management

  private func handleConnected() {
    // If we connected, any pending reconnect timer is obsolete.
    reconnectionTask?.cancel()
    reconnectionTask = nil
    scheduledReconnectDelay = nil

    // Update state
    connectionState = .connected
    connectedAt = Date()
    notifyStateChange()
    addTransportBreadcrumb("WebSocket opened", origin: .didOpen)

    setupPingPong()

    reconnectionAttempts = 0

    msgTask = Task {
      log.trace("starting message receiving")
      await receiveMessages()
    }
  }

  func start() async {
    guard !running else {
      log.trace("Already running")
      return
    }

    log.info("Starting to run")
    running = true
    setupNetworkMonitoring()
    startBackgroundObservers()

    await connect()
  }

  func connect(foregroundTransition: Bool = false) async {
    // Add this guard to prevent connecting if already connected
    guard connectionState == .disconnected else {
      log.trace("Already connected or connecting")
      return
    }

    // If a reconnect was scheduled, we're connecting now; cancel it.
    reconnectionTask?.cancel()
    reconnectionTask = nil
    scheduledReconnectDelay = nil

    // Cancel existing tasks before changing state
    await cancelTasks()

    // Double-check state after task cancellation
    if connectionState != .disconnected {
      log.trace("State changed during task cancellation")
      return
    }

    // Now update state
    connectionState = .connecting
    connectStartedAt = Date()
    connectedAt = nil
    lastPingSuccessAt = nil
    notifyStateChange()

    setupConnectionTimeout(foregroundTransition: foregroundTransition)

    let url = URL(string: urlString)!
    addTransportBreadcrumb(
      "Starting websocket connect",
      origin: .connectStart,
      data: [
        "foreground_transition": foregroundTransition,
      ]
    )
    log.info("Connecting to \(urlString)")
    webSocketTask = session!.webSocketTask(with: url)
    webSocketTask?.priority = URLSessionTask.highPriority
    webSocketTask?.resume()
  }

  func stopAndReset() async {
    log.trace("Disconnecting and stopping (manual)")

    // Set running to false first to prevent reconnection attempts
    running = false

    // Cancel all tasks
    await cancelTasks()

    // Cancel the connection timeout task
    connectionTimeoutTask?.cancel()
    connectionTimeoutTask = nil

    // Close WebSocket connection if active
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil

    // Stop network monitoring
    stopNetworkMonitoring()

    // Clear state
    connectionState = .disconnected
    stateObservers = []
    messageHandler = nil

    // Notify state change as final action
    notifyStateChange()

    log.info("Transport stopped completely")
  }

  // Track network quality
  private var networkQualityIsLow: Bool {
    guard let pathMonitor else { return false }
    return pathMonitor.currentPath.isExpensive || pathMonitor.currentPath.isConstrained
  }

  // MARK: - State Management

  func addStateObserver(
    _ observer: @escaping @Sendable StateObserverFn
  ) {
    stateObservers.append(observer)
    // Immediately notify of current state
    observer(connectionState, networkAvailable)
  }

  func addMessageHandler(
    _ handler: @escaping @Sendable (ServerProtocolMessage) -> Void
  ) {
    messageHandler = handler
  }

  private func notifyStateChange() {
    let currentState = connectionState
    let stateObservers = stateObservers
    // Notify observers on the main thread
    for stateObserver in stateObservers {
      stateObserver(currentState, networkAvailable)
    }
  }

  private func notifyMessageReceived(_ message: ServerProtocolMessage) {
    lastMessageAt = Date()
    messageHandler?(message)
  }

  // MARK: - Connection Monitoring

  public func ensureConnected() async {
    log.trace("Ensuring connection is alive")

    switch connectionState {
      case .disconnected:
        // Re-attempt immediately after connection is established
        await connect()

      case .connected:
        // Verify the connection is actually alive with a ping. If the ping
        // fails we treat this as a genuine disconnect so that the normal
        // reconnection logic (with back-off etc.) can run.
        do {
          try await sendPing()
        } catch {
          log.trace("Ping failed, treating as disconnect…")
          await handleDisconnection(error: error, origin: .ensureConnected)
        }

      case .connecting:
        break
    }
  }

  // MARK: - Ping configuration

  // Ping every 5 s. With a 10 s timeout and one allowed miss, worst-case
  // detection time is ~25 s which is a good balance between responsiveness
  // and battery/network usage for a chat app.
  private let pingInterval: TimeInterval = 5.0
  // Allow one lost ping; reconnect after the second consecutive failure.
  private let maxConsecutivePingFailures = 2

  private func setupPingPong() {
    guard webSocketTask != nil else { return }

    pingPongTask?.cancel()
    pingPongTask = Task {
      var consecutiveFailures = 0

      while connectionState == .connected,
            running,
            !Task.isCancelled
      {
        do {
          try await Task.sleep(for: .seconds(pingInterval))
          try await sendPing()
          // Successfully got pong – reset counter.
          consecutiveFailures = 0

        } catch PingError.inProgress {
          // Another ping is still outstanding; don't treat as a failure.
          continue

        } catch {
          consecutiveFailures += 1
          addTransportBreadcrumb(
            "Ping failed",
            origin: .ping,
            level: consecutiveFailures >= maxConsecutivePingFailures ? .warning : .info,
            error: error,
            data: [
              "consecutive_failures": consecutiveFailures,
              "max_consecutive_failures": maxConsecutivePingFailures,
            ]
          )
          log.warning("Ping failed (\(consecutiveFailures)/2)")

          if consecutiveFailures >= maxConsecutivePingFailures {
            await handleDisconnection(error: error, origin: .ping)
            break
          }
        }
      }
    }
  }

  private enum PingError: Error {
    case inProgress
  }

  private func sendPing(fastTimeout: Bool = false) async throws {
    guard running else { return }
    guard let webSocketTask else { return }

    // Ensure we don't have more than one ping outstanding.
    if !pingInFlight.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged {
      // A ping is already in flight; let the existing timeout handle it.
      throw PingError.inProgress
    }

    defer { pingInFlight.store(false, ordering: .releasing) }

    // Select an appropriate timeout for this ping.
    let timeout = currentPingTimeout(fast: fastTimeout)

    try await withThrowingTaskGroup(of: Void.self) { group in
      let hasCompleted = ManagedAtomic<Bool>(false)

      // Timeout task
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        if hasCompleted.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
          throw TransportError.connectionTimeout
        }
      }

      // Actual ping task
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          webSocketTask.sendPing { error in
            if hasCompleted.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
              if let error {
                continuation.resume(throwing: error)
              } else {
                continuation.resume()
              }
            }
          }
        }
      }

      do {
        try await group.next()
        group.cancelAll()
        lastPingSuccessAt = Date()
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private let connectionTimeout: TimeInterval = 20.0

  private func setupConnectionTimeout(foregroundTransition: Bool = false) {
    connectionTimeoutTask?.cancel()
    connectionTimeoutTask = Task {
      let timeout = foregroundTransition ? 8.0 : (networkQualityIsLow ? connectionTimeout * 1.5 : connectionTimeout)

      try? await Task.sleep(for: .seconds(timeout))

      if self.connectionState == .connecting, !Task.isCancelled, running {
        self.addTransportBreadcrumb(
          "Connect timeout fired",
          origin: .connectTimeout,
          level: .warning,
          data: [
            "timeout_s": timeout,
          ]
        )
        self.log.warning("Connection timeout after \(timeout)s")

        // Create a new task to avoid potential deadlock
        Task {
          await handleDisconnection(
            error: TransportError.connectionTimeout,
            origin: .connectTimeout
          )
        }
      }
    }
  }

  func send(_ message: ClientMessage) async throws {
    guard connectionState == .connected else {
      throw TransportError.notConnected
    }
    guard let webSocketTask else {
      throw TransportError.notConnected
    }
    let wsMessage: URLSessionWebSocketTask.Message = try .data(message.serializedData())
    try await webSocketTask.send(wsMessage)
  }

  private func receiveMessages() async {
    log.trace("waiting for messages")
    guard let webSocketTask else { return }

    while running, connectionState == .connected, !Task.isCancelled {
      do {
        let message = try await webSocketTask.receive()
        log.trace("got message")
        switch message {
          case .string:
            // unsupported
            break

          case let .data(data):
            log.trace("got data message \(data.count) bytes")

            do {
              let message = try ServerProtocolMessage(serializedBytes: data)
              log.trace("decoded message \(message.id)")
              notifyMessageReceived(message)
            } catch {
              log.error("Invalid message format", error: error)
              // Consider custom recovery instead of disconnection
            }

          @unknown default:
            // unsupported
            break
        }
      } catch {
        if error is CancellationError { break }

        addTransportBreadcrumb("Receive failed", origin: .receive, level: .warning, error: error)
        log.warning("Error receiving messages")
        if running {
          await handleDisconnection(error: error, origin: .receive)
        }
      }
    }
  }

  private func cancelTasks() async {
    // Cancel all tasks first
    let tasks = [pingPongTask, msgTask, connectionTimeoutTask, reconnectionTask].compactMap { $0 }
    tasks.forEach { $0.cancel() }

    // Then nullify references
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    pingPongTask = nil
    msgTask = nil
    connectionTimeoutTask = nil
    reconnectionTask = nil
    scheduledReconnectDelay = nil
  }

  private func handleDisconnection(
    closeCode: URLSessionWebSocketTask.CloseCode? = nil,
    reason: Data? = nil,
    error: Error? = nil,
    origin: TransportOrigin = .didClose,
    httpStatus: Int? = nil
  ) async {
    let priorState = connectionState
    let priorTaskState = webSocketTask?.state

    // Proceed with cleanup regardless of the task's current state. URLSession
    // sometimes still reports `.running` when the connection is actually
    // defunct, so we avoid early-returning here.
    connectionState = .disconnected
    connectedAt = nil
    notifyStateChange()

    addTransportBreadcrumb(
      "Handling websocket disconnection",
      origin: origin,
      level: error == nil ? .info : .warning,
      error: error,
      closeCode: closeCode,
      httpStatus: httpStatus,
      data: [
        "reason_bytes": reason?.count ?? 0,
      ]
    )

    if let error {
      // Capture details for diagnostics. Avoid including secrets; URLs are ok.
      let nsError = error as NSError
      var details = "domain=\(nsError.domain) code=\(nsError.code)"
      details += " priorState=\(priorState) running=\(running) net=\(networkAvailable) bg=\(isInBackground)"
      if let priorTaskState {
        details += " wsTaskState=\(priorTaskState.rawValue)"
      }
      if let closeCode {
        details += " closeCode=\(closeCode.rawValue)"
      }
      if let reason {
        details += " reasonBytes=\(reason.count)"
      }
      if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
        details += " failingURL=\(failingURL.absoluteString)"
      } else if let failingURLString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
        details += " failingURL=\(failingURLString)"
      }
      if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
        details += " underlying=\(underlying.domain):\(underlying.code)"
      }
      // These keys are commonly present for URLSession / CFNetwork failures and
      // are crucial for decoding opaque NSURLErrorDomain codes.
      if let streamDomain = nsError.userInfo["_kCFStreamErrorDomainKey"] {
        details += " streamDomain=\(streamDomain)"
      }
      if let streamCode = nsError.userInfo["_kCFStreamErrorCodeKey"] {
        details += " streamCode=\(streamCode)"
      }
      if let failureReason = nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
        details += " failureReason=\(failureReason)"
      }
      if let recoverySuggestion = nsError.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String {
        details += " recoverySuggestion=\(recoverySuggestion)"
      }
      log.warning("Disconnected with error (\(details))")
      if shouldCaptureIssue(error: error, closeCode: closeCode, origin: origin) {
        await captureTransportIssue(
          message: "WebSocket disconnected with error",
          origin: origin,
          error: error,
          closeCode: closeCode,
          httpStatus: httpStatus,
          data: [
            "details": details,
          ]
        )
      }
    } else if shouldCaptureIssue(error: nil, closeCode: closeCode, origin: origin) {
      await captureTransportIssue(
        message: "WebSocket closed unexpectedly",
        origin: origin,
        closeCode: closeCode,
        httpStatus: httpStatus,
        data: [
          "reason_bytes": reason?.count ?? 0,
        ]
      )
    }

    if let closeCode {
      webSocketTask?.cancel(with: closeCode, reason: reason)
      webSocketTask = nil
    }

    await cancelTasks()

    if running {
      // Check if this is an error that warrants immediate retry
      let shouldRetryImmediately = shouldRetryImmediately(error: error)
      attemptReconnection(immediate: shouldRetryImmediately)
    }
  }

  private func shouldRetryImmediately(error: Error?) -> Bool {
    guard let error else { return false }

    // Network transition errors often resolve quickly
    if let nsError = error as NSError? {
      let networkTransitionCodes = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
      ]
      return networkTransitionCodes.contains(nsError.code)
    }

    return false
  }

  private func attemptReconnection(immediate: Bool = false) {
    guard running else { return }

    guard connectionState == .disconnected else {
      log.trace("Not scheduling reconnection because state is \(connectionState)")
      return
    }

    let delay: Double

    if immediate {
      // Immediate reconnection for foreground transitions
      delay = 0.1 // Small delay to avoid race conditions
    } else {
      // Exponential backoff for reconnection attempts
      reconnectionAttempts += 1
      let baseDelay = min(15.0, pow(1.5, Double(min(reconnectionAttempts, 5))))
      let jitter = Double.random(in: 0 ... 1.5)
      delay = baseDelay + jitter
    }

    if let existingDelay = scheduledReconnectDelay, reconnectionTask != nil {
      if immediate, delay < existingDelay {
        log.trace("Rescheduling reconnection earlier (old \(existingDelay)s, new \(delay)s)")
        reconnectionTask?.cancel()
        reconnectionTask = nil
        scheduledReconnectDelay = nil
      } else {
        log.trace("Reconnection already scheduled after \(existingDelay)s")
        return
      }
    }

    scheduledReconnectDelay = delay
    reconnectionToken = reconnectionToken &+ 1
    let token = reconnectionToken

    addTransportBreadcrumb(
      "Scheduling websocket reconnect",
      origin: .reconnectScheduled,
      data: [
        "immediate": immediate,
        "delay_s": delay,
      ]
    )
    log.trace("Scheduling reconnection after \(delay) seconds")

    reconnectionTask = Task { [token] in
      defer {
        reconnectionTaskFinished(token: token)
      }

      do {
        try await Task.sleep(for: .seconds(delay))
      } catch {
        return
      }

      if Task.isCancelled { return }

      if connectionState == .disconnected, running {
        await connect(foregroundTransition: immediate)
      }
    }
  }

  private func reconnectionTaskFinished(token: UInt64) {
    guard token == reconnectionToken else { return }
    reconnectionTask = nil
    scheduledReconnectDelay = nil
  }

  // MARK: - Helpers

  /// Calculates the timeout to use for a ping based on network path quality
  /// and whether this is a fast-probe (foreground transition) ping.
  private func currentPingTimeout(fast: Bool) -> TimeInterval {
    if fast { return 3.0 }
    return networkQualityIsLow ? pingTimeoutConstrained : pingTimeoutNormal
  }
}

// MARK: Network Connectivity

extension WebSocketTransport {
  private func setNetworkAvailable(_ available: Bool) async {
    guard networkAvailable != available else { return }
    networkAvailable = available
    lastNetworkChangeAt = Date()
    addTransportBreadcrumb(
      available ? "Network became available" : "Network became unavailable",
      origin: .networkPath,
      data: [
        "available": available,
      ]
    )

    if !available {
      log.trace("Network is unavailable")
      notifyStateChange()
    } else {
      log.trace("Network became available")
      await ensureConnected()
    }
  }

  private func setupNetworkMonitoring() {
    log.trace("Setting up network monitoring")
    pathMonitor = NWPathMonitor()
    pathMonitor?.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      if path.status == .satisfied {
        // Network became available
        Task {
          await self.setNetworkAvailable(true)
        }
      } else if path.status == .unsatisfied {
        // Network became unavailable
        Task {
          await self.setNetworkAvailable(false)
        }
      }
    }
    pathMonitor?.start(queue: DispatchQueue.global())
  }

  private func stopNetworkMonitoring() {
    pathMonitor?.cancel()
    pathMonitor = nil
  }
}

// MARK: - URLSessionWebSocketDelegate

extension WebSocketTransport: URLSessionWebSocketDelegate {
  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    Task { await self.handleConnectedIfCurrent(task: webSocketTask) }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    Task { await self.handleDisconnectionIfCurrent(task: webSocketTask, closeCode: closeCode, reason: reason) }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    // Ignore nil completion. We rely on didClose for clean shutdown and
    // explicit errors for failure cases. Treating nil as a disconnect can
    // create spurious reconnects and amplify race conditions.
    guard let error else { return }
    let httpStatus = (task.response as? HTTPURLResponse)?.statusCode
    Task { await self.handleCompletionIfCurrent(task: task, error: error, httpStatus: httpStatus) }
  }
}

// MARK: - Delegate Filtering (stale callback protection)

extension WebSocketTransport {
  private func handleConnectedIfCurrent(task: URLSessionWebSocketTask) async {
    guard let current = webSocketTask, current === task else {
      log.trace("Ignoring didOpen for stale WebSocket task")
      return
    }
    handleConnected()
  }

  private func handleDisconnectionIfCurrent(
    task: URLSessionWebSocketTask,
    closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) async {
    guard let current = webSocketTask, current === task else {
      log.trace("Ignoring didClose for stale WebSocket task")
      return
    }
    await handleDisconnection(closeCode: closeCode, reason: reason, origin: .didClose)
  }

  private func handleCompletionIfCurrent(task: URLSessionTask, error: Error, httpStatus: Int?) async {
    // URLSession delivers completion for URLSessionTask; ensure it matches the
    // current WebSocket task before mutating state.
    guard let current = webSocketTask, current === task else {
      log.trace("Ignoring didCompleteWithError for stale WebSocket task")
      return
    }
    addTransportBreadcrumb(
      "WebSocket task completed with error",
      origin: .didComplete,
      level: .warning,
      error: error,
      httpStatus: httpStatus
    )
    await handleDisconnection(error: error, origin: .didComplete, httpStatus: httpStatus)
  }
}

private extension WebSocketTransport {
  func addTransportBreadcrumb(
    _ message: String,
    origin: TransportOrigin,
    level: SentryLevel = .info,
    error: Error? = nil,
    closeCode: URLSessionWebSocketTask.CloseCode? = nil,
    httpStatus: Int? = nil,
    data: [String: Any] = [:]
  ) {
    let crumb = Breadcrumb(level: level, category: "realtime.transport")
    crumb.message = message
    crumb.data = sentryData(
      origin: origin,
      error: error,
      closeCode: closeCode,
      httpStatus: httpStatus,
      data: data
    )
    SentrySDK.addBreadcrumb(crumb)
  }

  func captureTransportIssue(
    message: String,
    origin: TransportOrigin,
    error: Error? = nil,
    closeCode: URLSessionWebSocketTask.CloseCode? = nil,
    httpStatus: Int? = nil,
    data: [String: Any] = [:]
  ) async {
    let sentryData = sentryData(
      origin: origin,
      error: error,
      closeCode: closeCode,
      httpStatus: httpStatus,
      data: data
    )
    let tags = sentryTags(origin: origin, error: error, closeCode: closeCode)
    let fingerprint = sentryFingerprint(origin: origin, error: error, closeCode: closeCode, httpStatus: httpStatus)

    if let error {
      _ = SentrySDK.capture(error: error) { scope in
        scope.setLevel(.error)
        scope.setFingerprint(fingerprint)
        tags.forEach { scope.setTag(value: $1, key: $0) }
        sentryData.forEach { scope.setExtra(value: $1, key: $0) }
        scope.setExtra(value: message, key: "message")
      }
    } else {
      _ = SentrySDK.capture(message: message) { scope in
        scope.setLevel(.warning)
        scope.setFingerprint(fingerprint)
        tags.forEach { scope.setTag(value: $1, key: $0) }
        sentryData.forEach { scope.setExtra(value: $1, key: $0) }
      }
    }
  }

  func shouldCaptureIssue(
    error: Error?,
    closeCode: URLSessionWebSocketTask.CloseCode?,
    origin: TransportOrigin
  ) -> Bool {
    if let error {
      if case TransportError.connectionTimeout = error {
        return true
      }

      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
          case NSURLErrorCancelled,
            NSURLErrorTimedOut,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorSecureConnectionFailed,
            NSURLErrorNetworkConnectionLost:
            return false
          default:
            return true
        }
      }

      return true
    }

    guard origin == .didClose, let closeCode else { return false }
    return closeCode != .normalClosure && closeCode != .goingAway
  }

  func sentryTags(
    origin: TransportOrigin,
    error: Error?,
    closeCode: URLSessionWebSocketTask.CloseCode?
  ) -> [String: String] {
    var tags: [String: String] = [
      "scope": "Realtime_TransportWS",
      "ws_origin": origin.rawValue,
      "transport_state": connectionState.sentryValue,
      "network_available": networkAvailable ? "true" : "false",
      "in_background": isInBackground ? "true" : "false",
    ]

    if let pathMonitor {
      let path = pathMonitor.currentPath
      tags["nw_path_status"] = switch path.status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requires_connection"
        @unknown default: "unknown"
      }
    }

    if let closeCode {
      tags["ws_close_code"] = String(closeCode.rawValue)
    }

    if let (kind, _, _) = errorDescriptor(error) {
      tags["ws_error_kind"] = kind
    }

    return tags
  }

  func sentryFingerprint(
    origin: TransportOrigin,
    error: Error?,
    closeCode: URLSessionWebSocketTask.CloseCode?,
    httpStatus: Int?
  ) -> [String] {
    var fingerprint = ["realtime-transport", origin.rawValue]

    if let (kind, domain, code) = errorDescriptor(error) {
      fingerprint.append(kind)
      fingerprint.append(domain)
      fingerprint.append(code)
    } else if let closeCode {
      fingerprint.append("close")
      fingerprint.append(String(closeCode.rawValue))
    }

    if let httpStatus, httpStatus != 101 {
      fingerprint.append("http")
      fingerprint.append(String(httpStatus))
    }

    return fingerprint
  }

  func sentryData(
    origin: TransportOrigin,
    error: Error? = nil,
    closeCode: URLSessionWebSocketTask.CloseCode? = nil,
    httpStatus: Int? = nil,
    data extra: [String: Any] = [:]
  ) -> [String: Any] {
    var data: [String: Any] = [
      "ws_origin": origin.rawValue,
      "transport_state": connectionState.sentryValue,
      "running": running,
      "network_available": networkAvailable,
      "in_background": isInBackground,
      "reconnect_attempt": reconnectionAttempts,
      "ping_in_flight": pingInFlight.load(ordering: .relaxed),
      "request_timeout_s": 30,
      "url": urlString,
    ]

    if let scheduledReconnectDelay {
      data["scheduled_reconnect_delay_s"] = scheduledReconnectDelay
    }

    if let pathMonitor {
      let path = pathMonitor.currentPath
      data["nw_path_status"] = switch path.status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requires_connection"
        @unknown default: "unknown"
      }
      data["nw_path_expensive"] = path.isExpensive
      data["nw_path_constrained"] = path.isConstrained
    }

    if let closeCode {
      data["ws_close_code"] = closeCode.rawValue
    }

    if let httpStatus {
      data["http_status"] = httpStatus
    }

    if let connectStartedAt {
      data["since_connect_start_s"] = Date().timeIntervalSince(connectStartedAt)
    }
    if let connectedAt {
      data["since_connected_s"] = Date().timeIntervalSince(connectedAt)
    }
    if let lastMessageAt {
      data["since_last_message_s"] = Date().timeIntervalSince(lastMessageAt)
    }
    if let lastPingSuccessAt {
      data["since_last_ping_ok_s"] = Date().timeIntervalSince(lastPingSuccessAt)
    }
    if let lastNetworkChangeAt {
      data["since_last_network_change_s"] = Date().timeIntervalSince(lastNetworkChangeAt)
    }

    if let (kind, domain, code) = errorDescriptor(error) {
      data["ws_error_kind"] = kind
      data["error_domain"] = domain
      data["error_code"] = code
    }

    extra.forEach { data[$0.key] = $0.value }
    return data
  }

  func errorDescriptor(_ error: Error?) -> (kind: String, domain: String, code: String)? {
    guard let error else { return nil }

    if let error = error as? TransportError {
      switch error {
        case .connectionTimeout:
          return ("transport", "TransportError", "connectionTimeout")
        case .notConnected:
          return ("transport", "TransportError", "notConnected")
        case .invalidURL:
          return ("transport", "TransportError", "invalidURL")
        case .invalidResponse:
          return ("transport", "TransportError", "invalidResponse")
        case .invalidData:
          return ("transport", "TransportError", "invalidData")
        case let .connectionError(inner):
          let nsError = inner as NSError
          return ("transport_wrapped", nsError.domain, String(nsError.code))
        case .unknown:
          return ("transport", "TransportError", "unknown")
      }
    }

    let nsError = error as NSError
    return ("nserror", nsError.domain, String(nsError.code))
  }
}
