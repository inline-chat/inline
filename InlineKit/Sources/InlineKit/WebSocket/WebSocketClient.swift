import Foundation

enum WebSocketMessage: Sendable {
    case string(String)
    case data(Data)
}

enum WebSocketError: Error, Sendable {
    case disconnected
    case invalidMessage
}

enum WebSocketConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

struct ReconnectionConfig: Sendable {
    let maxAttempts: Int
    let backoff: TimeInterval
    
    static let `default` = ReconnectionConfig(maxAttempts: 5, backoff: 2)
    static let none = ReconnectionConfig(maxAttempts: 0, backoff: 0)
}

actor WebSocketClient {
    private var webSocketTask: URLSessionWebSocketTask?
    private var messageStreamContinuation: AsyncStream<WebSocketMessage>.Continuation?
    private var connectionState: WebSocketConnectionState = .disconnected
    private var reconnectAttempts = 0
    private var isActive = true
    
    private let url: URL
    private let session: URLSession
    private let reconnectionConfig: ReconnectionConfig
    
    init(
        url: URL,
        session: URLSession = .shared,
        reconnectionConfig: ReconnectionConfig = .default
    ) {
        self.url = url
        self.session = session
        self.reconnectionConfig = reconnectionConfig
    }
    
    deinit {
        isActive = false
        webSocketTask?.cancel()
    }
    
    nonisolated var messageStream: AsyncStream<WebSocketMessage> {
        AsyncStream { continuation in
            Task { [weak self] in
                await self?.setupMessageStream(continuation)
            }
        }
    }
    
    private func setupMessageStream(_ continuation: AsyncStream<WebSocketMessage>.Continuation) {
        messageStreamContinuation = continuation
    }
    
    var state: WebSocketConnectionState {
        connectionState
    }
    
    func connect() async throws {
        guard connectionState == .disconnected else { return }
        
        isActive = true
        connectionState = .connecting
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        connectionState = .connected
        reconnectAttempts = 0
        
        Task {
            await receiveMessages()
        }
    }
    
    func disconnect() async {
        connectionState = .disconnecting
        isActive = false
        webSocketTask?.cancel()
        webSocketTask = nil
        messageStreamContinuation?.finish()
        connectionState = .disconnected
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
            while isActive, connectionState == .connected {
                let message = try await webSocketTask.receive()
                
                switch message {
                case .string(let text):
                    messageStreamContinuation?.yield(.string(text))
                case .data(let data):
                    messageStreamContinuation?.yield(.data(data))
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
        guard connectionState == .connected else { return }
        
        webSocketTask = nil
        connectionState = .disconnected
        
        if isActive {
            await attemptReconnection()
        }
    }
    
    private func attemptReconnection() async {
        guard reconnectionConfig.maxAttempts > 0,
              reconnectAttempts < reconnectionConfig.maxAttempts,
              isActive
        else {
            return
        }
        
        reconnectAttempts += 1
        let delay = reconnectionConfig.backoff * TimeInterval(reconnectAttempts)
        
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
