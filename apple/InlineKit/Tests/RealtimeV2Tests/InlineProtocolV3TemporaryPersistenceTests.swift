@testable import Auth
import Foundation
import InlineProtocol
@testable import RealtimeV2
import Synchronization
import Testing

/// Exercises the production post-verification persistence stage with the real AuthStore.
/// Cryptographic binding and carrier-open acceptance belong to the separate V3 integration tests.
@Suite("V3 verified temporary authorization persistence", .serialized)
struct InlineProtocolV3TemporaryPersistenceTests {
  @Test("a failed renewal write keeps the verified candidate usable without replacing stored authority")
  func failedRenewalKeepsVerifiedCandidate() async throws {
    let fixture = try Fixture(writeSucceeds: false)
    defer { fixture.cleanUp() }
    let original = fixture.auth.snapshot()
    let candidate = try fixture.renewedCredentials()
    let authority = try fixture.auth.beginAccountMutation()

    let persisted = try await InlineProtocolV3Transport.persistVerifiedTemporaryAuthorization(
      candidate, auth: fixture.auth, authority: authority, bearerToken: nil
    )

    #expect(!persisted)
    #expect(candidate.temporary != original.inlineProtocol?.temporary)
    #expect(fixture.auth.snapshot() == original)
    #expect(try fixture.storedCredentials() == original.inlineProtocol)
    #expect(fixture.auth.isLoggedIn())
    #expect(!fixture.auth.hasPendingAccountTransition())
    try fixture.auth.validateAccountMutation(authority)
  }

  @Test("a successful renewal remains durable")
  func successfulRenewalIsPersisted() async throws {
    let fixture = try Fixture(writeSucceeds: true)
    defer { fixture.cleanUp() }
    let candidate = try fixture.renewedCredentials()

    let persisted = try await InlineProtocolV3Transport.persistVerifiedTemporaryAuthorization(
      candidate, auth: fixture.auth, authority: fixture.auth.beginAccountMutation(), bearerToken: nil
    )

    #expect(persisted)
    #expect(fixture.auth.snapshot().inlineProtocol == candidate)
    #expect(try fixture.storedCredentials() == candidate)
  }

