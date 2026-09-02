import Auth
import Foundation
import InlineProtocol
import RealtimeV2
import Testing
@testable import InlineKit

private actor SuspendedNativeLoginConnection: InlineProtocolNativeLoginConnection {
  private let authorization: InlineProtocolAuthorization
  private var authCompleteContinuation: CheckedContinuation<AuthCompleteResult, any Error>?
  private var authCompleteStarted = false
  private var authCompleteWaiters: [CheckedContinuation<Void, Never>] = []
  private var closeCalls = 0

  init(authorization: InlineProtocolAuthorization) {
    self.authorization = authorization
  }

  func authBegin(_: AuthBeginRequest) -> AuthBeginResult {
    var result = AuthBeginResult()
    result.challengeID = Data(repeating: 7, count: 32)
    result.delivery = .email
    return result
  }

  func authComplete(_: AuthCompleteRequest) async throws -> AuthCompleteResult {
    authCompleteStarted = true
    for waiter in authCompleteWaiters { waiter.resume() }
    authCompleteWaiters.removeAll()
    return try await withCheckedThrowingContinuation { continuation in
      authCompleteContinuation = continuation
    }
  }

  func waitForAuthComplete() async {
    if authCompleteStarted { return }
    await withCheckedContinuation { continuation in
      authCompleteWaiters.append(continuation)
    }
  }

  func authorizeAfterCancellation() {
    var user = InlineProtocol.User()
    user.id = 42
    var authorized = AuthAuthorized()
    authorized.user = user
    authorized.accountSessionID = 77
    var result = AuthCompleteResult()
    result.authorized = authorized
    authCompleteContinuation?.resume(returning: result)
    authCompleteContinuation = nil
  }

  func nativeLoginAuthorization() -> InlineProtocolAuthorization { authorization }
  func bindNativeLoginTemporary(to _: InlineProtocolAuthorization) async throws {}
  func verifyNativeLoginAuthorization() async throws {}
  func close() { closeCalls += 1 }
  func closeCount() -> Int { closeCalls }
}

private actor NativeLoginConnectionFactory {
  let connection: SuspendedNativeLoginConnection
  private var calls = 0

  init(connection: SuspendedNativeLoginConnection) {
    self.connection = connection
  }

  func connect(_: InlineProtocolV3Options) -> any InlineProtocolNativeLoginConnection {
    calls += 1
    return connection
  }

  func callCount() -> Int { calls }
}

private actor SuccessfulNativeLoginConnection: InlineProtocolNativeLoginConnection {
  private let authorization: InlineProtocolAuthorization

  init(authorization: InlineProtocolAuthorization) {
    self.authorization = authorization
  }

  func authBegin(_: AuthBeginRequest) -> AuthBeginResult {
    var result = AuthBeginResult()
    result.challengeID = Data(repeating: 8, count: 32)
    result.delivery = .email
    return result
  }

  func authComplete(_: AuthCompleteRequest) -> AuthCompleteResult {
    var user = InlineProtocol.User()
    user.id = 42
    var authorized = AuthAuthorized()
    authorized.user = user
    authorized.accountSessionID = 77
    var result = AuthCompleteResult()
    result.authorized = authorized
    return result
  }

  func nativeLoginAuthorization() -> InlineProtocolAuthorization { authorization }
  func bindNativeLoginTemporary(to _: InlineProtocolAuthorization) async throws {}
  func verifyNativeLoginAuthorization() async throws {}
  func close() {}
}

private actor SuccessfulNativeLoginConnectionFactory {
  private var connections: [SuccessfulNativeLoginConnection]

  init(_ connections: [SuccessfulNativeLoginConnection]) {
    self.connections = connections
  }

  func connect(_: InlineProtocolV3Options) throws -> any InlineProtocolNativeLoginConnection {
    try #require(connections.isEmpty == false)
    return connections.removeFirst()
  }
}

private actor CredentialStorageProbe {
  private var prepared = false

  func markPrepared() { prepared = true }
  func wasPrepared() -> Bool { prepared }
}

