import Foundation
import Logger
import Security
import SwiftProtobuf

final class InlineProtocolUpdatePipe: @unchecked Sendable {
  private let lock = NSLock()
  private let streamValue: AsyncStream<RealtimeV3Update>
  private let continuation: AsyncStream<RealtimeV3Update>.Continuation
  private let capacity: Int
  private let byteCapacity: Int
  private var bufferedSizes: [Int] = []
  private var bufferedBytes = 0
  private var finished = false

  init(capacity: Int = 256, byteCapacity: Int = 16 * 1024 * 1024) {
    precondition(capacity > 0)
    precondition(byteCapacity > 0)
    let pair = AsyncStream.makeStream(
      of: RealtimeV3Update.self,
      bufferingPolicy: .bufferingOldest(capacity)
    )
    self.capacity = capacity
    self.byteCapacity = byteCapacity
    streamValue = pair.stream
    continuation = pair.continuation
  }

  func stream() -> AsyncStream<RealtimeV3Update> { streamValue }

  @discardableResult
  func yield(_ update: RealtimeV3Update) -> Bool {
    let serializedBytes = (try? update.serializedData().count) ?? (byteCapacity + 1)
    let outcome = lock.withLock { () -> (accepted: Bool, finish: Bool) in
      guard !finished else { return (false, false) }
      // Check the cumulative budget before AsyncStream takes ownership. Once yielded, a value
      // remains drainable even after finish(), so detecting this only in the bookkeeping below
      // would let an oversized durable event escape through the terminating stream.
      guard serializedBytes <= byteCapacity,
            bufferedBytes <= byteCapacity - serializedBytes
      else {
        finished = true
        return (false, true)
      }
      switch continuation.yield(update) {
      case let .enqueued(remainingCapacity):
        let bufferedCount = max(0, capacity - remainingCapacity)
        guard bufferedCount > 0 else {
          bufferedSizes.removeAll(keepingCapacity: true)
          bufferedBytes = 0
          return (true, false)
        }
        let retainedBeforeNewValue = bufferedCount - 1
        while bufferedSizes.count > retainedBeforeNewValue {
          bufferedBytes -= bufferedSizes.removeFirst()
        }
        bufferedSizes.append(serializedBytes)
        bufferedBytes += serializedBytes
        guard bufferedBytes <= byteCapacity else {
          finished = true
          return (false, true)
        }
        return (true, false)
      case .dropped:
        return (false, false)
      case .terminated:
        finished = true
        return (false, false)
      @unknown default:
        finished = true
        return (false, true)
      }
    }
    if outcome.finish { continuation.finish() }
    return outcome.accepted
  }

  func finish() {
    let shouldFinish = lock.withLock {
      guard !finished else { return false }
      finished = true
      bufferedSizes.removeAll(keepingCapacity: false)
      bufferedBytes = 0
      return true
    }
    if shouldFinish { continuation.finish() }
  }
}

/// Keeps the mutable handshake state serialized while moving synchronous Security work off the
/// caller's executor. Swift 6 async functions otherwise inherit their caller until an explicit
/// concurrency boundary, which can put raw modular exponentiation on the UI thread at startup.
final class InlineProtocolHandshakeWorker: @unchecked Sendable {
  private let client: InlineHandshakeClient
  private let queue = DispatchQueue(
    label: "chat.inline.InlineProtocol.Handshake",
    qos: .userInitiated
  )
  private let onExecution: @Sendable () -> Void

  init(
    client: InlineHandshakeClient,
    onExecution: @escaping @Sendable () -> Void = {}
  ) {
    self.client = client
    self.onExecution = onExecution
  }

  func begin(temporary: Bool) async throws -> [UInt8] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        dispatchPrecondition(condition: .notOnQueue(.main))
        onExecution()
        continuation.resume(with: Result { try client.begin(temporary: temporary) })
      }
    }
  }

  func receive(_ body: [UInt8]) async throws -> InlineHandshakeTransition {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        dispatchPrecondition(condition: .notOnQueue(.main))
        onExecution()
        continuation.resume(with: Result { try client.receive(body) })
      }
    }
  }
}

