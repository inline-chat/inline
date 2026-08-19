import Auth
import Foundation
import InlineProtocol
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

@Suite("Inline Protocol native login")
struct InlineProtocolNativeLoginTests {
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