private actor NativeLoginPostCommitGate {
  private var committed = false
  private var committedWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func suspendAfterCommit() async {
    committed = true
    for waiter in committedWaiters { waiter.resume() }
    committedWaiters.removeAll()
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilCommitted() async {
    if committed { return }
    await withCheckedContinuation { continuation in
      committedWaiters.append(continuation)
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private enum CredentialStoragePreparationTestError: Error {
  case unavailable
}

@Suite("Inline Protocol native login")
struct InlineProtocolNativeLoginTests {
  @Test("login failure messages preserve recovery instructions without exposing unknown error details")
  func loginFailureMessagesAreActionableAndSafe() {
    #expect(InlineProtocolNativeLogin.userFacingMessage(for: AuthStorageError.logoutInProgress)
      == AuthStorageError.logoutInProgress.localizedDescription)
    #expect(InlineProtocolNativeLogin.userFacingMessage(for: InlineProtocolNativeLoginError.noPendingChallenge)
      == InlineProtocolNativeLoginError.noPendingChallenge.localizedDescription)
    #expect(InlineProtocolNativeLogin.userFacingMessage(for: RealtimeDirectRpcError.notConnected)
      == RealtimeDirectRpcError.notConnected.localizedDescription)
    let unexpected = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-debug-detail"])
    #expect(!InlineProtocolNativeLogin.userFacingMessage(for: unexpected).contains("private-debug-detail"))
  }

  @Test("native login preserves actionable RPC errors")
  func nativeLoginPreservesRPCError() {
    var rpcError = InlineProtocol.RpcError()
    rpcError.errorCode = .emailInvalid
    rpcError.message = "Email is invalid"
    rpcError.code = 400

    let presented = InlineProtocolNativeLogin.presentationError(
      InlineProtocolV3ConnectionError.rpc(rpcError)
    )

    guard let realtimeError = presented as? RealtimeDirectRpcError,
          case let .rpcError(errorCode, message, code) = realtimeError
    else {
      Issue.record("Expected a typed realtime RPC error")
      return
    }
    #expect(errorCode == .emailInvalid)
    #expect(message == "Email is invalid")
    #expect(code == 400)
    #expect(presented.localizedDescription == "Email is invalid")
  }

  @Test("native login presents pre-execution rejection as retryable capacity pressure")
  func nativeLoginPresentsPreExecutionRejection() {
    let presented = InlineProtocolNativeLogin.presentationError(
      InlineProtocolV3ConnectionError.rejectedBeforeExecution
    )

    guard case RealtimeDirectRpcError.capacityExceeded = presented else {
      Issue.record("Expected capacity pressure for a request proven not to have executed")
      return
    }
  }

  @Test("native completion invokes the injected local commit boundary before returning")
  func invokesInjectedCommitBoundary() async throws {
    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: "42:legacy", userId: 42)
    let permanent = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: false)
    )
    let temporary = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: true)
    )
    let factory = SuccessfulNativeLoginConnectionFactory([permanent, temporary])
    let probe = CredentialStorageProbe()
    let login = InlineProtocolNativeLogin(
      auth: auth.handle,
      url: URL(string: "ws://inline.test/realtime/v3")!,
      rsaPublicKeys: [try publicKey()],
      connect: { options in try await factory.connect(options) },
      commitLoginState: { _, _, _, _ in
        #expect(auth.handle.token() == "42:legacy")
        #expect(auth.handle.inlineProtocolCredentials() == nil)
        await probe.markPrepared()
        return try auth.handle.beginAccountMutation()
      }
    )

    _ = try await login.beginEmail("test@example.com")
    _ = try await login.complete(code: "123456")

    #expect(await probe.wasPrepared())
    #expect(auth.handle.token() == "42:legacy")
    #expect(auth.handle.inlineProtocolCredentials() == nil)
  }

  @Test("native cancellation after durable commit preserves the successful account")
  func cancellationAfterDurableCommitPreservesSuccess() async throws {
    let auth = Auth.mocked(authenticated: false)
    let permanent = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: false)
    )
    let temporary = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: true)
    )
    let factory = SuccessfulNativeLoginConnectionFactory([permanent, temporary])
    let gate = NativeLoginPostCommitGate()
    let login = InlineProtocolNativeLogin(
      auth: auth.handle,
      url: URL(string: "ws://inline.test/realtime/v3")!,
      rsaPublicKeys: [try publicKey()],
      connect: { options in try await factory.connect(options) },
      commitLoginState: { _, credentials, loginAttempt, _ in
        try await auth.saveInlineProtocolCredentials(
          credentials,
          loginAttempt: loginAttempt
        )
        let token = try await auth.handle.finalizeCredentialsCommittedByLoginAttempt(loginAttempt)
        await gate.suspendAfterCommit()
        return token
      }
    )

    _ = try await login.beginEmail("test@example.com")
    let completion = Task { try await login.complete(code: "123456") }
    await gate.waitUntilCommitted()
    await login.cancel()
    await gate.release()

    let result = try await completion.value
    #expect(result.userId == 42)
    #expect(auth.handle.inlineProtocolCredentials()?.userId == 42)
    try auth.handle.validateAccountMutation(result.accountMutationToken)
  }

  @Test("preserves bearer credentials when durable database preparation fails")
  func databasePreparationFailurePreservesBearerCredentials() async throws {
    let auth = Auth.mocked(authenticated: false)
    try await auth.saveCredentials(token: "42:legacy", userId: 42)
    let permanent = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: false)
    )
    let temporary = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: true)
    )
    let factory = SuccessfulNativeLoginConnectionFactory([permanent, temporary])
    let login = InlineProtocolNativeLogin(
      auth: auth.handle,
      url: URL(string: "ws://inline.test/realtime/v3")!,
      rsaPublicKeys: [try publicKey()],
      connect: { options in try await factory.connect(options) },
      commitLoginState: { _, _, _, _ in
        throw CredentialStoragePreparationTestError.unavailable
      }
    )

    _ = try await login.beginEmail("test@example.com")
    do {
      _ = try await login.complete(code: "123456")
      Issue.record("Expected credential storage preparation to fail")
    } catch let RealtimeDirectRpcError.unknown(underlying) {
      #expect(underlying is CredentialStoragePreparationTestError)
    } catch {
      Issue.record("Expected the preparation failure to cross the presentation boundary")
    }

    #expect(auth.handle.token() == "42:legacy")
    #expect(auth.handle.inlineProtocolCredentials() == nil)
  }

  @Test("logout fence remains typed when native credential commit is rejected")
  func logoutFenceRejectsNativeCredentialCommit() async throws {
    let auth = Auth.mocked(authenticated: false)
    let permanent = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: false)
    )
    let temporary = SuccessfulNativeLoginConnection(
      authorization: try authorization(temporary: true)
    )
    let factory = SuccessfulNativeLoginConnectionFactory([permanent, temporary])
    let login = InlineProtocolNativeLogin(
      auth: auth.handle,
      url: URL(string: "ws://inline.test/realtime/v3")!,
      rsaPublicKeys: [try publicKey()],
      connect: { options in try await factory.connect(options) }
    )

    _ = try await login.beginEmail("test@example.com")
    _ = try await auth.beginLogout()

    do {
      _ = try await login.complete(code: "123456")
      Issue.record("Expected the logout fence to reject native credential persistence")
    } catch AuthStorageError.logoutInProgress {
      // Preserve the actionable transition error instead of wrapping it as unknown.
    } catch {
      Issue.record("Unexpected native credential commit error: \(error)")
    }

    #expect(auth.handle.inlineProtocolCredentials() == nil)

    do {
      _ = try await login.complete(code: "123456")
      Issue.record("Expected the completed challenge to be explicitly expired")
    } catch let error as InlineProtocolNativeLoginError {
      #expect(error == .noPendingChallenge)
      #expect(error.localizedDescription.contains("request a new code"))
    } catch {
      Issue.record("Expected an actionable expired-challenge error")
    }
  }

  @Test("temporary authorization rotation uses the exact authenticated 80 percent boundary")
  func temporaryAuthorizationRotationBoundary() {
    let expiresAt: Int32 = 2_000_086_400
    let boundary = Int64(expiresAt) * 1_000 - 69_120_000
    #expect(!InlineProtocolV3Connection.temporaryAuthorizationNeedsRotation(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: boundary - 1
    ))
    #expect(InlineProtocolV3Connection.temporaryAuthorizationRotationRemainingMilliseconds(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: boundary - 1
    ) == 1)
    #expect(InlineProtocolV3Connection.temporaryAuthorizationNeedsRotation(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: boundary
    ))
    #expect(InlineProtocolV3Connection.temporaryAuthorizationRotationRemainingMilliseconds(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: boundary
    ) == 0)
    // A local wall-clock jump is intentionally absent from this decision; only the authenticated
    // server sample and monotonic elapsed time are inputs.
    #expect(!InlineProtocolV3Connection.temporaryAuthorizationNeedsRotation(
      expiresAt: expiresAt,
      authenticatedServerNowMilliseconds: boundary - 1
    ))
  }

  @Test("permanent authorizations never schedule temporary-key rotation")
  func permanentAuthorizationHasNoRotationDeadline() throws {
    let authorization = try authorization(temporary: false)
    #expect(authorization.expiresAt == nil)
  }

  @Test("cancellation fences a late authorization response before credential storage")
  func cancellationFencesLateAuthorization() async throws {
    let auth = Auth.mocked(authenticated: false)
    let permanent = try authorization(temporary: false)
    let connection = SuspendedNativeLoginConnection(authorization: permanent)
    let factory = NativeLoginConnectionFactory(connection: connection)
    let login = InlineProtocolNativeLogin(
      auth: auth.handle,
      url: URL(string: "ws://inline.test/realtime/v3")!,
      rsaPublicKeys: [try publicKey()],
      connect: { options in await factory.connect(options) }
    )

    _ = try await login.beginEmail("test@example.com")
    let completion = Task { try await login.complete(code: "123456") }
    await connection.waitForAuthComplete()
    await login.cancel()
    await connection.authorizeAfterCancellation()

    guard case let .failure(error) = await completion.result else {
      Issue.record("Expected native login completion to be cancelled")
      return
    }
    #expect(error is CancellationError)
    #expect(auth.handle.inlineProtocolCredentials() == nil)
    #expect(await connection.closeCount() == 1)
    #expect(await factory.callCount() == 1)
  }

  private func authorization(temporary: Bool) throws -> InlineProtocolAuthorization {
    let key = [UInt8](repeating: temporary ? 0x41 : 0x31, count: 256)
    return try InlineProtocolAuthorization(
      key: key,
      keyID: InlineSecureTransport.authKeyID(key),
      serverSalt: 7,
      temporary: temporary,
      expiresAt: temporary ? 1_900_000_000 : nil
    )
  }

  private func publicKey() throws -> InlineProtocolRSAPublicKey {
    let modulus = [UInt8](repeating: 1, count: 256)
    let exponent: [UInt8] = [1, 0, 1]
    return try InlineProtocolRSAPublicKey(
      modulus: modulus,
      exponent: exponent,
      fingerprint: InlineProtocolRSAPublicKey.fingerprint(
        modulus: modulus,
        exponent: exponent
      )
    )
  }
}
