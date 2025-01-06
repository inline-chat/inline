import Foundation

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

struct ReconnectionConfig: Sendable {
  let maxAttempts: Int
  let backoff: TimeInterval

  static let `default` = ReconnectionConfig(maxAttempts: 5, backoff: 1.5)
  static let none = ReconnectionConfig(maxAttempts: 0, backoff: 0)
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
  private let reconnectionConfig: ReconnectionConfig
  private let credentials: WebSocketCredentials

  private var stateObservers: [(WebSocketConnectionState) -> Void] = []
  private var messageHandler: ((WebSocketMessage) -> Void)? = nil

  private var log = Log.scoped("WebsocketClient")

  init(
    url: URL,
    reconnectionConfig: ReconnectionConfig = .default,
    credentials: WebSocketCredentials
  ) {
    self.url = url
    self.reconnectionConfig = reconnectionConfig
    self.credentials = credentials

    // Create session configuration
    let configuration = URLSessionConfiguration.default

    session = nil

    super.init()

    // Initialize session with self as delegate
    session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: nil // Using nil lets URLSession create its own queue
    )
  }

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

    // TODO: handle error
    self.msgTask = Task {
      setupPingPong()
      try? await self.send(
        .connectionInit(token: self.credentials.token, userId: self.credentials.userId)
      )

      await receiveMessages()
    }
  }

  private func handleDisconnection(
    closeCode: URLSessionWebSocketTask.CloseCode? = nil,
    reason: Data? = nil,
    error: Error? = nil
  ) {
    guard connectionState != .disconnected else { return }

    webSocketTask = nil
    connectionState = .disconnected
    notifyStateChange()

    if isActive {
      Task {
        await attemptReconnection()
      }
    }
  }

  func connect() async throws {
    guard connectionState == .disconnected else { return }

    isActive = true
    connectionState = .connecting
    notifyStateChange()

    webSocketTask = session!.webSocketTask(with: url)
    setupConnectionTimeout()
    webSocketTask?.resume()
  }

  func disconnect() async {
    notifyStateChange()

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

  private func setupPingPong() {
    guard webSocketTask != nil else { return }

    pingPongTask?.cancel()
    pingPongTask = Task {
      while connectionState == .connected && isActive && Task.isCancelled == false {
        do {
          try await Task.sleep(for: .seconds(10))
          log.debug("Sending ping \(self.id)")
          // Custom ping method
          webSocketTask?.sendPing { error in
            if let error = error {
              Task { @MainActor in
                Log.shared.debug("No pong received")
                await self.handleDisconnection(error: error)
                await self.log.error("Failed while pinging: \(error)")
              }
            }
          }
        } catch {
          Log.shared.debug("Failed to send ping")
          handleDisconnection(error: error)
          break
        }
      }
    }
  }

  private func setupConnectionTimeout() {
    Task {
      try? await Task.sleep(for: .seconds(14))
      if self.connectionState == .connecting {
        log.error("Connection timeout")
        handleDisconnection(error: WebSocketError.connectionTimeout)
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

  private func handleDisconnection() async {
    // ?
    guard connectionState == .connected else {
      log.debug("Already disconnected")
      return
    }

    webSocketTask?.cancel()
    webSocketTask = nil
    connectionState = .disconnected

    pingPongTask?.cancel()
    pingPongTask = nil
    
    msgTask?.cancel()
    msgTask = nil

    if isActive {
      await attemptReconnection()
    }
  }

  private func attemptReconnection() async {
    guard
      isActive
    else {
      return
    }

    reconnectAttempts += 1
    let jitter = Double.random(in: 0 ... 0.3)
    let delay = min(reconnectionConfig.backoff * TimeInterval(reconnectAttempts), 24) + jitter

    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

    if connectionState == .disconnected, isActive {
      try? await connect()
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
