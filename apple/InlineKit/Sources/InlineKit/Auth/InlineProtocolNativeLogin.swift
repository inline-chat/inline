import Auth
import Foundation
import InlineConfig
import InlineProtocol
import Logger
import RealtimeV2

public enum InlineProtocolNativeLoginError: Error, Sendable {
  case unavailable
  case noPendingChallenge
  case inviteRequired
  case invalidResponse
}

public struct InlineProtocolNativeLoginResult: Sendable {
  public let user: InlineProtocol.User
  public let userId: Int64
  public let accountSessionId: Int64
}

protocol InlineProtocolNativeLoginConnection: Sendable {
  func authBegin(_ request: AuthBeginRequest) async throws -> AuthBeginResult
  func authComplete(_ request: AuthCompleteRequest) async throws -> AuthCompleteResult
  func nativeLoginAuthorization() async -> InlineProtocolAuthorization
  func bindNativeLoginTemporary(to permanent: InlineProtocolAuthorization) async throws
  func verifyNativeLoginAuthorization() async throws
  func close() async
}

extension InlineProtocolV3Connection: InlineProtocolNativeLoginConnection {
  func nativeLoginAuthorization() -> InlineProtocolAuthorization { authorization }

  func bindNativeLoginTemporary(to permanent: InlineProtocolAuthorization) async throws {
    try await bindTemporary(to: permanent)
  }

  func verifyNativeLoginAuthorization() async throws {
    try await verifyAuthorization()
  }
}

typealias NativeLoginConnectionFactory = @Sendable (
  InlineProtocolV3Options
) async throws -> any InlineProtocolNativeLoginConnection

