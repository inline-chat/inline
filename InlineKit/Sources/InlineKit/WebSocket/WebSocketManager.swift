import Foundation

// WebSocketClient implementation stays the same as before...

public enum ConnectionState {
    case connecting
    case updating
    case normal
}

@MainActor
public final class WebSocketManager: ObservableObject {
    private var client: WebSocketClient?
    private var log = Log.scoped("WebsocketManager")
    @Published private(set) public var connectionState: ConnectionState = .connecting
    
    private var token: String?
    private var userId: Int64?
    
    convenience public init() {
        self.init(token: Auth.shared.getToken(), userId: Auth.shared.getCurrentUserId())
    }
    
    public init(token: String?, userId: Int64?) {
        self.token = token
        self.userId = userId
        Task {
            try await self.start()
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
        // Create a new task to call disconnect on the main actor
        Task { @MainActor [self] in
            self.disconnect()
        }
    }

    private var url: String {
        #if targetEnvironment(simulator)
            return "ws://localhost:8000/ws"
        #elseif DEBUG && os(iOS)
            return "ws://192.168.3.122:8000/ws"
        #elseif DEBUG && os(macOS)
            return "ws://localhost:8000/ws"
        #else
            return "wss://api.inline.chat/ws"
        #endif
    }

    public func start() async throws {
        guard let userId = userId, let token = token else {
            log.debug("not authenticated")
            return
        }
        
        let client = WebSocketClient(
            url: URL(string: url)!,
            reconnectionConfig: .init(maxAttempts: 300, backoff: 1.5),
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
            print("Received: \(text)")
        case .data(let data):
            print("Received: \(data)")
        }
    }
    
    private func stateDidChange(_ state: WebSocketConnectionState) {
        switch state {
        case .connected:
            connectionState = .normal
        case .disconnected:
            connectionState = .connecting
        case .connecting:
            connectionState = .updating
        }
    }
    
    func send(_ text: String) async throws {
        log.debug("sending message \(text)")
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
}