private final class InlineProtocolRequestCancellationState: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool { lock.withLock { cancelled } }

  func cancel() {
    lock.withLock { cancelled = true }
  }
}

/// Owns the continuous outbound carrier stream and the WebSocket send boundary together.
/// Obfuscated2 cannot recover if ciphertext is put on the wire in a different order than the
/// stream was advanced, so exactly one write may be in flight at a time.
actor InlineProtocolOutboundWriter {
  typealias SendWire = @Sendable (Data) async throws -> Void

  private struct Write {
    let packet: [UInt8]
    let quickAck: Bool
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let outbound: InlineAESCTRStream
  private let sendWire: SendWire
  private let capacity: Int
  private let byteCapacity: Int
  private var queue: [Write] = []
  private var queuedBytes = 0
  private var activeWrite: Write?
  private var drainTask: Task<Void, Never>?
  private var terminalError: (any Error)?

  init(
    outbound: InlineAESCTRStream,
    capacity: Int = 256,
    byteCapacity: Int = 16 * 1024 * 1024,
    sendWire: @escaping SendWire
  ) {
    precondition(capacity > 0)
    precondition(byteCapacity > 0)
    self.outbound = outbound
    self.capacity = capacity
    self.byteCapacity = byteCapacity
    self.sendWire = sendWire
  }

  func send(_ packet: [UInt8], quickAck: Bool = false) async throws {
    if let terminalError { throw terminalError }
    guard queue.count < capacity, queuedBytes + packet.count <= byteCapacity else {
      throw InlineProtocolV3ConnectionError.outboundBufferOverflow
    }

    try await withCheckedThrowingContinuation { continuation in
      queue.append(Write(packet: packet, quickAck: quickAck, continuation: continuation))
      queuedBytes += packet.count
      startDrainIfNeeded()
    }
  }

  func close(with error: any Error = InlineProtocolV3ConnectionError.closed) {
    guard terminalError == nil else { return }
    terminalError = error
    drainTask?.cancel()
    if let activeWrite {
      self.activeWrite = nil
      activeWrite.continuation.resume(throwing: error)
    }
    failQueued(with: error)
  }

  var queuedWriteCount: Int { queue.count }
  var queuedByteCount: Int { queuedBytes }

  private func startDrainIfNeeded() {
    guard drainTask == nil else { return }
    drainTask = Task { await drain() }
  }

  private func drain() async {
    while terminalError == nil, !queue.isEmpty {
      let write = queue.removeFirst()
      queuedBytes -= write.packet.count
      activeWrite = write
      do {
        let frame = try InlineSecureTransport.encodeAbridgedPacket(
          write.packet,
          requestQuickAck: write.quickAck
        )
        let wire = try outbound.process(frame)
        try await sendWire(Data(wire))
        guard let completedWrite = takeActiveWrite() else { continue }
        if let terminalError {
          completedWrite.continuation.resume(throwing: terminalError)
        } else {
          completedWrite.continuation.resume()
        }
      } catch {
        if let activeWrite = takeActiveWrite() {
          activeWrite.continuation.resume(throwing: error)
        }
        if terminalError == nil { terminalError = error }
        failQueued(with: error)
      }
    }
    drainTask = nil
  }

  private func takeActiveWrite() -> Write? {
    defer { activeWrite = nil }
    return activeWrite
  }

  private func failQueued(with error: any Error) {
    let queued = queue
    queue.removeAll(keepingCapacity: false)
    queuedBytes = 0
    for write in queued { write.continuation.resume(throwing: error) }
  }
}

public enum InlineProtocolV3ConnectionError: Error, Equatable, Sendable {
  case authorizationInvalidated
  case closed
  case commitOutcomeUnknown
  case invalidKey
  case outboundBufferOverflow
  case protocolFailure
  case requestCapacityExceeded
  /// The authenticated temporary authorization reached its rotation boundary. The owning
  /// transport closes the carrier so the normal reconnect owner can replace and persist it.
  case temporaryAuthorizationRotationDue
  case rpc(RpcError)
  case timeout
  case unexpectedResponse
  case updateBufferOverflow
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
  private typealias PreparedResult = (messageID: Int64, result: [UInt8])
  private typealias PreparedCompletion = @Sendable (Result<PreparedResult, any Error>) async -> Void
  private typealias PreparedAcknowledgement = @Sendable () async -> Void

  private struct PendingRequest {
    let requestToken: UUID
    let sequence: Int32
    let body: [UInt8]
    let completion: PreparedCompletion
    let timeoutTask: Task<Void, Never>?
    var acknowledgement: PreparedAcknowledgement?
  }

  private struct PendingProbe {
    var requestMessageID: Int64
    let sequence: Int32
    let body: [UInt8]
    let continuation: CheckedContinuation<Void, any Error>
    let timeoutTask: Task<Void, Never>?
  }

  private static let rpcResult: UInt32 = 0xf35c6d01
  private static let newSessionCreated: UInt32 = 0x9ec20908
  private static let messagesAck: UInt32 = 0x62d6b459
  private static let badMessage: UInt32 = 0xa7eff811
  private static let badServerSalt: UInt32 = 0xedab447b
  private static let vector: UInt32 = 0x1cb5c415
  private static let boolTrue: UInt32 = 0x997275b5
  private static let ping: UInt32 = 0x7abe77ec
  private static let pong: UInt32 = 0x347773c5
  private static let applicationRequestTimeout: Duration = .seconds(45)
  private static let temporaryKeyLifetimeMilliseconds: Int64 = 86_400_000
  private static let temporaryKeyRotationMilliseconds: Int64 = temporaryKeyLifetimeMilliseconds * 4 / 5

  private let log = Log.scoped("RealtimeV3.Connection")
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let carrier: InlineObfuscatedClientCarrier
  private let outboundWriter: InlineProtocolOutboundWriter
  private let sessionID: Int64
  private var authorizationValue: InlineProtocolAuthorization
  private var lastMessageID: Int64 = 0
  private var contentCount: Int32 = 0
  private var serverUnixMilliseconds: Int64
  private var monotonicAnchor: TimeInterval
  private nonisolated let updatePipe = InlineProtocolUpdatePipe()
  private var pendingRequests: [Int64: PendingRequest] = [:]
  private var pendingProbes: [Int64: PendingProbe] = [:]
  private var receiveTask: Task<Void, Never>?
  private var terminated = false
  private var terminationErrorValue: InlineProtocolV3ConnectionError?

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
    outboundWriter = InlineProtocolOutboundWriter(outbound: carrier.outbound) { data in
      try await task.send(.data(data))
    }
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
    let closeAttempt: @Sendable () -> Void = {
      task.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }

    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        task.resume()
        try await task.send(.data(Data(carrier.wireHeader)))
        let sessionID = readInt64(try secureRandom(count: 8), at: 0)

        if let authorization = options.authorization {
          try Task.checkCancellation()
          let connection = InlineProtocolV3Connection(
            session: session, task: task, carrier: carrier, sessionID: sessionID,
            authorization: authorization, serverTime: Int32(Date().timeIntervalSince1970)
          )
          await connection.startReceiving()
          return connection
        }

        let handshake = InlineProtocolHandshakeWorker(
          client: InlineHandshakeClient(rsaKeys: options.rsaPublicKeys)
        )
        var request = try await handshake.begin(temporary: options.temporary)
        var lastID: Int64 = 0
        while true {
          try Task.checkCancellation()
          let messageID = try nextSystemMessageID(last: &lastID)
          try await sendPacket(
            encodeUnencrypted(messageID: messageID, body: request),
            carrier: carrier,
            task: task
          )
          let packet = try await receivePacket(carrier: carrier, task: task)
          let response = try decodeUnencrypted(packet)
          switch try await handshake.receive(response) {
          case let .request(next): request = next
          case let .established(authorization, serverTime):
            try Task.checkCancellation()
            let connection = InlineProtocolV3Connection(
              session: session, task: task, carrier: carrier, sessionID: sessionID,
              authorization: authorization, serverTime: serverTime, lastMessageID: lastID
            )
            await connection.startReceiving()
            return connection
          }
        }
      } catch {
        closeAttempt()
        throw error
      }
    } onCancel: {
      closeAttempt()
    }
  }

  public var authorization: InlineProtocolAuthorization { authorizationValue }
  public var terminationError: InlineProtocolV3ConnectionError? { terminationErrorValue }
  public nonisolated var updates: AsyncStream<RealtimeV3Update> { updatePipe.stream() }

  /// Uses the authenticated server sample plus monotonic elapsed time; local wall-clock jumps do
  /// not cause a valid temporary key to rotate early or late.
  public static func temporaryAuthorizationNeedsRotation(
    expiresAt: Int32,
    authenticatedServerNowMilliseconds: Int64
  ) -> Bool {
    temporaryAuthorizationRotationRemainingMilliseconds(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: authenticatedServerNowMilliseconds
    ) <= 0
  }

  /// Returns the authenticated-server milliseconds until the 80% rotation boundary.
  /// A non-positive value means that new application requests must not be admitted.
  public static func temporaryAuthorizationRotationRemainingMilliseconds(
    expiresAt: Int32,
    authenticatedServerNowMilliseconds: Int64
  ) -> Int64 {
    Int64(expiresAt) * 1_000 - temporaryKeyRotationMilliseconds - authenticatedServerNowMilliseconds
  }

  /// Must be checked after an authenticated probe has sampled the peer's current message ID.
  public func temporaryAuthorizationNeedsRotation() -> Bool {
    guard authorizationValue.temporary, let expiresAt = authorizationValue.expiresAt else { return false }
    return Self.temporaryAuthorizationNeedsRotation(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: serverNowMilliseconds()
    )
  }

  /// Uses only the authenticated server sample and monotonic elapsed time. The transport uses
  /// this to wake its rotation owner; the request admission gate below remains authoritative if
  /// a newer authenticated record advances the clock while the task is asleep.
  public func temporaryAuthorizationRotationDelay() -> Duration? {
    guard authorizationValue.temporary, let expiresAt = authorizationValue.expiresAt else { return nil }
    let milliseconds = Self.temporaryAuthorizationRotationRemainingMilliseconds(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: serverNowMilliseconds()
    )
    return .milliseconds(Int(max(0, milliseconds)))
  }

  /// Waits for already-admitted low-level requests to finish for a bounded period. This is not
  /// a multipart-operation lease: uploads may still surface commit-unknown and must reconcile via
  /// their stable client upload identity after reconnect.
  public func waitForPendingRequestsToSettle() async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while !pendingRequests.isEmpty && clock.now < deadline {
      try? await clock.sleep(for: .milliseconds(100))
    }
  }

  public func close() async {
    await terminate(with: InlineProtocolV3ConnectionError.closed, closeCode: .normalClosure)
  }

  public func invoke(_ request: RealtimeV3Request) async throws -> RealtimeV3Response {
    let requestToken = UUID()
    let cancellationState = InlineProtocolRequestCancellationState()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        Task {
          do {
            try await self.beginInvoke(
              request,
              requestToken: requestToken,
              cancellationState: cancellationState
            ) { result in
              continuation.resume(with: result)
            }
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellationState.cancel()
      Task { [weak self] in
        await self?.cancelPending(requestToken: requestToken)
      }
    }
  }

  /// Starts an application request and returns after its encrypted record has been written.
  /// The independently multiplexed response is delivered through `completion`.
  public func beginInvoke(
    _ request: RealtimeV3Request,
    acknowledged: (@Sendable () async -> Void)? = nil,
    completion: @escaping @Sendable (Result<RealtimeV3Response, any Error>) async -> Void
  ) async throws {
    try await beginInvoke(
      request,
      requestToken: UUID(),
      cancellationState: nil,
      acknowledged: acknowledged,
      completion: completion
    )
  }

  private func beginInvoke(
    _ request: RealtimeV3Request,
    requestToken: UUID,
    cancellationState: InlineProtocolRequestCancellationState?,
    acknowledged: (@Sendable () async -> Void)? = nil,
    completion: @escaping @Sendable (Result<RealtimeV3Response, any Error>) async -> Void
  ) async throws {
    let body = try InlineSecureTransport.encodeInlineInvoke(payload: Array(request.serializedData()))
    try await beginPrepared(
      messageID: nextMessageID(),
      sequence: nextSequence(content: true),
      body: body,
      requestToken: requestToken,
      cancellationState: cancellationState,
      acknowledged: acknowledged
    ) { result in
      switch result {
      case let .success(prepared):
        do {
          if try InlineSecureTransport.decodeTLRPCError(prepared.result)?.code == 504 {
            await completion(.failure(InlineProtocolV3ConnectionError.commitOutcomeUnknown))
            return
          }
          guard case let .result(payload) = try InlineSecureTransport
            .decodeInlineApplicationObject(prepared.result)
          else {
            throw InlineProtocolV3ConnectionError.unexpectedResponse
          }
          await completion(.success(try RealtimeV3Response(serializedBytes: payload)))
        } catch {
          await completion(.failure(error))
        }
      case let .failure(error):
        await completion(.failure(error))
      }
    }
  }

  public func authBegin(_ request: AuthBeginRequest) async throws -> AuthBeginResult {
    var envelope = RealtimeV3Request()
    envelope.body = .authBegin(request)
    switch try await invoke(envelope).body {
    case let .authBegin(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func authComplete(_ request: AuthCompleteRequest) async throws -> AuthCompleteResult {
    var envelope = RealtimeV3Request()
    envelope.body = .authComplete(request)
    switch try await invoke(envelope).body {
    case let .authComplete(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func callRPC(_ request: RpcCall) async throws -> RpcResult {
    var envelope = RealtimeV3Request()
    envelope.body = .rpc(request)
    switch try await invoke(envelope).body {
    case let .rpcResult(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func createHTTPUpload(_ request: CreateHttpUploadRequest) async throws -> CreateHttpUploadResult {
    var envelope = RealtimeV3Request()
    envelope.body = .createHTTPUpload(request)
    switch try await invoke(envelope).body {
    case let .createHTTPUpload(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error)
    default: throw InlineProtocolV3ConnectionError.unexpectedResponse
    }
  }

  public func finishHTTPUpload(_ request: FinishHttpUploadRequest) async throws -> FinishHttpUploadResult {
    var envelope = RealtimeV3Request()
    envelope.body = .finishHTTPUpload(request)
    switch try await invoke(envelope).body {
    case let .finishHTTPUpload(value): return value
    case let .rpcError(error): throw InlineProtocolV3ConnectionError.rpc(error)
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

  /// Proves that the peer currently recognizes this authorization key by round-tripping an
  /// authenticated MTProto ping over the live socket.
  public func verifyAuthorization(
    pingID suppliedPingID: Int64? = nil,
    timeout: Duration? = .seconds(10)
  ) async throws {
    let pingID: Int64
    if let suppliedPingID {
      pingID = suppliedPingID
    } else {
      pingID = readInt64(try Self.secureRandom(count: 8), at: 0)
    }
    guard pendingProbes[pingID] == nil else {
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    let messageID = try nextMessageID()
    let sequence = nextSequence(content: false)
    let body = little(Self.ping) + little(pingID)

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let timeoutTask: Task<Void, Never>? = if let timeout {
          Task { [weak self] in
            do {
              try await Task.sleep(for: timeout)
            } catch {
              return
            }
            await self?.failProbe(pingID: pingID, with: InlineProtocolV3ConnectionError.timeout)
          }
        } else {
          nil
        }
        pendingProbes[pingID] = PendingProbe(
          requestMessageID: messageID,
          sequence: sequence,
          body: body,
          continuation: continuation,
          timeoutTask: timeoutTask
        )
        Task { [weak self] in
          do {
            try await self?.sendEncrypted(
              messageID: messageID,
              sequence: sequence,
              body: body,
              quickAck: true
            )
          } catch {
            await self?.failProbe(pingID: pingID, with: error)
          }
        }
      }
    } onCancel: {
      Task { [weak self] in
        await self?.failProbe(pingID: pingID, with: CancellationError())
      }
    }
  }

  private func sendPrepared(
    messageID initialID: Int64,
    sequence: Int32,
    body: [UInt8]
  ) async throws -> (messageID: Int64, result: [UInt8]) {
    let requestToken = UUID()
    let cancellationState = InlineProtocolRequestCancellationState()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        Task {
          do {
            try await self.beginPrepared(
              messageID: initialID,
              sequence: sequence,
              body: body,
              requestToken: requestToken,
              cancellationState: cancellationState
            ) { result in
              continuation.resume(with: result)
            }
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellationState.cancel()
      Task { [weak self] in
        await self?.cancelPending(requestToken: requestToken)
      }
    }
  }

  /// Registers response ownership before writing so even an immediate response cannot be lost.
  /// Returning after the write (rather than the response) preserves the transport's multiplexing.
  private func beginPrepared(
    messageID: Int64,
    sequence: Int32,
    body: [UInt8],
    requestToken: UUID = UUID(),
    cancellationState: InlineProtocolRequestCancellationState? = nil,
    acknowledged: PreparedAcknowledgement? = nil,
    completion: @escaping PreparedCompletion
  ) async throws {
    if cancellationState?.isCancelled == true { throw CancellationError() }
    guard !temporaryAuthorizationNeedsRotation() else {
      throw InlineProtocolV3ConnectionError.temporaryAuthorizationRotationDue
    }
    guard pendingRequests.count < 64 else {
      throw InlineProtocolV3ConnectionError.requestCapacityExceeded
    }
    guard pendingRequests[messageID] == nil else {
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.applicationRequestTimeout)
      } catch {
        return
      }
      await self?.requestTimedOut(requestToken: requestToken)
    }
    pendingRequests[messageID] = PendingRequest(
      requestToken: requestToken,
      sequence: sequence,
      body: body,
      completion: completion,
      timeoutTask: timeoutTask,
      acknowledgement: acknowledged
    )
    do {
      try await sendEncrypted(messageID: messageID, sequence: sequence, body: body, quickAck: true)
    } catch {
      // A terminal writer failure completes all pending requests during termination. Avoid
      // completing the same waiter twice if that path won the race with this catch.
      guard let pending = pendingRequests.removeValue(forKey: messageID) else { return }
      pending.timeoutTask?.cancel()
      throw error
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
    if constructor != Self.pong,
       constructor != Self.badMessage,
       constructor != Self.badServerSalt
    {
      satisfyPendingProbesWithAuthenticatedTraffic()
    }
    switch constructor {
    case Self.newSessionCreated:
      guard fields.body.count >= 28 else { throw InlineProtocolV3ConnectionError.protocolFailure }
      authorizationValue.serverSalt = readInt64(fields.body, at: 20)
    case Self.messagesAck:
      guard fields.body.count >= 12,
            try readUInt32(fields.body, at: 4) == Self.vector
      else { throw InlineProtocolV3ConnectionError.protocolFailure }
      let count = readInt32(fields.body, at: 8)
      guard count >= 0, fields.body.count == 12 + Int(count) * 8 else {
        throw InlineProtocolV3ConnectionError.protocolFailure
      }
      for index in 0 ..< Int(count) {
        await acknowledgePending(messageID: readInt64(fields.body, at: 12 + index * 8))
      }
      return
    case Self.pong:
      guard fields.body.count == 20 else { throw InlineProtocolV3ConnectionError.protocolFailure }
      let requestMessageID = readInt64(fields.body, at: 4)
      let pingID = readInt64(fields.body, at: 12)
      guard let probe = pendingProbes.removeValue(forKey: pingID) else { return }
      probe.timeoutTask?.cancel()
      guard probe.requestMessageID == requestMessageID else {
        probe.continuation.resume(throwing: InlineProtocolV3ConnectionError.protocolFailure)
        throw InlineProtocolV3ConnectionError.protocolFailure
      }
      probe.continuation.resume()
    case Self.badMessage, Self.badServerSalt:
      try await recoverBadMessage(fields, constructor: constructor)
    case Self.rpcResult:
      guard fields.body.count >= 12 else { throw InlineProtocolV3ConnectionError.protocolFailure }
      let requestID = readInt64(fields.body, at: 4)
      guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
      pending.timeoutTask?.cancel()
      deliver(pending, .success((requestID, Array(fields.body.dropFirst(12)))))
    default:
      let application: InlineApplicationObject
      do {
        application = try InlineSecureTransport.decodeInlineApplicationObject(fields.body)
      } catch {
        // Authenticated service constructors added by newer peers are non-critical unless this
        // client recognizes them. Ignore them without weakening record authentication.
        log.warning("Ignoring unknown authenticated Inline Protocol service message")
        return
      }
      guard case let .update(payload) = application else { return }
      let update: RealtimeV3Update
      do {
        update = try RealtimeV3Update(serializedBytes: payload)
      } catch {
        throw InlineProtocolV3ConnectionError.protocolFailure
      }
      guard updatePipe.yield(update) else {
        throw InlineProtocolV3ConnectionError.updateBufferOverflow
      }
    }
  }

  private func recoverBadMessage(
    _ fields: InlineEncryptedRecordFields,
    constructor: UInt32
  ) async throws {
    guard fields.body.count >= 20 else { throw InlineProtocolV3ConnectionError.protocolFailure }
    let requestID = readInt64(fields.body, at: 4)
    let sequence = readInt32(fields.body, at: 12)
    if let pending = pendingRequests.removeValue(forKey: requestID) {
      guard pending.sequence == sequence else {
        pending.timeoutTask?.cancel()
        deliver(pending, .failure(InlineProtocolV3ConnectionError.protocolFailure))
        throw InlineProtocolV3ConnectionError.protocolFailure
      }
      try await recoverBadRequest(
        pending,
        fields: fields,
        constructor: constructor
      )
      return
    }
    guard let probeEntry = pendingProbes.first(where: {
      $0.value.requestMessageID == requestID
    }) else {
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    let pingID = probeEntry.key
    var probe = pendingProbes.removeValue(forKey: pingID)!
    guard probe.sequence == sequence else {
      probe.timeoutTask?.cancel()
      probe.continuation.resume(throwing: InlineProtocolV3ConnectionError.protocolFailure)
      throw InlineProtocolV3ConnectionError.protocolFailure
    }
    guard try recoverBadMessageState(fields, constructor: constructor) else {
      probe.timeoutTask?.cancel()
      probe.continuation.resume(throwing: InlineProtocolV3ConnectionError.protocolFailure)
      return
    }
    probe.requestMessageID = try nextMessageID()
    pendingProbes[pingID] = probe
    do {
      try await sendEncrypted(
        messageID: probe.requestMessageID,
        sequence: probe.sequence,
        body: probe.body,
        quickAck: true
      )
    } catch {
      await failProbe(pingID: pingID, with: error)
    }
  }

  private func recoverBadRequest(
    _ pending: PendingRequest,
    fields: InlineEncryptedRecordFields,
    constructor: UInt32
  ) async throws {
    guard try recoverBadMessageState(fields, constructor: constructor) else {
      pending.timeoutTask?.cancel()
      deliver(pending, .failure(InlineProtocolV3ConnectionError.protocolFailure))
      return
    }
    let replacementID = try nextMessageID()
    pendingRequests[replacementID] = pending
    do {
      try await sendEncrypted(
        messageID: replacementID, sequence: pending.sequence, body: pending.body, quickAck: true
      )
    } catch {
      await failPending(messageID: replacementID, with: error)
    }
  }

  private func recoverBadMessageState(
    _ fields: InlineEncryptedRecordFields,
    constructor: UInt32
  ) throws -> Bool {
    let code = readInt32(fields.body, at: 16)
    if code == 16 || code == 17 {
      sample(messageID: fields.messageID)
    } else if code == 48, constructor == Self.badServerSalt, fields.body.count >= 28 {
      authorizationValue.serverSalt = readInt64(fields.body, at: 20)
    } else {
      return false
    }
    return true
  }

  private func receiveFailed(_ error: any Error) async {
    let failure: any Error = if task.closeCode.rawValue == 4401 {
      InlineProtocolV3ConnectionError.authorizationInvalidated
    } else {
      error
    }
    await terminate(with: failure, closeCode: .goingAway)
  }

  private func failPending(messageID: Int64, with error: any Error) async {
    guard let pending = pendingRequests.removeValue(forKey: messageID) else { return }
    pending.timeoutTask?.cancel()
    deliver(pending, .failure(error))
  }

  private func cancelPending(requestToken: UUID) async {
    guard let entry = pendingRequests.first(where: { $0.value.requestToken == requestToken }) else {
      return
    }
    let pending = pendingRequests.removeValue(forKey: entry.key)!
    pending.timeoutTask?.cancel()
    deliver(pending, .failure(CancellationError()))
  }

  private func requestTimedOut(requestToken: UUID) async {
    guard let entry = pendingRequests.first(where: { $0.value.requestToken == requestToken }) else {
      return
    }
    let pending = pendingRequests.removeValue(forKey: entry.key)!
    pending.timeoutTask?.cancel()
    log.error("Application request timed out; terminating connection")
    deliver(pending, .failure(InlineProtocolV3ConnectionError.timeout))
    await terminate(with: InlineProtocolV3ConnectionError.timeout, closeCode: .goingAway)
  }

  private func acknowledgePending(messageID: Int64) async {
    guard var pending = pendingRequests[messageID],
          let acknowledgement = pending.acknowledgement
    else { return }
    pending.acknowledgement = nil
    pendingRequests[messageID] = pending
    Task { await acknowledgement() }
  }

  private func failPending(with error: any Error) async {
    let pending = pendingRequests.values
    pendingRequests.removeAll()
    for request in pending {
      request.timeoutTask?.cancel()
      deliver(request, .failure(error))
    }
    let probes = pendingProbes.values
    pendingProbes.removeAll()
    for probe in probes {
      probe.timeoutTask?.cancel()
      probe.continuation.resume(throwing: error)
    }
  }

  /// Application callbacks must not hold the secure receive actor. A slow transaction or host
  /// listener is isolated to its own task after this actor has removed exactly-once ownership.
  private func deliver(_ pending: PendingRequest, _ result: Result<PreparedResult, any Error>) {
    Task { await pending.completion(result) }
  }

  /// A successfully decrypted server record proves that the authenticated connection is alive.
  /// This mirrors Telegram's liveness contract and avoids killing a busy connection merely
  /// because an exact pong was delayed behind other authenticated traffic.
  private func satisfyPendingProbesWithAuthenticatedTraffic() {
    guard !pendingProbes.isEmpty else { return }
    let probes = pendingProbes.values
    pendingProbes.removeAll()
    log.debug("Authorization probe satisfied by authenticated traffic count=\(probes.count)")
    for probe in probes {
      probe.timeoutTask?.cancel()
      probe.continuation.resume()
    }
  }

  private func failProbe(pingID: Int64, with error: any Error) async {
    guard let probe = pendingProbes.removeValue(forKey: pingID) else { return }
    probe.timeoutTask?.cancel()
    probe.continuation.resume(throwing: error)
    if error as? InlineProtocolV3ConnectionError == .timeout {
      await terminate(with: error, closeCode: .goingAway)
    }
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
    guard !terminated else { throw InlineProtocolV3ConnectionError.closed }
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
    do {
      try await sendPacket(record, quickAck: quickAck)
    } catch {
      await terminate(with: error, closeCode: .goingAway)
      throw error
    }
  }

  private func sendPacket(_ packet: [UInt8], quickAck: Bool = false) async throws {
    try await outboundWriter.send(packet, quickAck: quickAck)
  }

  private func terminate(
    with error: any Error,
    closeCode: URLSessionWebSocketTask.CloseCode
  ) async {
    guard !terminated else { return }
    terminated = true
    terminationErrorValue = error as? InlineProtocolV3ConnectionError ?? .closed
    let pendingRPCCount = pendingRequests.count
    let pendingProbeCount = pendingProbes.count
    let queuedWriteCount = await outboundWriter.queuedWriteCount
    if closeCode == .normalClosure {
      log.info(
        "Connection closed pending_rpc=\(pendingRPCCount) pending_probe=\(pendingProbeCount) queued_write=\(queuedWriteCount)"
      )
    } else {
      log.error(
        "Connection failed pending_rpc=\(pendingRPCCount) pending_probe=\(pendingProbeCount) queued_write=\(queuedWriteCount)",
        error: error
      )
    }
    receiveTask?.cancel()
    receiveTask = nil
    await outboundWriter.close(with: error)
    await failPending(with: error)
    updatePipe.finish()
    task.cancel(with: closeCode, reason: nil)
    session.invalidateAndCancel()
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