public actor InlineProtocolNativeLogin {
  public static let shared = InlineProtocolNativeLogin()

  private struct Pending {
    let generation: UInt64
    let challengeID: Data
    let rsaPublicKeys: [InlineProtocolRSAPublicKey]
    let connection: any InlineProtocolNativeLoginConnection
  }

  private struct CompletionTask {
    let generation: UInt64
    let task: Task<InlineProtocolNativeLoginResult, any Error>
  }

  private let auth: AuthHandle
  private let log = Log.scoped("InlineProtocol.Login")
  private let url: URL
  private let rsaPublicKeys: [InlineProtocolRSAPublicKey]
  private let localDebugTrustHost: String?
  private let connect: NativeLoginConnectionFactory
  private var pending: Pending?
  private var completionTask: CompletionTask?
  private var generation: UInt64 = 0

  public nonisolated var isAvailable: Bool {
    !rsaPublicKeys.isEmpty || InlineProtocolTrustRoots.supportsLocalDebugDiscovery(
      for: url,
      allowedDevelopmentHost: localDebugTrustHost
    )
  }

  public init(
    auth: AuthHandle = Auth.shared.handle,
    url: URL? = nil,
    rsaPublicKeys: [InlineProtocolRSAPublicKey] = InlineProtocolTrustRoots.production
  ) {
    self.auth = auth
    let resolvedURL = url ?? URL(string: InlineConfig.realtimeServerURL.replacingOccurrences(
      of: "/realtime", with: "/realtime/v3"
    ))!
    self.url = resolvedURL
    self.rsaPublicKeys = rsaPublicKeys
    #if DEBUG
    localDebugTrustHost = ProjectConfig.useProductionApi ? nil : ProjectConfig.devHost
    #else
    localDebugTrustHost = nil
    #endif
    connect = { try await InlineProtocolV3Connection.connect($0) }
  }

  init(
    auth: AuthHandle,
    url: URL,
    rsaPublicKeys: [InlineProtocolRSAPublicKey],
    connect: @escaping NativeLoginConnectionFactory
  ) {
    self.auth = auth
    self.url = url
    self.rsaPublicKeys = rsaPublicKeys
    localDebugTrustHost = nil
    self.connect = connect
  }

  @discardableResult
  public func beginEmail(_ email: String, client: ClientInfo = ClientInfo()) async throws -> AuthBeginResult {
    try await begin(identifier: .email(email), client: client)
  }

  @discardableResult
  public func beginPhoneNumber(
    _ phoneNumber: String,
    client: ClientInfo = ClientInfo()
  ) async throws -> AuthBeginResult {
    try await begin(identifier: .phoneNumber(phoneNumber), client: client)
  }

  public func complete(
    code: String,
    inviteCode: String? = nil,
    timeZone: String? = nil
  ) async throws -> InlineProtocolNativeLoginResult {
    guard let pending else { throw InlineProtocolNativeLoginError.noPendingChallenge }
    guard completionTask == nil else { throw InlineProtocolNativeLoginError.invalidResponse }
    var request = AuthCompleteRequest()
    request.challengeID = pending.challengeID
    request.code = code
    if let inviteCode, !inviteCode.isEmpty { request.inviteCode = inviteCode }
    if let timeZone, !timeZone.isEmpty { request.timeZone = timeZone }
    let generation = pending.generation
    let task = Task { [self] in
      try await performComplete(request: request, pending: pending, generation: generation)
    }
    completionTask = CompletionTask(generation: generation, task: task)
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      clearCompletionTask(generation: generation)
      return result
    } catch {
      clearCompletionTask(generation: generation)
      throw Self.presentationError(error)
    }
  }

  private func performComplete(
    request: AuthCompleteRequest,
    pending: Pending,
    generation: UInt64
  ) async throws -> InlineProtocolNativeLoginResult {
    log.info("Native login challenge completion started")
    let result = try await pending.connection.authComplete(request)
    try requireCurrent(generation)
    guard case let .authorized(authorized) = result.state else {
      throw InlineProtocolNativeLoginError.inviteRequired
    }
    log.info("Native login challenge authorized")
    let permanent = await pending.connection.nativeLoginAuthorization()
    try requireCurrent(generation)
    log.info("Creating temporary application authorization")
    var temporaryConnection: (any InlineProtocolNativeLoginConnection)?
    do {
      let connection = try await connect(.init(
        url: url,
        rsaPublicKeys: pending.rsaPublicKeys,
        temporary: true
      ))
      temporaryConnection = connection
      try requireCurrent(generation)
      try await connection.bindNativeLoginTemporary(to: permanent)
      try requireCurrent(generation)
      try await connection.verifyNativeLoginAuthorization()
      try requireCurrent(generation)
      log.info("Temporary application authorization bound")
      let temporary = await connection.nativeLoginAuthorization()
      try requireCurrent(generation)

      // Credential persistence is the commit point. Once it starts, cancellation no longer
      // tears down a session whose authority may already be stored by AuthStore.
      self.pending = nil
      try await auth.saveInlineProtocolCredentials(.init(
        userId: authorized.user.id,
        accountSessionId: authorized.accountSessionID,
        permanent: permanent,
        temporary: temporary
      ))
      log.info("Native login credentials stored")
      await connection.close()
      await pending.connection.close()
      log.info("Native login connections closed")
      return InlineProtocolNativeLoginResult(
        user: authorized.user,
        userId: authorized.user.id,
        accountSessionId: authorized.accountSessionID
      )
    } catch {
      if error is CancellationError {
        log.info("Native login credential setup cancelled")
      } else {
        log.error("Native login credential setup failed", error: error)
      }
      if let temporaryConnection { await temporaryConnection.close() }
      await pending.connection.close()
      if self.pending?.generation == generation { self.pending = nil }
      throw Self.presentationError(error)
    }
  }

  public func cancel() async {
    log.info("Native login cancellation requested")
    let cancelled = pending
    pending = nil
    generation &+= 1
    if completionTask?.generation == cancelled?.generation {
      completionTask?.task.cancel()
      completionTask = nil
    }
    if let cancelled { await cancelled.connection.close() }
  }

  private func begin(
    identifier: AuthBeginRequest.OneOf_Identifier,
    client: ClientInfo
  ) async throws -> AuthBeginResult {
    guard isAvailable else { throw InlineProtocolNativeLoginError.unavailable }
    await cancel()
    let generation = self.generation
    try requireGeneration(generation)
    let resolvedRsaPublicKeys = try await resolveRsaPublicKeys()
    try requireGeneration(generation)
    let fingerprints = resolvedRsaPublicKeys.map { String($0.fingerprint) }.joined(separator: ",")
    log.info(
      "Native login permanent authorization handshake started " +
        "scheme=\(url.scheme ?? "unknown") host=\(url.host ?? "unknown") " +
        "key_count=\(resolvedRsaPublicKeys.count) fingerprints=\(fingerprints)"
    )
    let connection: any InlineProtocolNativeLoginConnection
    do {
      connection = try await connect(.init(
        url: url,
        rsaPublicKeys: resolvedRsaPublicKeys
      ))
    } catch {
      log.error("Native login permanent authorization handshake failed", error: error)
      throw Self.presentationError(error)
    }
    do {
      try requireGeneration(generation)
    } catch {
      await connection.close()
      throw error
    }
    log.info("Native login permanent authorization handshake completed")
    do {
      var request = AuthBeginRequest()
      request.identifier = identifier
      request.client = client
      let result = try await connection.authBegin(request)
      try requireGeneration(generation)
      pending = Pending(
        generation: generation,
        challengeID: result.challengeID,
        rsaPublicKeys: resolvedRsaPublicKeys,
        connection: connection
      )
      log.info("Native login challenge accepted")
      return result
    } catch {
      log.error("Native login challenge start failed", error: error)
      await connection.close()
      throw Self.presentationError(error)
    }
  }

  private func resolveRsaPublicKeys() async throws -> [InlineProtocolRSAPublicKey] {
    if InlineProtocolTrustRoots.supportsLocalDebugDiscovery(
      for: url,
      allowedDevelopmentHost: localDebugTrustHost
    ) {
      log.info(
        "Resolving local Debug Inline Protocol public keys " +
          "host=\(url.host ?? "unknown")"
      )
    }
    return try await InlineProtocolTrustRoots.resolve(
      for: url,
      pinnedKeys: rsaPublicKeys,
      allowedDevelopmentHost: localDebugTrustHost
    )
  }

  private func requireCurrent(_ generation: UInt64) throws {
    try Task.checkCancellation()
    guard self.generation == generation, pending?.generation == generation else {
      throw CancellationError()
    }
  }

  private func requireGeneration(_ generation: UInt64) throws {
    try Task.checkCancellation()
    guard self.generation == generation else { throw CancellationError() }
  }

  private func clearCompletionTask(generation: UInt64) {
    if completionTask?.generation == generation { completionTask = nil }
  }

  static func presentationError(_ error: any Error) -> any Error {
    if error is CancellationError ||
      error is InlineProtocolNativeLoginError ||
      error is RealtimeDirectRpcError {
      return error
    }

    guard let connectionError = error as? InlineProtocolV3ConnectionError else {
      return RealtimeDirectRpcError.unknown(error)
    }

    return switch connectionError {
    case .authorizationInvalidated:
      RealtimeDirectRpcError.notAuthorized
    case .closed, .temporaryAuthorizationRotationDue:
      RealtimeDirectRpcError.notConnected
    case .commitOutcomeUnknown:
      RealtimeDirectRpcError.commitOutcomeUnknown
    case .requestCapacityExceeded:
      RealtimeDirectRpcError.capacityExceeded
    case .timeout:
      RealtimeDirectRpcError.timeout
    case let .rpc(error):
      RealtimeDirectRpcError.rpcError(
        errorCode: error.errorCode,
        message: error.message,
        code: Int(error.code)
      )
    case .invalidKey, .outboundBufferOverflow, .protocolFailure, .unexpectedResponse,
         .updateBufferOverflow:
      RealtimeDirectRpcError.unknown(connectionError)
    }
  }
}
