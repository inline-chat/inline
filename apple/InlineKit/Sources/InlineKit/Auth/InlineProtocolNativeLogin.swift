import Auth
import Foundation
import InlineConfig
import InlineProtocol
import Logger
import RealtimeV2

public enum InlineProtocolNativeLoginError: Error, Equatable, LocalizedError, Sendable,
  PrivacySafeErrorCategoryProviding
{
  case unavailable
  case noPendingChallenge
  case inviteRequired
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "Secure Inline Protocol sign-in is unavailable. Please try again."
    case .noPendingChallenge:
      "This confirmation code session expired. Go back and request a new code."
    case .inviteRequired:
      "An invite code is required to continue."
    case .invalidResponse:
      "Sign-in is already being completed. Please wait or request a new code."
    }
  }

  public var privacySafeErrorCategory: String {
    switch self {
    case .unavailable: "native_login:unavailable"
    case .noPendingChallenge: "native_login:no_pending_challenge"
    case .inviteRequired: "native_login:invite_required"
    case .invalidResponse: "native_login:completion_in_progress"
    }
  }
}

public struct InlineProtocolNativeLoginResult: Sendable {
  public let user: InlineProtocol.User
  public let userId: Int64
  public let accountSessionId: Int64
  public let accountMutationToken: AuthAccountMutationToken
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
typealias NativeLoginStateCommit = @Sendable (
  InlineProtocol.User,
  InlineProtocolSessionCredentials,
  AuthLoginAttempt,
  Int64?
) async throws -> AuthAccountMutationToken

private enum NativeLoginSetupPhase: String, Sendable {
  case temporaryConnection = "temporary_connection"
  case temporaryBinding = "temporary_binding"
  case temporaryVerification = "temporary_verification"
  case localStatePreparation = "local_state_preparation"
  case credentialCommit = "credential_commit"
}

private struct NativeLoginSetupDiagnosticError: Error, LocalizedError, Sendable,
  PrivacySafeErrorCategoryProviding
{
  let phase: NativeLoginSetupPhase
  let reason: String

  init(phase: NativeLoginSetupPhase, error: any Error) {
    self.phase = phase
    reason = error.localizedDescription
  }

  var errorDescription: String? { reason }
  var privacySafeErrorCategory: String { "native_login_setup:\(phase.rawValue)" }
}

public actor InlineProtocolNativeLogin {
  public static let shared = InlineProtocolNativeLogin()

  private struct Pending {
    let generation: UInt64
    let challengeID: Data
    let rsaPublicKeys: [InlineProtocolRSAPublicKey]
    let connection: any InlineProtocolNativeLoginConnection
    let loginAttempt: AuthLoginAttempt
    let existingAuthenticatedUserID: Int64?
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
  private let commitLoginState: NativeLoginStateCommit
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
    commitLoginState = { user, credentials, loginAttempt, existingAuthenticatedUserID in
      let commit = try await LoginStatePreparation.commit(
        auth: auth,
        loginAttempt: loginAttempt,
        targetUserID: user.id,
        existingAuthenticatedUserID: existingAuthenticatedUserID,
        persistCredentials: {
          try await auth.saveInlineProtocolCredentials(
            credentials,
            loginAttempt: loginAttempt
          )
        }
      ) { db in
        try User.save(db, user: user)
      }
      return commit.accountMutationToken
    }
  }

  init(
    auth: AuthHandle,
    url: URL,
    rsaPublicKeys: [InlineProtocolRSAPublicKey],
    connect: @escaping NativeLoginConnectionFactory,
    commitLoginState: NativeLoginStateCommit? = nil
  ) {
    self.auth = auth
    self.url = url
    self.rsaPublicKeys = rsaPublicKeys
    localDebugTrustHost = nil
    self.connect = connect
    self.commitLoginState = commitLoginState ?? { _, credentials, loginAttempt, _ in
      try await auth.saveInlineProtocolCredentials(credentials, loginAttempt: loginAttempt)
      return try await auth.finalizeCredentialsCommittedByLoginAttempt(loginAttempt)
    }
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
    log.info(
      "Native login challenge completion started transition_id=\(pending.loginAttempt.correlationID.uuidString)"
    )
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
    var setupPhase = NativeLoginSetupPhase.temporaryConnection
    do {
      let connection = try await connect(.init(
        url: url,
        rsaPublicKeys: pending.rsaPublicKeys,
        temporary: true
      ))
      temporaryConnection = connection
      try requireCurrent(generation)
      setupPhase = .temporaryBinding
      try await connection.bindNativeLoginTemporary(to: permanent)
      try requireCurrent(generation)
      setupPhase = .temporaryVerification
      try await connection.verifyNativeLoginAuthorization()
      try requireCurrent(generation)
      log.info("Temporary application authorization bound")
      let temporary = await connection.nativeLoginAuthorization()
      try requireCurrent(generation)

      let credentials = InlineProtocolSessionCredentials(
        userId: authorized.user.id,
        accountSessionId: authorized.accountSessionID,
        permanent: permanent,
        temporary: temporary
      )

      // Clear and verify old projection, commit keychain authority, then add the new user's
      // minimum projection through the shared fenced login boundary.
      setupPhase = .localStatePreparation
      let accountMutationToken = try await commitLoginState(
        authorized.user,
        credentials,
        pending.loginAttempt,
        pending.existingAuthenticatedUserID
      )
      setupPhase = .credentialCommit
      self.pending = nil
      log.info("Native login credentials stored")
      // The DB/authority commit is the linearization point. UI cancellation after it must not
      // turn a committed account into a failed login, and temporary connection teardown must not
      // keep the success path spinning behind an uncooperative socket writer.
      _ = Task { [connection, pendingConnection = pending.connection] in
        await connection.close()
        await pendingConnection.close()
      }
      return InlineProtocolNativeLoginResult(
        user: authorized.user,
        userId: authorized.user.id,
        accountSessionId: authorized.accountSessionID,
        accountMutationToken: accountMutationToken
      )
    } catch {
      if error is CancellationError {
        log.info(
          "Native login credential setup cancelled transition_id=\(pending.loginAttempt.correlationID.uuidString)"
        )
      } else {
        log.error(
          "Native login credential setup failed transition_id=\(pending.loginAttempt.correlationID.uuidString) phase=\(setupPhase.rawValue)",
          error: NativeLoginSetupDiagnosticError(phase: setupPhase, error: error)
        )
      }
      _ = auth.cancelLoginAttempt(pending.loginAttempt)
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
    if let cancelled {
      _ = auth.cancelLoginAttempt(cancelled.loginAttempt)
    }
    if let cancelled { await cancelled.connection.close() }
  }

  private func begin(
    identifier: AuthBeginRequest.OneOf_Identifier,
    client: ClientInfo
  ) async throws -> AuthBeginResult {
    guard isAvailable else { throw InlineProtocolNativeLoginError.unavailable }
    await cancel()
    let existingAuthenticatedUserID = auth.isLoggedIn() ? auth.userId() : nil
    let loginAttempt = try await auth.beginLoginAttempt(allowAuthenticated: true)
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
      _ = auth.cancelLoginAttempt(loginAttempt)
      log.error("Native login permanent authorization handshake failed", error: error)
      throw Self.presentationError(error)
    }
    do {
      try requireGeneration(generation)
    } catch {
      _ = auth.cancelLoginAttempt(loginAttempt)
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
        connection: connection,
        loginAttempt: loginAttempt,
        existingAuthenticatedUserID: existingAuthenticatedUserID
      )
      log.info("Native login challenge accepted")
      return result
    } catch {
      _ = auth.cancelLoginAttempt(loginAttempt)
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
      error is AuthStorageError ||
      error is LoginStatePreparationError ||
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
    case .rejectedBeforeExecution, .requestCapacityExceeded:
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
