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

  // Add background handling methods
  #if os(iOS)
  // Add these properties at the top with other properties
  private var isInBackground = false

  private func setIsInBackground(_ isInBackground: Bool) {
    self.isInBackground = isInBackground
  }

  // Update background handling to be more robust
  @objc private nonisolated func handleAppDidEnterBackground() {
    Task {
      await self.setIsInBackground(true)
    }
  }

  @objc private nonisolated func handleAppWillEnterForeground() {
    Task {
      await self.setIsInBackground(false)

      // Check connection and reconnect if needed
      await ensureConnected()
    }
  }
  #endif

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

  func connect() async {
    // Add this guard to prevent connecting if already connected
    guard connectionState == .disconnected else {
      log.trace("Already connected or connecting")
      return
    }

    connectionState = .connecting
    notifyStateChange()

    await cancelTasks()

    setupConnectionTimeout()
    let url = URL(string: urlString)!
    log.debug("connecting to \(urlString)")
    webSocketTask = session!.webSocketTask(with: url)
    webSocketTask?.resume()
    log.debug("connecting to \(urlString)")
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
    pathMonitor?.cancel()
    pathMonitor = nil

    // Clear state
    connectionState = .disconnected
    stateObservers = []
    messageHandler = nil

    // Notify state change as final action
    notifyStateChange()

    log.debug("Transport stopped completely")
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
          try await Task.sleep(for: .seconds(10))
          try await sendPing()
          consecutiveFailures = 0
        } catch {
          consecutiveFailures += 1
          log.error("Ping failed (\(consecutiveFailures)/3)", error: error)

          if consecutiveFailures >= 2 {
            await handleDisconnection(error: error)
            break
          }
        }
      }
    }
  }

  private func sendPing() async throws {
    guard running else { return }
    guard let webSocketTask else { return }

    try await withThrowingTaskGroup(of: Void.self) { group in

      let hasCompleted = ManagedAtomic<Bool>(false)

      // Add timeout task
      group.addTask {
        try await Task.sleep(for: .seconds(5)) // 5 seconds timeout for ping
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

  private func setupConnectionTimeout() {
    connectionTimeoutTask?.cancel()
    connectionTimeoutTask = Task {
      try? await Task.sleep(for: .seconds(20))
      if self.connectionState == .connecting, !Task.isCancelled, running {
        log.error("Connection timeout after 20s")
        await handleDisconnection()
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

    do {
      while running, connectionState == .connected, !Task.isCancelled {
        let message = try await webSocketTask.receive()
        log.debug("got message")
        switch message {
          case .string:
            // unsupported
            break
          case let .data(data):
            log.debug("got data message \(data.count) bytes")

            let message = try ServerProtocolMessage(serializedBytes: data)
            log.debug("decoded message \(message.id)")
            notifyMessageReceived(message)
          @unknown default:
            // unsupported
            break
        }
      }
    } catch {
      log.error("Error receiving messages", error: error)
      if running {
        await handleDisconnection()
      }
    }
  }

  private func cancelTasks() async {
    // Cancel all tasks first
    let tasks = [pingPongTask, msgTask].compactMap { $0 }
    tasks.forEach { $0.cancel() }

    // Then nullify references
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    pingPongTask = nil
    msgTask = nil
  }

  private func handleDisconnection(
    closeCode: URLSessionWebSocketTask.CloseCode? = nil,
    reason: Data? = nil,
    error: Error? = nil
  ) async {
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
      attemptReconnection()
    }
  }

  private func attemptReconnection() {
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

    let jitter = Double.random(in: 0 ... 3)
    let delay = 5.0 + jitter

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
          await connect()
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
  private func setNetworkAvailable(_ networkAvailable: Bool) async {
    if networkAvailable {
      log.trace("Network became available")
      self.networkAvailable = networkAvailable

      // Side-effect
      await ensureConnected()
    } else {
      log.trace("Network is unavailable")
      self.networkAvailable = networkAvailable
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
