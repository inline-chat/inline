import Foundation
import InlineProtocol
import Security
import Testing

@_spi(LogoutCoordinator) @testable import Auth

@Suite("Legacy protocol upgrade storage")
struct LegacyProtocolUpgradeStoreTests {
  private struct Fixture {
    let namespace = UUID().uuidString
    let source = AuthCredentials(userId: 42, token: "42:legacy-session")

    var prefix: String { AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace) }

    func seed(_ credentials: AuthCredentials? = nil) throws {
      let credentials = credentials ?? source
      AuthKeychainConfig.mockSet(credentials.token, forKey: "token", namespace: namespace)
      AuthKeychainConfig.mockSet(
        try JSONEncoder().encode(credentials), forKey: "credentials_v2", namespace: namespace
      )
      UserDefaults.standard.set(NSNumber(value: credentials.userId), forKey: "\(prefix)userId")
    }

    func makeStore(
      write: (@Sendable () -> Bool)? = nil,
      interleaving: (@Sendable () -> Void)? = nil
    ) -> (AuthSnapshotCache, AuthStore) {
      let cache = AuthSnapshotCache(initial: .init(status: .hydrating, didHydrate: false))
      let store = AuthStore(
        cache: cache, mocked: true, namespace: namespace,
        legacyUpgradeWriteOverride: write, credentialWriteInterleavingHook: interleaving
      )
      return (cache, store)
    }

    func stored(_ key: String) -> Data? {
      AuthKeychainConfig.mockGetData(key, namespace: namespace)
    }

    func removeBearerLikeOlderBuild() {
      AuthKeychainConfig.mockDelete("token", namespace: namespace)
      AuthKeychainConfig.mockDelete("credentials_v2", namespace: namespace)
      UserDefaults.standard.removeObject(forKey: "\(prefix)userId")
    }

    func clear() {
      for key in ["token", "credentials_v2", "inline_protocol_credentials_v1", AuthStore.legacyProtocolUpgradeKey] {
        AuthKeychainConfig.mockDelete(key, namespace: namespace)
      }
      for key in ["userId", "logoutPending", "logoutAttemptID", "loginCommitPendingAttemptID"] {
        UserDefaults.standard.removeObject(forKey: "\(prefix)\(key)")
      }
    }

