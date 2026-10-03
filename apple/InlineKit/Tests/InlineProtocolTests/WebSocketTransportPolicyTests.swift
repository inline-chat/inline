import Foundation
@testable import InlineProtocol
import Network
import Testing

@Suite("WebSocket transport policy")
struct WebSocketTransportPolicyTests {
  @Test(
    "real WebSocket closes distinguish confirmed revocation from ambiguous authorization loss",
    .timeLimit(.minutes(1)),
    arguments: ["session_revoked_confirmed", "session_revoked", "authorization_unavailable"]
  )
  func classifiesAuthorizationCloseThroughFoundation(reason: String) async throws {
    let server = try LoopbackWebSocketServer(closeReason: reason)
    defer { server.cancel() }
    let port = try server.port
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)/authorization-close"))
    let key = [UInt8](repeating: 0x5A, count: 256)
    let authorization = try InlineProtocolAuthorization(
      key: key, keyID: InlineSecureTransport.authKeyID(key), serverSalt: 1,
      temporary: true, expiresAt: Int32(Date().timeIntervalSince1970) + 3_600
    )
    let connection = try await InlineProtocolV3Connection.connect(.reconnect(
      url: url, authorization: authorization
    ))

    // Exercise the real receive failure and URLSession closeCode/closeReason delivery. The
    // server waits for the carrier header, so an HTTP upgrade failure cannot satisfy the test.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await connection.terminationError == nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let terminationError = await connection.terminationError
    await connection.close()
    #expect(terminationError == (reason == "session_revoked_confirmed"
      ? .sessionRevoked : .authorizationInvalidated))
  }

  @Test("configures Foundation for the largest valid Inline packet")
  func configuresMaximumIncomingMessageSize() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let url = try #require(URL(string: "wss://localhost/realtime"))

    let task = InlineWebSocketTransportPolicy.makeTask(
      using: session,
      url: url
    )

    #expect(
      InlineWebSocketTransportPolicy.maximumIncomingMessageBytes
        == InlineSecureTransport.maximumPacketBytes + 4
    )
    #expect(
      task.maximumMessageSize
        == InlineWebSocketTransportPolicy.maximumIncomingMessageBytes
    )
  }

  @Test("receives a valid Inline record above Foundation's old limit")
  func receivesLargeInlineRecord() async throws {
    let authKey = [UInt8](repeating: 0x5A, count: 256)
    let body = [UInt8](repeating: 0x2A, count: 1_100_000)
    let messageSeconds = Int64(1_700_000_000)
    let fields = InlineEncryptedRecordFields(
      serverSalt: 1,
      sessionID: 2,
      messageID: (messageSeconds << 32) | 1,
      sequenceNumber: 1,
      body: body
    )
    let paddingCount = 12 + (16 - (32 + body.count + 12) % 16) % 16
    let record = try InlineSecureTransport.encryptRecord(
      authKey: authKey,
      direction: .serverToClient,
      fields: fields,
      padding: [UInt8](repeating: 0xA5, count: paddingCount)
    )
    let frame = try InlineSecureTransport.encodeAbridgedPacket(record)
    #expect(frame.count > 1_048_576)
    #expect(frame.count <= InlineWebSocketTransportPolicy.maximumIncomingMessageBytes)
    #expect(
      try InlineSecureTransport.decryptRecord(
        record,
        authKey: authKey,
        direction: .serverToClient,
        expectedSessionID: fields.sessionID,
        validServerSalts: [fields.serverSalt],
        nowSeconds: messageSeconds
      ) == fields
    )

    let server = try LoopbackWebSocketServer(payload: Data(frame))
    defer { server.cancel() }
    let port = try server.port
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)/oversized-record"))

    let oldLimitSession = URLSession(configuration: .ephemeral)
    defer { oldLimitSession.invalidateAndCancel() }
    let oldLimitTask = oldLimitSession.webSocketTask(with: url)
    oldLimitTask.maximumMessageSize = 1_048_576
    oldLimitTask.resume()
    do {
      _ = try await receiveData(from: oldLimitTask)
      Issue.record("Foundation unexpectedly admitted a WebSocket message above the old limit")
    } catch is ReceiveTimeoutError {
      throw ReceiveTimeoutError()
    } catch {
      // The old production path rejected this complete WebSocket message.
    }
    oldLimitTask.cancel(with: .goingAway, reason: nil)

    let configuredSession = URLSession(configuration: .ephemeral)
    defer { configuredSession.invalidateAndCancel() }
    let configuredTask = InlineWebSocketTransportPolicy.makeTask(
      using: configuredSession,
      url: url
    )
    configuredTask.resume()
    let received = try await receiveData(from: configuredTask)
    #expect(received == Data(frame))
    configuredTask.cancel(with: .goingAway, reason: nil)
  }
}

