import Foundation

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
  private var webSocketTask: URLSessionWebSocketTask?
  private var pingPongTask: Task<Void, Never>? = nil
  private var msgTask: Task<Void, Never>? = nil
  private var connectionState: WebSocketConnectionState = .disconnected
  private var reconnectAttempts = 0
  private var isActive = true
  private var id = UUID()
  
  // Connection metrics
  private var lastConnectedAt: Date?
  private var lastDisconnectedAt: Date?
  
  private let url: URL
  private var session: URLSession?
  private let credentials: WebSocketCredentials
  
  private var stateObservers: [(WebSocketConnectionState) -> Void] = []
  private var messageHandler: ((WebSocketMessage) -> Void)? = nil
  
  private var log = Log.scoped("WebsocketClient")
  
  init(
    url: URL,
    credentials: WebSocketCredentials
  ) {
    self.url = url
    self.credentials = credentials
    
    // Create session configuration
    let configuration = URLSessionConfiguration.default
    configuration.shouldUseExtendedBackgroundIdleMode = true
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForResource = 300 // 5 minutes
    
    session = nil
    
    super.init()
    
    // Initialize session with self as delegate
    session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: nil // Using nil lets URLSession create its own queue
    )
    
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
  
  // Update background handling to be more robust
  @objc private nonisolated func handleAppDidEnterBackground() {
    Task { @MainActor in
      self.isInBackground = true
      self.backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
        self?.endBackgroundTask()
      }
      // Force a ping when entering background
      try? await self.sendPing()
    }
  }
  
  @objc private nonisolated func handleAppWillEnterForeground() {
    Task { @MainActor in
      self.isInBackground = false
      self.endBackgroundTask()
      
      // Check connection and reconnect if needed
      if self.connectionState != .connected {
        do {
          try await self.connect()
        } catch {
          log.error("Failed to reconnect on foreground", error: error)
        }
      } else {
        // Force a ping to verify connection
        try? await self.sendPing()
      }
    }
  }
  
  private func endBackgroundTask() {
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }
#endif
  
  deinit {
    isActive = false
    webSocketTask?.cancel()
    
    Task { @MainActor [self] in
      await self.handleDisconnection()
    }
  }
  
  // MARK: - URLSessionWebSocketDelegate
  
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
  
  var state: WebSocketConnectionState {
    connectionState
  }
  
  // MARK: - Connection Management
  
  private func handleConnected() {
    connectionState = .connected
    reconnectAttempts = 0
    notifyStateChange()
    
    setupPingPong()
    
    // TODO: handle error
    Task {
      Log.shared.debug("Sending connection init")
      do {
        try await self.send(
          .connectionInit(token: self.credentials.token, userId: self.credentials.userId)
        )
      } catch {
        Log.shared.error("Failed to send connection init", error: error)
      }
    }
    
    msgTask = Task {
      await receiveMessages()
    }
  }
  
  func connect() async throws {
    // Add this guard to prevent connecting if already connected
    guard connectionState == .disconnected else {
      log.debug("Already connected or connecting")
      return
    }
    
    cancelTasks()
    
    isActive = true
    connectionState = .connecting
    notifyStateChange()
    
    webSocketTask = session!.webSocketTask(with: url)
    setupConnectionTimeout()
    webSocketTask?.resume()
  }
  
  func disconnect() async {
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
  
  public func ensureConnected() {
    log.debug("Ensuring connection is alive")
    Task {
      switch connectionState {
      case .disconnected:
        // Definitely need to reconnect
        do {
          try await connect()
        } catch {
          log.error("Failed to establish connection", error: error)
        }
        
      case .connected:
        // Verify the connection is actually alive with a ping
        do {
          try await sendPing()
        } catch {
          log.debug("Ping failed, reconnecting...")
          do {
            try await connect()
          } catch {
            log.error("Failed to establish connection", error: error)
          }
        }
        
      case .connecting:
        // Already attempting to connect, let it finish
        break
      }
    }
  }
  
  private func setupPingPong() {
    guard webSocketTask != nil else { return }
    
    pingPongTask?.cancel()
    pingPongTask = Task {
      while connectionState == .connected && isActive && Task.isCancelled == false {
        do {
          try await Task.sleep(for: .seconds(10))
          log.debug("Sending ping \(id)")
          try await sendPing()
        } catch {
          log.error("Ping failed", error: error)
          await handleDisconnection(error: error)
          break
        }
      }
    }
  }
  
  private func sendPing() async throws {
    return try await withCheckedThrowingContinuation { continuation in
      webSocketTask?.sendPing { error in
        if let error = error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
  
  private func setupConnectionTimeout() {
    Task {
      try? await Task.sleep(for: .seconds(14))
      if self.connectionState == .connecting {
        log.error("Connection timeout")
        await handleDisconnection(error: WebSocketError.connectionTimeout)
      }
    }
  }
  
  // Add connection quality monitoring
  private func monitorConnectionQuality() {
    //        Task {
    //            var failedPings = 0
    //            while connectionState == .connected && isActive {
    //                do {
    //                    let start = Date()
    //                    try await webSocketTask?.sendPing()
    //                    let latency = Date().timeIntervalSince(start)
    //                    failedPings = 0
    //                    // Log or report latency
    //                } catch {
    //                    failedPings += 1
    //                    if failedPings >= 3 {
    //                        await handleDisconnection(error: WebSocketError.poorConnection)
    //                        break
    //                    }
    //                }
    //                try await Task.sleep(for: .seconds(5))
    //            }
    //        }
  }
  
  // Rest of the implementation..
  
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
  
  private func cancelTasks() {
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    
    pingPongTask?.cancel()
    pingPongTask = nil
    
    msgTask?.cancel()
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
    
    cancelTasks()
    
    if isActive {
      await attemptReconnection()
    }
  }
  
  private var reconnectionInProgress = false
  
  private func attemptReconnection() async {
    guard isActive else { return }
    guard !reconnectionInProgress else {
      return
    }
    
    reconnectAttempts += 1
    let backoff = 1.2
    let jitter = Double.random(in: 0 ... 0.3)
    let delay = min(backoff * TimeInterval(reconnectAttempts), 24) + jitter
    
    log.debug("Attempting reconnection after \(delay) seconds, attempt \(reconnectAttempts)")
    
    reconnectionInProgress = true
    // Task is important here
    Task {
      do {
        // try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try await Task.sleep(for: .seconds(delay))
        
        // if still needed
        if connectionState == .disconnected && isActive {
          try await connect()
        }
        reconnectionInProgress = false
        
      } catch {
        log.error("Reconnection attempt failed", error: error)
        reconnectionInProgress = false
        await handleDisconnection(error: error)
      }
    }
  }
}

// MARK: - Convenience Methods

extension WebSocketClient {
  func send(text: String) async throws {
    try await send(.string(text))
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
  
  func send(data: Data) async throws {
    try await send(.data(data))
  }
}