    func assertBearerPreserved(_ cache: AuthSnapshotCache) throws {
      #expect(cache.snapshot().token == source.token)
      #expect(cache.snapshot().status == .authenticated(source))
      #expect(stored("token") == Data(source.token.utf8))
      #expect(try stored("credentials_v2").map { try JSONDecoder().decode(AuthCredentials.self, from: $0) } == source)
      #expect(stored("inline_protocol_credentials_v1") == nil)
      #expect(UserDefaults.standard.object(forKey: "\(prefix)loginCommitPendingAttemptID") == nil)
      #expect(UserDefaults.standard.object(forKey: "\(prefix)logoutPending") == nil)
    }
  }

  private func authorization(temporary: Bool = false, seed: UInt8 = 0) throws -> InlineProtocolAuthorization {
    let key = (0..<256).map { UInt8(truncatingIfNeeded: $0) &+ seed }
    return try InlineProtocolAuthorization(
      key: key, keyID: InlineSecureTransport.authKeyID(key), serverSalt: 7,
      temporary: temporary, expiresAt: temporary ? 2_000_000_000 : nil
    )
  }

  private func credentials(permanent: InlineProtocolAuthorization) throws -> InlineProtocolSessionCredentials {
    InlineProtocolSessionCredentials(
      userId: 42, accountSessionId: 91, permanent: permanent,
      temporary: try authorization(temporary: true, seed: 1)
    )
  }

  @Test("candidate survives process loss before server authorization and repeated staging reuses it")
  func candidateSurvivesReopen() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (cache, store) = fixture.makeStore()
    let mutation = try cache.makeAccountMutationToken()
    let permanent = try authorization()
    #expect(try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source) == permanent)
    #expect(try await store.stageLegacyProtocolUpgrade(authorization(seed: 3), for: fixture.source) == permanent)
    #expect(cache.snapshot().inlineProtocol == nil)
    try cache.validateAccountMutationToken(mutation)
    try fixture.assertBearerPreserved(cache)

    let (reopenedCache, reopened) = fixture.makeStore()
    #expect(try await reopened.legacyProtocolUpgradeCandidate(for: fixture.source) == permanent)
    #expect(reopenedCache.snapshot().inlineProtocol == nil)
    try fixture.assertBearerPreserved(reopenedCache)
  }

  @Test("verified commit and reopen retain bearer authority and account work without login markers")
  func verifiedCommitPreservesAuthority() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (cache, store) = fixture.makeStore()
    let mutation = try cache.makeAccountMutationToken()
    let permanent = try authorization()
    let verified = try credentials(permanent: permanent)
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    try await store.commitLegacyProtocolUpgrade(verified, for: fixture.source)
    #expect(cache.snapshot().inlineProtocol == verified)
    try cache.validateAccountMutationToken(mutation)
    try fixture.assertBearerPreserved(cache)

    let (reopened, _) = fixture.makeStore()
    #expect(reopened.snapshot().inlineProtocol == verified)
    try fixture.assertBearerPreserved(reopened)
  }

  @Test("process loss after durable commit recovers verified credentials without publication")
  func crashAfterDurableWrite() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let permanent = try authorization()
    let verified = try credentials(permanent: permanent)
    var record = try LegacyProtocolUpgrade(source: fixture.source, permanent: permanent)
    record.credentials = verified
    AuthKeychainConfig.mockSet(
      try JSONEncoder().encode(record), forKey: AuthStore.legacyProtocolUpgradeKey, namespace: fixture.namespace
    )
    let (reopened, _) = fixture.makeStore()
    #expect(reopened.snapshot().inlineProtocol == verified)
    try fixture.assertBearerPreserved(reopened)
  }

  @Test("token-only legacy storage upgrades without rewriting the original credential layout")
  func legacyTokenOnlyStorage() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    AuthKeychainConfig.mockDelete("credentials_v2", namespace: fixture.namespace)
    let (cache, store) = fixture.makeStore()
    let authority = try cache.makeAccountMutationToken()
    let permanent = try authorization()
    let verified = try credentials(permanent: permanent)
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source, authority: authority)
    try await store.commitLegacyProtocolUpgrade(verified, for: fixture.source, authority: authority)
    await store.refreshFromStorage()
    try cache.validateAccountMutationToken(authority)
    #expect(cache.snapshot().token == fixture.source.token)
    #expect(cache.snapshot().inlineProtocol == verified)
    #expect(fixture.stored("credentials_v2") == nil)
    let (reopened, _) = fixture.makeStore()
    #expect(reopened.snapshot().token == fixture.source.token)
    #expect(reopened.snapshot().inlineProtocol == verified)
  }

  @Test("failed candidate or verified writes leave the bearer and durable candidate intact")
  func failedWritesAreNonDestructive() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (failedCache, failedStore) = fixture.makeStore(write: { false })
    let permanent = try authorization()
    await #expect(throws: AuthStorageError.keychainWriteFailed) {
      try await failedStore.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    }
    #expect(fixture.stored(AuthStore.legacyProtocolUpgradeKey) == nil)
    try fixture.assertBearerPreserved(failedCache)

    let (_, staging) = fixture.makeStore()
    try await staging.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    let stagedData = fixture.stored(AuthStore.legacyProtocolUpgradeKey)
    await #expect(throws: AuthStorageError.keychainWriteFailed) {
      try await failedStore.commitLegacyProtocolUpgrade(credentials(permanent: permanent), for: fixture.source)
    }
    #expect(fixture.stored(AuthStore.legacyProtocolUpgradeKey) == stagedData)
    #expect(failedCache.snapshot().inlineProtocol == nil)
    try fixture.assertBearerPreserved(failedCache)
  }

  @Test("old logout and bearer replacement cannot resurrect a staged or verified V3 record")
  func oldWriterInvalidatesUpgrade() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (_, store) = fixture.makeStore()
    let permanent = try authorization()
    let verified = try credentials(permanent: permanent)
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    try await store.commitLegacyProtocolUpgrade(verified, for: fixture.source)

    fixture.removeBearerLikeOlderBuild()
    let (loggedOut, _) = fixture.makeStore()
    #expect(loggedOut.snapshot().isLoggedIn == false)
    #expect(loggedOut.snapshot().inlineProtocol == nil)
    await #expect(throws: AuthStorageError.loginSuperseded) {
      try await store.commitLegacyProtocolUpgrade(verified, for: fixture.source)
    }

    let replacement = AuthCredentials(userId: 42, token: "42:replacement")
    try fixture.seed(replacement)
    let (replaced, replacementStore) = fixture.makeStore()
    #expect(replaced.snapshot().token == replacement.token)
    #expect(replaced.snapshot().inlineProtocol == nil)
    #expect(try await replacementStore.legacyProtocolUpgradeCandidate(for: replacement) == nil)
    await #expect(throws: AuthStorageError.loginSuperseded) {
      try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    }
  }

  @Test("source removal during a Keychain write prevents V3 publication")
  func sourceRemovalDuringWrite() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (_, staging) = fixture.makeStore()
    let permanent = try authorization()
    try await staging.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    let (cache, store) = fixture.makeStore(interleaving: { fixture.removeBearerLikeOlderBuild() })
    await #expect(throws: AuthStorageError.loginSuperseded) {
      try await store.commitLegacyProtocolUpgrade(credentials(permanent: permanent), for: fixture.source)
    }
    #expect(cache.snapshot().inlineProtocol == nil)
    let (reopened, _) = fixture.makeStore()
    #expect(reopened.snapshot().isLoggedIn == false)
    #expect(reopened.snapshot().inlineProtocol == nil)
  }

  @Test("temporary rotation updates only the upgrade record and preserves account mutation leases")
  func temporaryRotationPreservesSource() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (cache, store) = fixture.makeStore()
    let permanent = try authorization()
    var verified = try credentials(permanent: permanent)
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    try await store.commitLegacyProtocolUpgrade(verified, for: fixture.source)
    let mutation = try cache.makeAccountMutationToken()
    verified.temporary = try authorization(temporary: true, seed: 2)
    verified.permanent.serverSalt = 8
    try await store.saveInlineProtocolCredentials(verified, authority: mutation)
    #expect(cache.snapshot().inlineProtocol == verified)
    try cache.validateAccountMutationToken(mutation)
    try fixture.assertBearerPreserved(cache)
    let (reopened, _) = fixture.makeStore()
    #expect(reopened.snapshot().inlineProtocol == verified)
  }

  @Test("stale transport rotation cannot replace a newer same-user bearer authority")
  func staleTransportRotationDoesNotReplaceLogin() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (cache, store) = fixture.makeStore()
    let permanent = try authorization()
    var previous = try credentials(permanent: permanent)
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    try await store.commitLegacyProtocolUpgrade(previous, for: fixture.source)
    let oldTransportAuthority = try cache.makeAccountMutationToken()

    // Same-user replacement intentionally preserves the ordinary account mutation lease;
    // the transport must additionally prove that its permanent/session still owns storage.
    try await store.saveCredentials(token: "42:replacement-session", userId: 42)
    try cache.validateAccountMutationToken(oldTransportAuthority)
    previous.temporary = try authorization(temporary: true, seed: 5)
    await #expect(throws: AuthStorageError.loginSuperseded) {
      try await store.saveInlineProtocolCredentials(previous, authority: oldTransportAuthority)
    }
    #expect(cache.snapshot().token == "42:replacement-session")
    #expect(cache.snapshot().inlineProtocol == nil)
    #expect(fixture.stored("token") == Data("42:replacement-session".utf8))
    #expect(fixture.stored("inline_protocol_credentials_v1") == nil)
    #expect(fixture.stored(AuthStore.legacyProtocolUpgradeKey) == nil)
    #expect(UserDefaults.standard.object(forKey: "\(fixture.prefix)loginCommitPendingAttemptID") == nil)
  }

  @Test("explicit login replacement and logout remove the additive record")
  func explicitTransitionsClearUpgrade() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (_, store) = fixture.makeStore()
    let permanent = try authorization()
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    try await store.saveCredentials(token: fixture.source.token, userId: fixture.source.userId)
    #expect(fixture.stored(AuthStore.legacyProtocolUpgradeKey) == nil)
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    let fence = try store.beginLogoutSynchronously()
    #expect(await store.destroyCredentialsForPendingLogout(fence: fence) != nil)
    #expect(fixture.stored(AuthStore.legacyProtocolUpgradeKey) == nil)
  }

  @Test("foreign credentials or a different permanent key cannot commit")
  func invalidCompletionIsRejected() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (cache, store) = fixture.makeStore()
    let permanent = try authorization()
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source)
    var foreign = try credentials(permanent: permanent)
    foreign.userId = 43
    await #expect(throws: AuthStorageError.encodingFailed) {
      try await store.commitLegacyProtocolUpgrade(foreign, for: fixture.source)
    }
    await #expect(throws: AuthStorageError.loginSuperseded) {
      try await store.commitLegacyProtocolUpgrade(credentials(permanent: authorization(seed: 4)), for: fixture.source)
    }
    #expect(cache.snapshot().inlineProtocol == nil)
    try fixture.assertBearerPreserved(cache)
  }

  @Test("logout followed by login with the identical bearer rejects the old account lease")
  func identicalBearerDoesNotReviveOldLease() async throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    let (cache, store) = fixture.makeStore()
    let previousAuthority = try cache.makeAccountMutationToken()
    let permanent = try authorization()
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source, authority: previousAuthority)

    let fence = try store.beginLogoutSynchronously()
    let destruction = try #require(await store.destroyCredentialsForPendingLogout(fence: fence))
    #expect(await store.completePendingLogout(
      fence: fence,
      databaseProof: AuthDatabaseCleanupProof(fence: fence),
      credentialProof: destruction,
      completionPermit: AuthLogoutCompletionPermit(fence: fence)
    ))
    try await store.saveCredentials(token: fixture.source.token, userId: fixture.source.userId)
    let currentAuthority = try cache.makeAccountMutationToken()
    try await store.stageLegacyProtocolUpgrade(permanent, for: fixture.source, authority: currentAuthority)
    let candidate = fixture.stored(AuthStore.legacyProtocolUpgradeKey)
    await #expect(throws: AuthStorageError.loginUnavailable) {
      try await store.legacyProtocolUpgradeCandidate(for: fixture.source, authority: previousAuthority)
    }
    await #expect(throws: AuthStorageError.loginUnavailable) {
      try await store.commitLegacyProtocolUpgrade(
        credentials(permanent: permanent), for: fixture.source, authority: previousAuthority
      )
    }
    #expect(fixture.stored(AuthStore.legacyProtocolUpgradeKey) == candidate)
    #expect(cache.snapshot().inlineProtocol == nil)
    try await store.commitLegacyProtocolUpgrade(
      credentials(permanent: permanent), for: fixture.source, authority: currentAuthority
    )
    #expect(cache.snapshot().inlineProtocol != nil)
  }

  @Test("invalid or inaccessible optional migration storage leaves a readable bearer usable")
  func optionalStorageFailureKeepsBearer() throws {
    let fixture = Fixture()
    defer { fixture.clear() }
    try fixture.seed()
    AuthKeychainConfig.mockSet(Data("corrupt".utf8), forKey: AuthStore.legacyProtocolUpgradeKey, namespace: fixture.namespace)
    let (cache, _) = fixture.makeStore()
    try fixture.assertBearerPreserved(cache)
    #expect(cache.snapshot().inlineProtocol == nil)

    let keychain = UpgradeReadKeychain(source: fixture.source)
    let snapshot = AuthStore.readSnapshot(
      primaryKeychain: keychain, fallbackKeychain: nil,
      userDefaultsKey: "\(fixture.prefix)userId", mocked: false, namespace: nil
    )
    #expect(snapshot.token == fixture.source.token)
    #expect(snapshot.inlineProtocol == nil)
    #expect(snapshot.isLoggedIn)
  }
}

/// A locked optional slot must not block an independently readable bearer authority.
private final class UpgradeReadKeychain: KeychainClient, @unchecked Sendable {
  private let source: AuthCredentials
  private(set) var lastResultCode: OSStatus = errSecSuccess

  init(source: AuthCredentials) { self.source = source }

  func getData(_ key: String) -> Data? {
    if key == "credentials_v2" {
      lastResultCode = errSecSuccess
      return try? JSONEncoder().encode(source)
    }
    lastResultCode = key == AuthStore.legacyProtocolUpgradeKey ? errSecInteractionNotAllowed : errSecItemNotFound
    return nil
  }

  func set(_: String, forKey _: String, withAccess _: KeychainAccess?) -> Bool { false }
  func set(_: Data, forKey _: String, withAccess _: KeychainAccess?) -> Bool { false }
  func delete(_: String) -> Bool { false }
}