  @Test("a replacement permanent authority cannot inherit the old renewal after a failed write")
  func replacementDuringWriteIsRejected() async throws {
    let fixture = try Fixture(writeSucceeds: false)
    defer { fixture.cleanUp() }
    let candidate = try fixture.renewedCredentials()
    let authority = try fixture.auth.beginAccountMutation()
    var replacement = candidate
    replacement.permanent = try Fixture.key(byte: 9)
    let replacementSnapshot = AuthSnapshot(
      status: .authenticatedV3(userId: replacement.userId), didHydrate: true, inlineProtocol: replacement
    )
    fixture.onWrite.action.withLock { action in
      action = { _ = fixture.cache.update(replacementSnapshot) }
    }

    await #expect(throws: AuthStorageError.loginSuperseded) {
      try await InlineProtocolV3Transport.persistVerifiedTemporaryAuthorization(
        candidate, auth: fixture.auth, authority: authority, bearerToken: nil
      )
    }
    #expect(fixture.auth.snapshot() == replacementSnapshot)
  }

  @Test("logout beginning during a failed write still retires the renewal")
  func logoutDuringWriteIsRejected() async throws {
    let fixture = try Fixture(writeSucceeds: false)
    defer { fixture.cleanUp() }
    let candidate = try fixture.renewedCredentials()
    let authority = try fixture.auth.beginAccountMutation()
    fixture.onWrite.action.withLock { action in
      action = { _ = try? fixture.store.beginLogoutSynchronously() }
    }

    await #expect(throws: AuthStorageError.logoutInProgress) {
      try await InlineProtocolV3Transport.persistVerifiedTemporaryAuthorization(
        candidate, auth: fixture.auth, authority: authority, bearerToken: nil
      )
    }
    #expect(fixture.auth.hasPendingLogout())
  }

  @Test("cancellation during a failed write still retires the renewal")
  func cancellationDuringWriteIsRejected() async throws {
    let fixture = try Fixture(writeSucceeds: false)
    defer { fixture.cleanUp() }
    let candidate = try fixture.renewedCredentials()
    let authority = try fixture.auth.beginAccountMutation()
    fixture.onWrite.action.withLock { action in
      action = { withUnsafeCurrentTask { $0?.cancel() } }
    }

    let work = Task {
      try await InlineProtocolV3Transport.persistVerifiedTemporaryAuthorization(
        candidate, auth: fixture.auth, authority: authority, bearerToken: nil
      )
    }
    await #expect(throws: CancellationError.self) { try await work.value }
    #expect(fixture.auth.isLoggedIn())
  }

  @Test("the renewal stage cannot persist a different permanent account authority")
  func permanentReplacementIsRejected() async throws {
    let fixture = try Fixture(writeSucceeds: false)
    defer { fixture.cleanUp() }
    var candidate = try fixture.renewedCredentials()
    candidate.permanent = try Fixture.key(byte: 8)

    await #expect(throws: AuthStorageError.loginSuperseded) {
      try await InlineProtocolV3Transport.persistVerifiedTemporaryAuthorization(
        candidate, auth: fixture.auth, authority: fixture.auth.beginAccountMutation(), bearerToken: nil
      )
    }
  }

  private struct Fixture: Sendable {
    private static let credentialsKey = "inline_protocol_credentials_v1"
    let namespace = UUID().uuidString
    let cache: AuthSnapshotCache
    let store: AuthStore
    let auth: AuthHandle
    let onWrite = WriteControl()

    init(writeSucceeds: Bool) throws {
      let original = InlineProtocolSessionCredentials(
        userId: 42, accountSessionId: 84, permanent: try Self.key(byte: 2),
        temporary: try Self.key(byte: 3, temporary: true)
      )
      AuthKeychainConfig.mockSet(
        try JSONEncoder().encode(original), forKey: Self.credentialsKey, namespace: namespace
      )
      let cache = AuthSnapshotCache(initial: .init(status: .hydrating, didHydrate: false))
      let onWrite = self.onWrite
      let store = AuthStore(
        cache: cache, mocked: true, namespace: namespace,
        temporaryAuthorityWriteOverride: {
          onWrite.action.withLock { $0 }?()
          return writeSucceeds
        }
      )
      self.cache = cache
      self.store = store
      auth = AuthHandle(cache: cache, store: store)
    }

    func renewedCredentials() throws -> InlineProtocolSessionCredentials {
      var credentials = try #require(auth.snapshot().inlineProtocol)
      credentials.temporary = try Self.key(byte: 4, temporary: true)
      return credentials
    }

    func storedCredentials() throws -> InlineProtocolSessionCredentials? {
      guard let data = AuthKeychainConfig.mockGetData(Self.credentialsKey, namespace: namespace)
      else { return nil }
      return try JSONDecoder().decode(InlineProtocolSessionCredentials.self, from: data)
    }

    func cleanUp() {
      onWrite.action.withLock { $0 = nil }
      for key in ["token", "credentials_v2", Self.credentialsKey, AuthStore.legacyProtocolUpgradeKey] {
        AuthKeychainConfig.mockDelete(key, namespace: namespace)
      }
      let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
      for key in ["userId", "logoutPending", "logoutAttemptID", "loginCommitPendingAttemptID"] {
        UserDefaults.standard.removeObject(forKey: "\(prefix)\(key)")
      }
    }

    static func key(byte: UInt8, temporary: Bool = false) throws -> InlineProtocolAuthorization {
      let bytes = [UInt8](repeating: byte, count: 256)
      return try .init(
        key: bytes, keyID: InlineSecureTransport.authKeyID(bytes), serverSalt: 9,
        temporary: temporary, expiresAt: temporary ? 2_000_000_000 : nil
      )
    }
  }

  private final class WriteControl: Sendable {
    let action = Mutex<(@Sendable () -> Void)?>(nil)
  }
}
