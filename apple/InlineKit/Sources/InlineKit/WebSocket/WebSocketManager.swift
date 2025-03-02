import Foundation
import InlineConfig
import Network
import Logger
import Auth

// WebSocketClient implementation stays the same as before...

public enum ConnectionState {
  case connecting
  case updating
  case normal
}

@MainActor
public final class WebSocketManager: ObservableObject {
  private var client: WebSocketClient?
  private var log = Log.scoped("WebsocketManager", enableTracing: false)
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

    log.debug("starting socket")
    Task {
      await self.start()
    }
  }

  public func ensureConnected() {
    Task {
      await client?.ensureConnected()
    }
  }

  private func disconnect() {
    Task {
      await client?.stop()
    }
  }

  private var url: String {
    if ProjectConfig.useProductionApi {
      return "wss://api.inline.chat/ws"
    }

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

  public func start() async {
    guard let userId, let token else {
      log.debug("not authenticated")
      return
    }

    guard let url = URL(string: url) else {
      log.error("Invalid URL: \(url)")
      return
    }

    log.debug("starting websocket client")

    let client = WebSocketClient(
      url: url,
      credentials: WebSocketCredentials(token: token, userId: userId)
    )
    self.client = nil
    self.client = client

    await client.start()

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
      case let .string(text):
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

      case let .data(data):
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

  func send<T: Codable>(_ message: ClientMessage<T>) async throws {
    log.trace("sending message \(message)")
    try await client?.send<T>(message)
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
    log.debug("authenticated, starting socket")

    token = Auth.shared.getToken()
    userId = Auth.shared.getCurrentUserId()

    // Connect
    Task { await self.start() }
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
}
