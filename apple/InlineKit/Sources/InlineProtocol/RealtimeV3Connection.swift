import Foundation
import Security
import SwiftProtobuf

private final class InlineProtocolUpdatePipe: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<RealtimeV3Update>.Continuation] = [:]

  func stream() -> AsyncStream<RealtimeV3Update> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(of: RealtimeV3Update.self)
    continuation.onTermination = { [weak self] _ in
      _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
    }
    lock.withLock { continuations[id] = continuation }
    return stream
  }

  func yield(_ update: RealtimeV3Update) {
    let values = lock.withLock { Array(continuations.values) }
    for continuation in values { continuation.yield(update) }
  }

  func finish() {
    let values = lock.withLock {
      let values = Array(continuations.values)
      continuations.removeAll()
      return values
    }
    for continuation in values { continuation.finish() }
  }
}

public enum InlineProtocolV3ConnectionError: Error, Equatable, Sendable {
  case closed
  case invalidKey
  case protocolFailure
  case rpc(String)
  case unexpectedResponse
}

public struct InlineProtocolV3Options: Sendable {
  public let url: URL
  public let rsaPublicKeys: [InlineProtocolRSAPublicKey]
  public let authorization: InlineProtocolAuthorization?
  public let temporary: Bool

  public init(
    url: URL,
    rsaPublicKeys: [InlineProtocolRSAPublicKey],
    authorization: InlineProtocolAuthorization? = nil,
    temporary: Bool = false
  ) {
    self.url = url
    self.rsaPublicKeys = rsaPublicKeys
    self.authorization = authorization
    self.temporary = temporary
  }

  public static func reconnect(url: URL, authorization: InlineProtocolAuthorization) -> Self {
    Self(url: url, rsaPublicKeys: [], authorization: authorization)
  }
}

