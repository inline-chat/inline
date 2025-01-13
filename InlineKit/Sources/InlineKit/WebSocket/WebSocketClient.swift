import Atomics
import Foundation
import Network

#if canImport(UIKit)
import UIKit
#endif

enum WebSocketMessage: Sendable {
  case string(String)
  case data(Data)
}

enum WebSocketError: Error, Sendable {
  case disconnected
  case invalidMessage
  case connectionTimeout
}

enum WebSocketConnectionState: Sendable {
  case disconnected
  case connecting
  case connected
}

struct WebSocketCredentials: Sendable {
  let token: String
  let userId: Int64
}

actor WebSocketClient: NSObject, Sendable, URLSessionWebSocketDelegate {
  // As long as `isActive` is true, we retry
  private var isActive = false
  
  // TBD
  private var inBackground = false
  
  // Tasks
  private var webSocketTask: URLSessionWebSocketTask?
  private var pingPongTask: Task<Void, Never>? = nil
  private var msgTask: Task<Void, Never>? = nil
  private var connectionTimeoutTask: Task<Void, Never>? = nil
  
  // State
  private var id = UUID()
  private var connectionState: WebSocketConnectionState = .disconnected {
    didSet {
      log.debug("State changed to \(connectionState) (id: \(id))")
    }
  }

  private var networkAvailable = true
  
  private var reconnectAttempts = 0
  
  // Configuration
  private let url: URL
  private var session: URLSession?
  private let credentials: WebSocketCredentials
  
  // Internals
  private var stateObservers: [(WebSocketConnectionState) -> Void] = []
  private var messageHandler: ((WebSocketMessage) -> Void)? = nil
  private var log = Log.scoped("WebsocketClient")
  private var pathMonitor: NWPathMonitor?
  
  init(
    url: URL,
    credentials: WebSocketCredentials
  ) {
    self.url = url
    self.credentials = credentials
    
    // Create session configuration
    let configuration = URLSessionConfiguration.default
    configuration.shouldUseExtendedBackgroundIdleMode = true
    // configuration.waitsForConnectivity = true
    // configuration.timeoutIntervalForResource = 300 // 5 minutes
    
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
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
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
    isActive = false
    webSocketTask?.cancel()
    
    Task { @MainActor [self] in
      await self.stop()
    }
  }
  
  var state: WebSocketConnectionState {
    connectionState
  }
  
  // MARK: - Connection Management
  
  private func handleConnected() {
    // Reset state
    reconnectAttempts = 0
    
    // Update state
    connectionState = .connected
    notifyStateChange()
    
    setupPingPong()
    
    // TODO: handle error
    Task {
      log.debug("Sending connection init")
      do {
        try await self.send(
          .connectionInit(token: self.credentials.token, userId: self.credentials.userId)
        )
      } catch {
        log.error("Failed to send connection init", error: error)
        await handleDisconnection(error: error)
      }
    }
    
    msgTask = Task {
      log.debug("Starting message receiving")
      await receiveMessages()
    }
  }
  
//  private var isConnecting = false

  func start() async {
    guard !isActive else {
      log.debug("Already started")
      return
    }
      
    isActive = true
    
    setupNetworkMonitoring()
    startBackgroundObservers()
    
    await connect()
  }
  
  func connect() async {
    // Add this guard to prevent connecting if already connected
    guard connectionState == .disconnected else {
      log.debug("Already connected or connecting")
      return
    }

    await cancelTasks()
  
    connectionState = .connecting
    notifyStateChange()
    
    setupConnectionTimeout()
    webSocketTask = session!.webSocketTask(with: url)
    webSocketTask?.resume()
  }
  
  func stop() async {
    log.debug("Disconnecting and stopping (manual)")
    isActive = false
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    
    connectionState = .disconnected
    notifyStateChange()
  }
  
  // MARK: - State Management
  
  func addStateObserver(_ observer: @escaping @Sendable (WebSocketConnectionState) -> Void) {
    stateObservers.append(observer)
    // Immediately notify of current state
    observer(connectionState)
  }
  
  func addMessageHandler(_ handler: @escaping @Sendable (WebSocketMessage) -> Void) {
    messageHandler = handler
  }
  
  private func notifyStateChange() {
    let currentState = connectionState
    let stateObservers = self.stateObservers
    // Notify observers on the main thread
    for stateObserver in stateObservers {
      stateObserver(currentState)
    }
  }
  
  private func notifyMessageReceived(_ message: WebSocketMessage) {
    messageHandler?(message)
  }
  
  // MARK: - Connection Monitoring
  
  public func ensureConnected() async {
    log.debug("Ensuring connection is alive")

    switch connectionState {
    case .disconnected:
      // Re-attempt immediately after connection is established
      await connect()

    case .connected:
      // Verify the connection is actually alive with a ping
      do {
        try await sendPing()
      } catch {
        log.debug("Ping failed, reconnecting...")
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
      
      while connectionState == .connected &&
        isActive &&
        !Task.isCancelled
      {
        do {
          try await Task.sleep(for: .seconds(10))
          log.debug("Sending ping \(id)")
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
    guard let task = webSocketTask else {
      throw WebSocketError.disconnected
    }
    
    guard isActive else { return }
    
    try await withThrowingTaskGroup(of: Void.self) { group in
      // Add timeout task
      group.addTask {
        try await Task.sleep(for: .seconds(5)) // 5 seconds timeout for ping
        throw WebSocketError.connectionTimeout
      }
      
      // Add ping task
      group.addTask {
        try await withCheckedThrowingContinuation { continuation in
          task.sendPing { error in
            if let error = error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume()
            }
          }
        }
      }
      
      // Wait for first completion (success or failure)
      try await group.next()
      
      // Cancel any remaining tasks
      group.cancelAll()
    }
  }

  private func setupConnectionTimeout() {
    connectionTimeoutTask?.cancel()
    connectionTimeoutTask = Task {
      try? await Task.sleep(for: .seconds(10))
      if self.connectionState == .connecting && !Task.isCancelled && isActive {
        log.error("Connection timeout after 10s")
        await handleDisconnection(error: WebSocketError.connectionTimeout)
      }
    }
  }

  func send(_ message: WebSocketMessage) async throws {
    guard connectionState == .connected, let webSocketTask else {
      throw WebSocketError.disconnected
    }
    
    let wsMessage: URLSessionWebSocketTask.Message
    switch message {
    case .string(let text):
      wsMessage = .string(text)
    case .data(let data):
      wsMessage = .data(data)
    }
    
    try await webSocketTask.send(wsMessage)
  }
  
  private func receiveMessages() async {
    guard let webSocketTask else { return }
    
    do {
      while isActive, connectionState == .connected, !Task.isCancelled {
        let message = try await webSocketTask.receive()
        
        switch message {
        case .string(let text):
          notifyMessageReceived(.string(text))
        case .data(let data):
          notifyMessageReceived(.data(data))
        @unknown default:
          throw WebSocketError.invalidMessage
        }
      }
    } catch {
      if isActive {
        await handleDisconnection()
      }
    }
  }
  
  private func cancelTasks() async {
    // Cancel all tasks first
    let tasks = [pingPongTask, msgTask].compactMap { $0 }
    tasks.forEach { $0.cancel() }
    
    // Wait for all tasks to complete
//    for task in tasks {
//      let _ = await task.value
//    }
    
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
    
    if let error = error {
      log.error("Disconnected with error", error: error)
    }
    
    if let closeCode = closeCode {
      webSocketTask?.cancel(with: closeCode, reason: reason)
      webSocketTask = nil
    }
    
    await cancelTasks()
    
    if isActive {
      attemptReconnection()
    }
  }
  
  private let reconnectionInProgress = ManagedAtomic<Bool>(false)
  
  private func attemptReconnection() {
    guard isActive else { return }
    
    // Atomic check and set for reconnection state
    guard reconnectionInProgress.compareExchange(
      expected: false,
      desired: true,
      ordering: .acquiring
    ).exchanged else {
      log.debug("Reconnection already in progress")
      return
    }

    reconnectAttempts += 1
    let backoff = 1.2
    let jitter = Double.random(in: 0 ... 0.3)
    let delay = min(backoff * TimeInterval(reconnectAttempts), 24) + jitter
    
    log.debug("Attempting reconnection after \(delay) seconds, attempt \(reconnectAttempts)")
    
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
        if connectionState == .disconnected && isActive {
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

extension WebSocketClient {
  private func setNetworkAvailable(_ networkAvailable: Bool) async {
    if networkAvailable {
      log.debug("Network became available")
      self.networkAvailable = networkAvailable
      
      // Side-effect
      await ensureConnected()
    } else {
      log.debug("Network is unavailable")
      self.networkAvailable = networkAvailable
    }
  }
  
  private func setupNetworkMonitoring() {
    log.debug("Setting up network monitoring")
    pathMonitor = NWPathMonitor()
    pathMonitor?.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
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

extension WebSocketClient {
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

// MARK: - Convenience Methods

extension WebSocketClient {
  private func send(text: String) async throws {
    try await send(.string(text))
  }
  
  private func send(data: Data) async throws {
    try await send(.data(data))
  }
  
  func send<T: Codable>(_ message: ClientMessage<T>) async throws {
    //    log.debug("sending message \(message)")
    
    let encoder = JSONEncoder()
    // Configure encoder for better JSON formatting
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    
    do {
      let jsonData = try encoder.encode(message)
      // Convert JSON data to string for WebSocket text frame
      if let jsonString = String(data: jsonData, encoding: .utf8) {
        try await send(.string(jsonString))
      } else {
        throw INWebSocketError.encodingFailed
      }
    } catch {
      throw INWebSocketError.encodingFailed
    }
  }
}
