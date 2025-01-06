import Foundation
import Network

// WebSocketClient implementation stays the same as before...

public enum ConnectionState {
  case connecting
  case updating
  case normal
}

@MainActor
public final class WebSocketManager: ObservableObject {
  private var client: WebSocketClient?
  private var log = Log.scoped("WebsocketManager", enableTracing: true)
  @Published public private(set) var connectionState: ConnectionState = .connecting

  private var token: String?
  private var userId: Int64?
  private var updatesManager = UpdatesManager.shared

  public convenience init() {
    self.init(token: Auth.shared.getToken(), userId: Auth.shared.getCurrentUserId())
  }

  public init(token: String?, userId: Int64?) {
    self.token = token
    self.userId = userId
//    self.updatesManager = UpdatesManager()
    Task {
      try await self.start()
    }

    setupNetworkMonitoring()
  }
  
  public func ensureConnected() async {
    // ONLY reconnect if we are disconnected, otherwise we will start two connections initially while the other one is connecting
    if await client?.state == .disconnected {
      try? await start()
    }
  }

  func disconnect() {
    log.debug("disconnecting (manual)")
    Task {
      await client?.disconnect()
    }
  }

  deinit {
    log.debug("deinit")
    pathMonitor?.cancel()
    // Create a new task to call disconnect on the main actor
    Task { @MainActor [self] in
      self.disconnect()
    }
  }

  private var url: String {
    #if targetEnvironment(simulator)
      return "ws://localhost:8000/ws"
    #elseif DEBUG && os(iOS)
      return "ws://\(ProjectConfig.devHost):8000/ws"
    #elseif DEBUG && os(macOS)
      return "ws://\(ProjectConfig.devHost):8000/ws"
    #else
      return "wss://api.inline.chat/ws"
    #endif
  }

  public func start() async throws {
    guard let userId = userId, let token = token else {
      log.debug("not authenticated")
      return
    }

    guard let url = URL(string: url) else {
      log.error("Invalid URL: \(url)")
      return
    }
    
    if let client = client {
      log.debug("disconnecting before reconnecting")
      await client.disconnect()
    }
    
    log.debug("connecting WS")

    let client = WebSocketClient(
      url: url,
      reconnectionConfig: .init(maxAttempts: 30000, backoff: 1.5),
      credentials: WebSocketCredentials(token: token, userId: userId)
    )
    self.client = client

    try await client.connect()

    log.debug("ws connected")

    await client.addMessageHandler { [weak self] message in
      Task { @MainActor in
        self?.processMessage(message)
      }
    }

    await client.addStateObserver { [weak self] state in
      Task { @MainActor in
        self?.stateDidChange(state)
      }
    }
  }

  private func processMessage(_ message: WebSocketMessage) {
    switch message {
    case .string(let text):
//      log.trace("received string \(text)")
      // Decode message as update
      if let serverMessage = decodeServerMessage(data: text) {
        switch serverMessage.k {
        case .message:
          if let updates = serverMessage.p?.updates {
            Task {
              await updatesManager.applyBatch(updates: updates)
            }
          }
        default:
          break
        }
      }

    case .data(let data):
      log.trace("received data \(data)")
      // ...
    }
  }

  private func stateDidChange(_ state: WebSocketConnectionState) {
    switch state {
    case .connected:
      connectionState = .normal
    case .disconnected:
      connectionState = .connecting
    case .connecting:
      connectionState = .connecting
    }
  }

  func send(_ text: String) async throws {
//    log.debug("sending message \(text)")
    try await client?.send(text: text)
  }

  // MARK: - Application Logic

  public func loggedOut() {
    log.debug("logged out")
    // Clear cached creds
    token = nil
    userId = nil

    // Disconnect
    disconnect()
  }

  public func authenticated() {
    log.debug("authenticated")
    // Clear cached creds
    token = Auth.shared.getToken()
    userId = Auth.shared.getCurrentUserId()

    // Disconnect
    Task {
      // TODO: handle saving this task
      try await self.start()
    }
  }

  private func decodeServerMessage(data: String) -> ServerMessage.UpdateMessage? {
    let decoder = JSONDecoder()
    do {
      return try decoder.decode(ServerMessage<ServerMessagePayload>.self, from: data.data(using: .utf8)!)
    } catch {
      log.error("Failed to decode server message", error: error)
      return nil
    }
  }

  // MARK: Network Connectivity

  private var pathMonitor: NWPathMonitor?

  private func setupNetworkMonitoring() {
    pathMonitor = NWPathMonitor()
    pathMonitor?.pathUpdateHandler = { [weak self] path in
      Task { @MainActor in
        if path.status == .satisfied {
          // Network became available
          if await self?.client?.state != .connected {
            self?.log.debug("recovering connection")
            try? await self?.start()
          }
        } else {
          // Network became unavailable
          self?.log.debug("network unavailable")
          self?.disconnect()
        }
      }
    }
    pathMonitor?.start(queue: DispatchQueue.global())
  }
}