public actor InlineProtocolV3Connection {
  private struct PendingRequest {
    let sequence: Int32
    let body: [UInt8]
    let continuation: CheckedContinuation<(messageID: Int64, result: [UInt8]), any Error>
  }

  private static let rpcResult: UInt32 = 0xf35c6d01
  private static let newSessionCreated: UInt32 = 0x9ec20908
  private static let messagesAck: UInt32 = 0x62d6b459
  private static let badMessage: UInt32 = 0xa7eff811
  private static let badServerSalt: UInt32 = 0xedab447b
  private static let vector: UInt32 = 0x1cb5c415
  private static let boolTrue: UInt32 = 0x997275b5

  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let carrier: InlineObfuscatedClientCarrier
  private let sessionID: Int64
  private var authorizationValue: InlineProtocolAuthorization
  private var lastMessageID: Int64 = 0
  private var contentCount: Int32 = 0
  private var serverUnixMilliseconds: Int64
  private var monotonicAnchor: TimeInterval
  private nonisolated let updatePipe = InlineProtocolUpdatePipe()
  private var pendingRequests: [Int64: PendingRequest] = [:]
  private var receiveTask: Task<Void, Never>?

  private init(
    session: URLSession,
    task: URLSessionWebSocketTask,
    carrier: InlineObfuscatedClientCarrier,
    sessionID: Int64,
    authorization: InlineProtocolAuthorization,
    serverTime: Int32,
    lastMessageID: Int64 = 0
  ) {
    self.session = session
    self.task = task
    self.carrier = carrier
    self.sessionID = sessionID
    authorizationValue = authorization
    self.lastMessageID = lastMessageID
    serverUnixMilliseconds = Int64(serverTime) * 1_000
    monotonicAnchor = ProcessInfo.processInfo.systemUptime
  }

  public static func connect(_ options: InlineProtocolV3Options) async throws -> InlineProtocolV3Connection {
    guard options.authorization != nil || !options.rsaPublicKeys.isEmpty else {
      throw InlineProtocolV3ConnectionError.invalidKey
    }
    var header: [UInt8]
    repeat { header = try secureRandom(count: 64) }
    while !InlineObfuscatedClientCarrier.isValidHeader(header)
    let carrier = try InlineObfuscatedClientCarrier(randomHeader: header)
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: options.url)
    task.resume()
    try await task.send(.data(Data(carrier.wireHeader)))
    let sessionID = readInt64(try secureRandom(count: 8), at: 0)

    if let authorization = options.authorization {
      let connection = InlineProtocolV3Connection(
        session: session, task: task, carrier: carrier, sessionID: sessionID,
        authorization: authorization, serverTime: Int32(Date().timeIntervalSince1970)
      )
      await connection.startReceiving()
      return connection
    }

    let handshake = InlineHandshakeClient(rsaKeys: options.rsaPublicKeys)
    var request = try handshake.begin(temporary: options.temporary)
    var lastID: Int64 = 0
    while true {
      let messageID = try nextSystemMessageID(last: &lastID)
      try await sendPacket(
        encodeUnencrypted(messageID: messageID, body: request),
        carrier: carrier,
        task: task
      )
      let packet = try await receivePacket(carrier: carrier, task: task)
      let response = try decodeUnencrypted(packet)
      switch try handshake.receive(response) {
      case let .request(next): request = next
      case let .established(authorization, serverTime):
        let connection = InlineProtocolV3Connection(
          session: session, task: task, carrier: carrier, sessionID: sessionID,
          authorization: authorization, serverTime: serverTime, lastMessageID: lastID
        )
        await connection.startReceiving()
        return connection
      }
    }
  }

  public var authorization: InlineProtocolAuthorization { authorizationValue }
  public nonisolated var updates: AsyncStream<RealtimeV3Update> { updatePipe.stream() }

  public func close() {
    receiveTask?.cancel()
    receiveTask = nil
    failPending(with: InlineProtocolV3ConnectionError.closed)
    updatePipe.finish()
    task.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
  }

  public func invoke(_ request: RealtimeV3Request) async throws -> RealtimeV3Response {
    let body = try InlineSecureTransport.encodeInlineInvoke(payload: Array(request.serializedData()))
    let result = try await sendContent(body)
    guard case let .result(payload) = try InlineSecureTransport.decodeInlineApplicationObject(result) else {
      throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
    return try RealtimeV3Response(serializedBytes: payload)
  }

  public func authBegin(_ request: AuthBeginRequest) async throws -> AuthBeginResult {
    var envelope = RealtimeV3Request()
    envelope.body = .authBegin(request)
    switch try await invoke(envelope).body {
    case let .authBegin(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error.message)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func authComplete(_ request: AuthCompleteRequest) async throws -> AuthCompleteResult {
    var envelope = RealtimeV3Request()
    envelope.body = .authComplete(request)
    switch try await invoke(envelope).body {
    case let .authComplete(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error.message)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func callRPC(_ request: RpcCall) async throws -> RpcResult {
    var envelope = RealtimeV3Request()
    envelope.body = .rpc(request)
    switch try await invoke(envelope).body {
    case let .rpcResult(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error.message)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func createHTTPUpload(_ request: CreateHttpUploadRequest) async throws -> CreateHttpUploadResult {
    var envelope = RealtimeV3Request()
    envelope.body = .createHTTPUpload(request)
    switch try await invoke(envelope).body {
    case let .createHTTPUpload(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error.message)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func finishHTTPUpload(_ request: FinishHttpUploadRequest) async throws -> FinishHttpUploadResult {
    var envelope = RealtimeV3Request()
    envelope.body = .finishHTTPUpload(request)
    switch try await invoke(envelope).body {
    case let .finishHTTPUpload(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error.message)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func bindTemporary(to permanent: InlineProtocolAuthorization) async throws {
    guard authorizationValue.temporary, !permanent.temporary,
          let expiresAt = authorizationValue.expiresAt
    else { throw InlineProtocolV3ConnectionError.protocolFailure }
    let messageID = try nextMessageID()
    let sequence = nextSequence(content: true)
    let nonce = readInt64(try Self.secureRandom(count: 8), at: 0)
    let proof = try InlineTemporaryKeyBinding.createProof(
      permanent: permanent, temporary: authorizationValue, temporarySessionID: sessionID,
      messageID: messageID, nonce: nonce, expiresAt: expiresAt,
      randomInt128: Self.secureRandom(count: 16), randomPadding: Self.secureRandom(count: 8)
    )
    let body = try InlineTemporaryKeyBinding.encodeRequest(
      permanentKeyID: readInt64(permanent.keyID, at: 0),
      nonce: nonce, expiresAt: expiresAt, proof: proof
    )
    let result = try await sendPrepared(messageID: messageID, sequence: sequence, body: body).result
    guard result == little(Self.boolTrue) else { throw InlineProtocolV3ConnectionError.protocolFailure }
  }

  private func sendContent(_ body: [UInt8]) async throws -> [UInt8] {
    try await sendPrepared(messageID: nextMessageID(), sequence: nextSequence(content: true), body: body).result
  }

  private func sendPrepared(
    messageID initialID: Int64,
    sequence: Int32,
    body: [UInt8]
  ) async throws -> (messageID: Int64, result: [UInt8]) {
    try await withCheckedThrowingContinuation { continuation in
      pendingRequests[initialID] = PendingRequest(
        sequence: sequence, body: body, continuation: continuation
      )
      Task {
        do {
          try await self.sendEncrypted(
            messageID: initialID, sequence: sequence, body: body, quickAck: true
          )
        } catch {
          self.failPending(messageID: initialID, with: error)
        }
      }
    }
  }

  private func startReceiving() {
    guard receiveTask == nil else { return }
    receiveTask = Task { [weak self] in
      guard let self else { return }
      do {
        while !Task.isCancelled { try await self.receiveAndDispatch() }
      } catch is CancellationError {
        return
      } catch {
        await self.receiveFailed(error)
      }
    }
  }

  private func receiveAndDispatch() async throws {
    let fields = try await receiveEncrypted()
    if fields.sequenceNumber % 2 == 1 { try await sendAcknowledgement(fields.messageID) }
    let constructor = try readUInt32(fields.body, at: 0)
    switch constructor {
    case Self.newSessionCreated:
      guard fields.body.count >= 28 else { throw InlineProtocolV3ConnectionError.protocolFailure }
      authorizationValue.serverSalt = readInt64(fields.body, at: 20)
    case Self.messagesAck:
      return
    case Self.badMessage, Self.badServerSalt:
      try await recoverBadMessage(fields, constructor: constructor)
    case Self.rpcResult:
      guard fields.body.count >= 12 else { throw InlineProtocolV3ConnectionError.protocolFailure }
      let requestID = readInt64(fields.body, at: 4)
      guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
      pending.continuation.resume(returning: (requestID, Array(fields.body.dropFirst(12))))
    default:
      guard case let .update(payload) = try InlineSecureTransport.decodeInlineApplicationObject(fields.body)
      else { return }
      updatePipe.yield(try RealtimeV3Update(serializedBytes: payload))
    }
  }

  private func recoverBadMessage(
    _ fields: InlineEncryptedRecordFields,
    constructor: UInt32
  ) async throws {
    guard fields.body.count >= 20 else { throw InlineProtocolV3ConnectionError.protocolFailure }
    let requestID = readInt64(fields.body, at: 4)
    let sequence = readInt32(fields.body, at: 12)
    guard let pending = pendingRequests.removeValue(forKey: requestID), pending.sequence == sequence
    else { throw InlineProtocolV3ConnectionError.protocolFailure }
    let code = readInt32(fields.body, at: 16)
    if code == 16 || code == 17 {
      sample(messageID: fields.messageID)
    } else if code == 48, constructor == Self.badServerSalt, fields.body.count >= 28 {
      authorizationValue.serverSalt = readInt64(fields.body, at: 20)
    } else {
      pending.continuation.resume(throwing: InlineProtocolV3ConnectionError.protocolFailure)
      return
    }
    let replacementID = try nextMessageID()
    pendingRequests[replacementID] = pending
    do {
      try await sendEncrypted(
        messageID: replacementID, sequence: pending.sequence, body: pending.body, quickAck: true
      )
    } catch {
      failPending(messageID: replacementID, with: error)
    }
  }

  private func receiveFailed(_ error: any Error) {
    receiveTask = nil
    failPending(with: error)
    updatePipe.finish()
  }

  private func failPending(messageID: Int64, with error: any Error) {
    pendingRequests.removeValue(forKey: messageID)?.continuation.resume(throwing: error)
  }

  private func failPending(with error: any Error) {
    let pending = pendingRequests.values
    pendingRequests.removeAll()
    for request in pending { request.continuation.resume(throwing: error) }
  }

  private func receiveEncrypted() async throws -> InlineEncryptedRecordFields {
    let packet = try await receivePacket()
    let fields = try InlineSecureTransport.decryptRecord(
      packet, authKey: authorizationValue.key, direction: .serverToClient,
      expectedSessionID: sessionID, validServerSalts: [authorizationValue.serverSalt],
      nowSeconds: serverNowMilliseconds() / 1_000
    )
    sample(messageID: fields.messageID)
    return fields
  }

  private func sendAcknowledgement(_ messageID: Int64) async throws {
    let body = little(Self.messagesAck) + little(Self.vector) + little(Int32(1)) + little(messageID)
    try await sendEncrypted(
      messageID: try nextMessageID(), sequence: nextSequence(content: false), body: body, quickAck: false
    )
  }

  private func sendEncrypted(
    messageID: Int64,
    sequence: Int32,
    body: [UInt8],
    quickAck: Bool
  ) async throws {
    let paddingCount = 12 + (16 - (32 + body.count + 12) % 16) % 16
    let record = try InlineSecureTransport.encryptRecord(
      authKey: authorizationValue.key,
      direction: .clientToServer,
      fields: InlineEncryptedRecordFields(
        serverSalt: authorizationValue.serverSalt, sessionID: sessionID,
        messageID: messageID, sequenceNumber: sequence, body: body
      ),
      padding: Self.secureRandom(count: paddingCount)
    )
    try await sendPacket(record, quickAck: quickAck)
  }

  private func sendPacket(_ packet: [UInt8], quickAck: Bool = false) async throws {
    let frame = try InlineSecureTransport.encodeAbridgedPacket(packet, requestQuickAck: quickAck)
    try await task.send(.data(Data(try carrier.outbound.process(frame))))
  }

  private func receivePacket() async throws -> [UInt8] {
    while true {
      let message = try await task.receive()
      let wire: [UInt8] = switch message {
      case let .data(data): Array(data)
      case let .string(string): Array(string.utf8)
      @unknown default: throw InlineProtocolV3ConnectionError.closed
      }
      switch try InlineSecureTransport.decodeAbridgedFrame(carrier.inbound.process(wire)) {
      case let .packet(payload, _): return payload
      case .quickAck: continue
      }
    }
  }

  private func nextSequence(content: Bool) -> Int32 {
    let value = contentCount * 2 + (content ? 1 : 0)
    if content { contentCount += 1 }
    return value
  }

  private func nextMessageID() throws -> Int64 {
    try nextMessageID(milliseconds: serverNowMilliseconds())
  }

  private func nextMessageID(milliseconds: Int64) throws -> Int64 {
    let low = Int64(try readUInt32(Self.secureRandom(count: 4), at: 0) & 0x3fff_ffff) << 2
    var candidate = ((milliseconds / 1_000) << 32)
      | (((milliseconds % 1_000) << 32) / 1_000) | low
    candidate &= ~3
    if candidate <= lastMessageID { candidate = (lastMessageID + 4) & ~3 }
    lastMessageID = candidate
    return candidate
  }

  private func serverNowMilliseconds() -> Int64 {
    serverUnixMilliseconds + Int64((ProcessInfo.processInfo.systemUptime - monotonicAnchor) * 1_000)
  }

  private func sample(messageID: Int64) {
    serverUnixMilliseconds = (messageID >> 32) * 1_000
    monotonicAnchor = ProcessInfo.processInfo.systemUptime
  }

  private static func secureRandom(count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    return bytes
  }

  private static func nextSystemMessageID(last: inout Int64) throws -> Int64 {
    let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
    let low = Int64(try readUInt32(secureRandom(count: 4), at: 0) & 0x3fff_ffff) << 2
    var value = ((milliseconds / 1_000) << 32) | (((milliseconds % 1_000) << 32) / 1_000) | low
    value &= ~3
    if value <= last { value = (last + 4) & ~3 }
    last = value
    return value
  }

  private static func encodeUnencrypted(messageID: Int64, body: [UInt8]) throws -> [UInt8] {
    guard !body.isEmpty, body.count.isMultiple(of: 4) else {
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    return little(Int64(0)) + little(messageID) + little(Int32(body.count)) + body
  }

  private static func decodeUnencrypted(_ packet: [UInt8]) throws -> [UInt8] {
    guard packet.count >= 24, readInt64(packet, at: 0) == 0 else {
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    let count = Int(readInt32(packet, at: 16))
    guard count > 0, count.isMultiple(of: 4), packet.count == 20 + count else {
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    return Array(packet.dropFirst(20))
  }

  private static func sendPacket(
    _ packet: [UInt8], carrier: InlineObfuscatedClientCarrier, task: URLSessionWebSocketTask
  ) async throws {
    let frame = try InlineSecureTransport.encodeAbridgedPacket(packet)
    try await task.send(.data(Data(try carrier.outbound.process(frame))))
  }

  private static func receivePacket(
    carrier: InlineObfuscatedClientCarrier, task: URLSessionWebSocketTask
  ) async throws -> [UInt8] {
    while true {
      guard case let .data(data) = try await task.receive() else {
        throw InlineProtocolV3ConnectionError.protocolFailure
      }
      switch try InlineSecureTransport.decodeAbridgedFrame(carrier.inbound.process(Array(data))) {
      case let .packet(payload, _): return payload
      case .quickAck: continue
      }
    }
  }
}

private func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  withUnsafeBytes(of: value.littleEndian, Array.init)
}

private func readUInt32(_ value: [UInt8], at offset: Int) throws -> UInt32 {
  guard offset + 4 <= value.count else { throw InlineProtocolV3ConnectionError.protocolFailure }
  return value[offset..<(offset + 4)].enumerated().reduce(0) {
    $0 | UInt32($1.element) << UInt32($1.offset * 8)
  }
}

private func readInt32(_ value: [UInt8], at offset: Int) -> Int32 {
  Int32(bitPattern: value[offset..<(offset + 4)].enumerated().reduce(0) {
    $0 | UInt32($1.element) << UInt32($1.offset * 8)
  })
}

private func readInt64(_ value: [UInt8], at offset: Int) -> Int64 {
  Int64(bitPattern: value[offset..<(offset + 8)].enumerated().reduce(0) {
    $0 | UInt64($1.element) << UInt64($1.offset * 8)
  })
}
