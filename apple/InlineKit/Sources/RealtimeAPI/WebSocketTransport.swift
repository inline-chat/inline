import Atomics
import Foundation
import InlineConfig
import InlineProtocol
import Logger
import Network

#if canImport(UIKit)
import UIKit
#endif

enum TransportConnectionState {
  case disconnected
  case connecting
  case connected
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
  private var log = Log.scoped("Realtime_TransportWS", enableTracing: true)
  private var pathMonitor: NWPathMonitor?
  private let reconnectionInProgress = ManagedAtomic<Bool>(false)

  override init() {
    log.debug("Initializing WebSocketTransport")
    // Create session configuration
    let configuration = URLSessionConfiguration.default
    configuration.shouldUseExtendedBackgroundIdleMode = true
    configuration.timeoutIntervalForResource = 300
    configuration.timeoutIntervalForRequest = 30
    configuration.waitsForConnectivity = false // Don't wait, try immediately
    configuration.httpMaximumConnectionsPerHost = 1 // Allow multiple connections
    configuration.allowsCellularAccess = true
    configuration.isDiscretionary = false // Immediate connection attempt
    configuration.networkServiceType = .responsiveData // For real-time priority

    // Set TCP options for faster connection establishment
    configuration.connectionProxyDictionary = [
      kCFNetworkProxiesHTTPEnable: false,
      kCFStreamPropertyShouldCloseNativeSocket: true,
    ]
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv12

    session = nil

    super.init()

    // Initialize session with self as delegate
    session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: nil // Using nil lets URLSession create its own queue
    )
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
      log.debug("Disconnecting due to extended background time")
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
    Task {
      await UIApplication.shared.endBackgroundTask(backgroundTask)
    }
    backgroundTask = .invalid
  }

  private func cleanupBackgroundResources() async {
    // Only disconnect if we've been in background for more than 30 seconds
    if connectionState == .connected {
      log.debug("Disconnecting due to extended background time")
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
    // Update state
    connectionState = .connected
    notifyStateChange()

    setupPingPong()

    reconnectionAttempts = 0

    msgTask = Task {
      log.debug("starting message receiving")
      await receiveMessages()
    }
  }

  func start() async {
    guard !running else {
      log.trace("Already running")
      return
    }

    log.debug("Starting to run")
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

    // Cancel existing tasks before changing state
    await cancelTasks()

    // Double-check state after task cancellation
    if connectionState != .disconnected {
      log.trace("State changed during task cancellation")
      return
    }

    // Now update state
    connectionState = .connecting
    notifyStateChange()

    setupConnectionTimeout(foregroundTransition: foregroundTransition)

    let url = URL(string: urlString)!
    log.debug("connecting to \(urlString)")
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

    // Clear reconnection state
    reconnectionInProgress.store(false, ordering: .releasing)

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

    log.debug("Transport stopped completely")
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
        // TODO: Fix this BS
        // Verify the connection is actually alive with a ping
        do {
          try await sendPing()
        } catch {
          log.trace("Ping failed, reconnecting...")
          await connect()
        }

      case .connecting:
        break
    }
  }

  private let pingInterval: TimeInterval = 10.0
  private let pingTimeout: TimeInterval = 8.0
  private let maxConsecutivePingFailures = 3

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
          consecutiveFailures = 0
        } catch {
          consecutiveFailures += 1
          log.error("Ping failed (\(consecutiveFailures)/3)", error: error)

          if consecutiveFailures >= maxConsecutivePingFailures {
            await handleDisconnection(error: error)
            break
          }
        }
      }
    }
  }

  private func sendPing(fastTimeout: Bool = false) async throws {
    guard running else { return }
    guard let webSocketTask else { return }

    try await withThrowingTaskGroup(of: Void.self) { group in

      let hasCompleted = ManagedAtomic<Bool>(false)

      // Add timeout task
      group.addTask {
        try await Task.sleep(for: .seconds(fastTimeout ? 2.0 : self.pingTimeout)) // 5 seconds timeout for ping
        if hasCompleted.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
          throw TransportError.connectionTimeout
        }
      }

      // Add ping task
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
        // Wait for first completion (success or failure)
        try await group.next()
        group.cancelAll()
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
        log.error("Connection timeout after \(timeout)s")

        // Create a new task to avoid potential deadlock
        Task {
          await handleDisconnection()
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
    log.debug("waiting for messages")
    guard let webSocketTask else { return }

    while running, connectionState == .connected, !Task.isCancelled {
      do {
        let message = try await webSocketTask.receive()
        log.debug("got message")
        switch message {
          case .string:
            // unsupported
            break
          case let .data(data):
            log.debug("got data message \(data.count) bytes")

            do {
              let message = try ServerProtocolMessage(serializedBytes: data)
              log.debug("decoded message \(message.id)")
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

        log.error("Error receiving messages", error: error)
        if running {
          await handleDisconnection()
        }
      }
    }
  }

  private func cancelTasks() async {
    // Cancel all tasks first
    let tasks = [pingPongTask, msgTask, connectionTimeoutTask].compactMap { $0 }
    tasks.forEach { $0.cancel() }

    // Then nullify references
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    pingPongTask = nil
    msgTask = nil
    connectionTimeoutTask = nil
  }

  private func handleDisconnection(
    closeCode: URLSessionWebSocketTask.CloseCode? = nil,
    reason: Data? = nil,
    error: Error? = nil
  ) async {
    if webSocketTask?.state == .running {
      log.debug("WebSocket disconnect was stale")
      return
    }
    
    connectionState = .disconnected
    notifyStateChange()

    if let error {
      log.error("Disconnected with error", error: error)
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

    // Atomic check and set for reconnection state
    guard reconnectionInProgress.compareExchange(
      expected: false,
      desired: true,
      ordering: .acquiring
    ).exchanged else {
      log.trace("Reconnection already in progress")
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

    log.trace("Attempting reconnection after \(delay) seconds")

    // Task is important here
    Task {
      defer {
        reconnectionInProgress.store(false, ordering: .releasing)
      }

      do {
        // try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try await Task.sleep(for: .seconds(delay))

        if Task.isCancelled {
          return
        }

        // if still needed
        if connectionState == .disconnected, running {
          await connect(foregroundTransition: immediate)
        }
      } catch {
        log.error("Reconnection attempt failed", error: error)
        await handleDisconnection(error: error)
      }
    }
  }
}

// MARK: Network Connectivity

extension WebSocketTransport {
  private func setNetworkAvailable(_ available: Bool) async {
    guard networkAvailable != available else { return }
    networkAvailable = available

    if !available {
      log.trace("Network is unavailable")
      await cancelTasks()
      connectionState = .disconnected
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
    Task { await handleConnected() }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    Task { await handleDisconnection(closeCode: closeCode, reason: reason) }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    Task { await handleDisconnection(error: error) }
  }
}
