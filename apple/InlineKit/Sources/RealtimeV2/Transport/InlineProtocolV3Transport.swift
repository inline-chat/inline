import AsyncAlgorithms
import Auth
import Foundation
import InlineConfig
import InlineProtocol
import Logger

public actor InlineProtocolV3Transport: Transport {
  private let log = Log.scoped("RealtimeV3.Transport")
  private let auth: AuthHandle
  private let url: URL
  private let rsaPublicKeys: [InlineProtocolRSAPublicKey]
  private let channel = AsyncChannel<TransportEvent>()
  private var connection: InlineProtocolV3Connection?
  private var updatesTask: Task<Void, Never>?

  public nonisolated var events: AsyncChannel<TransportEvent> { channel }

  public init(
    auth: AuthHandle,
    url: URL? = nil,
    rsaPublicKeys: [InlineProtocolRSAPublicKey] = []
  ) {
    self.auth = auth
    self.url = url ?? URL(string: InlineConfig.realtimeServerURL.replacingOccurrences(
      of: "/realtime", with: "/realtime/v3"
    ))!
    self.rsaPublicKeys = rsaPublicKeys
  }

  public func start() async {
    guard connection == nil else { return }
    log.info("Inline Protocol transport start requested")
    await channel.send(.connecting)
    do {
      guard var credentials = auth.inlineProtocolCredentials() else {
        throw InlineProtocolV3ConnectionError.invalidKey
      }
      if let temporary = credentials.temporary,
         (temporary.expiresAt ?? 0) > Int32(Date().timeIntervalSince1970) + 60 {
        log.info("Reconnecting with stored temporary authorization")
        connection = try await InlineProtocolV3Connection.connect(.reconnect(
          url: url, authorization: temporary
        ))
        log.info("Stored temporary authorization reconnected")
      } else if !rsaPublicKeys.isEmpty {
        log.info("Creating replacement temporary authorization")
        let temporary = try await InlineProtocolV3Connection.connect(.init(
          url: url,
          rsaPublicKeys: rsaPublicKeys,
          temporary: true
        ))
        try await temporary.bindTemporary(to: credentials.permanent)
        let authorization = await temporary.authorization
        credentials.temporary = authorization
        try await auth.saveInlineProtocolCredentials(credentials)
        connection = temporary
        log.info("Replacement temporary authorization bound and stored")
      } else {
        // Application traffic must never fall back to the permanent authorization key. A client
        // without a usable temporary key must have pinned roots available to create and bind one.
        throw InlineProtocolV3ConnectionError.invalidKey
      }
      if let connection { startUpdates(connection) }
      log.info("Inline Protocol transport connected")
      await channel.send(.connected)
    } catch {
      log.error("Inline Protocol connection failed", error: error)
      connection = nil
      await channel.send(.disconnected(errorDescription: String(describing: error)))
    }
  }

  public func stop() async {
    log.info("Inline Protocol transport stop requested")
    updatesTask?.cancel()
    updatesTask = nil
    if let connection { await connection.close() }
    connection = nil
    await channel.send(.disconnected(errorDescription: "stopped"))
    log.info("Inline Protocol transport stopped")
  }

  public func send(_ message: ClientMessage) async throws {
    guard let connection else { throw TransportError.notConnected }
    switch message.body {
    case .connectionInit:
      var opened = ServerProtocolMessage()
      opened.body = .connectionOpen(ConnectionOpen())
      await channel.send(.message(opened))
    case let .rpcCall(call):
      do {
        var envelope = RealtimeV3Request()
        envelope.body = .rpc(call)
        let response = try await connection.invoke(envelope)
        var server = ServerProtocolMessage()
        switch response.body {
        case let .rpcResult(result):
          var wrapped = RpcResult()
          wrapped.reqMsgID = message.id
          wrapped.result = result.result
          server.body = .rpcResult(wrapped)
        case var .rpcError(error):
          error.reqMsgID = message.id
          server.body = .rpcError(error)
        default:
          throw InlineProtocolV3ConnectionError.unexpectedResponse
        }
        await channel.send(.message(server))
      } catch {
        throw error
      }
    case let .ping(ping):
      var pong = Pong()
      pong.nonce = ping.nonce
      var server = ServerProtocolMessage()
      server.body = .pong(pong)
      await channel.send(.message(server))
    case .ack:
      return
    case nil:
      return
    }
  }

  private func startUpdates(_ connection: InlineProtocolV3Connection) {
    updatesTask?.cancel()
    updatesTask = Task { [weak self, channel] in
      for await update in connection.updates {
        guard !Task.isCancelled else { return }
        var server = ServerProtocolMessage()
        server.body = .message(update.message)
        await channel.send(.message(server))
      }
      await self?.connectionEnded()
    }
  }

  private func connectionEnded() async {
    guard connection != nil else { return }
    log.warning("Inline Protocol transport receive loop ended")
    connection = nil
    await channel.send(.disconnected(errorDescription: "connection_closed"))
  }
}

public actor NegotiatingRealtimeTransport: Transport {
  private enum Active {
    case v2(WebSocketTransport)
    case v3(InlineProtocolV3Transport)
  }

  private let auth: AuthHandle
  private let log = Log.scoped("Realtime.TransportSelection")
  private let rsaPublicKeys: [InlineProtocolRSAPublicKey]
  private let channel = AsyncChannel<TransportEvent>()
  private var active: Active?
  private var eventTask: Task<Void, Never>?

  public nonisolated var events: AsyncChannel<TransportEvent> { channel }

  public init(auth: AuthHandle, rsaPublicKeys: [InlineProtocolRSAPublicKey] = []) {
    self.auth = auth
    self.rsaPublicKeys = rsaPublicKeys
  }

  public func start() async {
    guard active == nil else { return }
    if auth.inlineProtocolCredentials() != nil {
      log.info("Selected Inline Protocol transport")
      let transport = InlineProtocolV3Transport(auth: auth, rsaPublicKeys: rsaPublicKeys)
      active = .v3(transport)
      forward(transport.events)
      await transport.start()
    } else {
      log.info("Selected legacy Realtime V2 transport")
      let transport = WebSocketTransport()
      active = .v2(transport)
      forward(transport.events)
      await transport.start()
    }
  }

  public func stop() async {
    eventTask?.cancel()
    eventTask = nil
    switch active {
    case let .v2(transport): await transport.stop()
    case let .v3(transport): await transport.stop()
    case nil: break
    }
    active = nil
  }

  public func send(_ message: ClientMessage) async throws {
    switch active {
    case let .v2(transport): try await transport.send(message)
    case let .v3(transport): try await transport.send(message)
    case nil: throw TransportError.notConnected
    }
  }

  private func forward(_ events: AsyncChannel<TransportEvent>) {
    eventTask?.cancel()
    eventTask = Task { [channel] in
      for await event in events {
        guard !Task.isCancelled else { return }
        await channel.send(event)
      }
    }
  }
}