private struct ReceiveTimeoutError: Error {}

private func receiveData(from task: URLSessionWebSocketTask) async throws -> Data {
  try await withThrowingTaskGroup(of: Data.self) { group in
    group.addTask {
      switch try await task.receive() {
        case let .data(data):
          return data
        case let .string(string):
          throw UnexpectedWebSocketMessageError(message: string)
        @unknown default:
          throw UnexpectedWebSocketMessageError(message: "unknown")
      }
    }
    group.addTask {
      try await Task.sleep(for: .seconds(5))
      throw ReceiveTimeoutError()
    }
    guard let result = try await group.next() else {
      throw ReceiveTimeoutError()
    }
    group.cancelAll()
    return result
  }
}

private struct UnexpectedWebSocketMessageError: Error {
  let message: String
}

private enum LoopbackWebSocketServerError: Error {
  case listenerFailed(String)
  case listenerTimedOut
  case missingPort
}

private final class LoopbackWebSocketServer: @unchecked Sendable {
  private let listener: NWListener
  private let payload: Data
  private let closeReason: String?
  private let queue = DispatchQueue(label: "chat.inline.websocket-transport-policy-test")
  private let lock = NSLock()
  private var connections: [NWConnection] = []

  var port: UInt16 {
    get throws {
      guard let rawValue = listener.port?.rawValue else {
        throw LoopbackWebSocketServerError.missingPort
      }
      return rawValue
    }
  }

  init(payload: Data = Data(), closeReason: String? = nil) throws {
    self.payload = payload
    self.closeReason = closeReason
    let webSocketOptions = NWProtocolWebSocket.Options()
    webSocketOptions.autoReplyPing = true
    let parameters = NWParameters.tcp
    parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
    listener = try NWListener(using: parameters, on: .any)

    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    let startGate = LoopbackListenerStartGate()
    listener.stateUpdateHandler = { state in
      switch state {
        case .ready:
          startGate.complete(.success(()))
        case let .failed(error):
          startGate.complete(.failure(.listenerFailed(String(describing: error))))
        default:
          break
      }
    }
    listener.start(queue: queue)
    switch startGate.wait() {
      case .success:
        break
      case let .failure(error):
        listener.cancel()
        throw error
    }
  }

  func cancel() {
    listener.cancel()
    let activeConnections = lock.withLock {
      defer { connections.removeAll() }
      return connections
    }
    for connection in activeConnections {
      connection.cancel()
    }
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock {
      connections.append(connection)
    }
    connection.stateUpdateHandler = { [payload, closeReason] state in
      guard case .ready = state else { return }
      if let closeReason {
        connection.receiveMessage { data, _, _, error in
          guard error == nil, data?.count == 64 else { return }
          let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
          metadata.closeCode = .privateCode(4401)
          connection.send(
            content: Data(closeReason.utf8),
            contentContext: NWConnection.ContentContext(
              identifier: "authorization-close", metadata: [metadata]
            ),
            isComplete: true,
            completion: .contentProcessed { _ in }
          )
        }
        return
      }
      let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
      let context = NWConnection.ContentContext(
        identifier: "oversized-inline-record",
        metadata: [metadata]
      )
      connection.send(
        content: payload,
        contentContext: context,
        isComplete: true,
        completion: .contentProcessed { _ in }
      )
    }
    connection.start(queue: queue)
  }
}

private final class LoopbackListenerStartGate: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var result: Result<Void, LoopbackWebSocketServerError>?

  func complete(_ result: Result<Void, LoopbackWebSocketServerError>) {
    let shouldSignal = lock.withLock {
      guard self.result == nil else { return false }
      self.result = result
      return true
    }
    if shouldSignal {
      semaphore.signal()
    }
  }

  func wait() -> Result<Void, LoopbackWebSocketServerError> {
    guard semaphore.wait(timeout: .now() + 5) == .success else {
      return .failure(.listenerTimedOut)
    }
    return lock.withLock { result ?? .failure(.listenerTimedOut) }
  }
}
