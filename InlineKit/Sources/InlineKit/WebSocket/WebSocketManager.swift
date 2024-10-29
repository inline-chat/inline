import Foundation

// WebSocketClient implementation stays the same as before...

enum ConnectionState {
    case connecting
    case updating
    case normal
}

@MainActor
public final class WebSocketManager: ObservableObject {
    private var client: WebSocketClient?
    private var messageTask: Task<Void, Never>?
    private var log = Log.scoped("WebsocketManager")
    
    @Published private(set) var connectionState: ConnectionState = .connecting
    
    private var token = Auth.shared.getToken()
    private var userId = Auth.shared.getCurrentUserId()
    
    public init() {
        Task {
            try await self.start()
        }
    }
    
    func disconnect() {
        messageTask?.cancel()
        messageTask = nil
        connectionState = .connecting
    
        Task {
            await client?.disconnect()
        }
    }
    
    deinit {
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
            reconnectionConfig: .init(maxAttempts: 300, backoff: 1.5)
        )
        self.client = client
        
        log.debug("connecting")
        
        try await client.connect()
        
        log.debug("connected")
     
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            guard let self else { return }
            
            for await message in client.messageStream {
                log.debug("message received \(message)")
                await self.processMessage(message)
            }
        }
        
        log.debug("authenticating as userId=\(userId)")
        try await client
            .send(
                ClientMessage<ConnectionInitPayload>
                    .createConnectionInit(
                        token: token,
                        userId: userId
                    )
            )
        
    }
    
    func stop() async {
        messageTask?.cancel()
        messageTask = nil
        await client?.disconnect()
        client = nil
    }
    
    private func processMessage(_ message: WebSocketMessage) async {
        switch message {
        case .string(let text):
            print("Received: \(text)")
        case .data(let data):
            print("Received: \(data)")
        }
    }
    
    func send(_ text: String) async throws {
        log.debug("sending message \(text)")
        try await client?.send(text: text)
    }
    
    public func loggedOut() {
        log.debug("logged out")
        // Clear cached creds
        self.token = nil
        self.userId = nil
        
        // Disconnect
        self.disconnect()
    }
    
    public func authenticated() {
        log.debug("authenticated")
        // Clear cached creds
        self.token = Auth.shared.getToken()
        self.userId = Auth.shared.getCurrentUserId()
        
        // Disconnect
        Task {
            // TODO: handle saving this task
            try await self.start()
        }
    }
}
