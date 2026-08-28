import Foundation
import InlineProtocol
import Security
import Testing

@_spi(LogoutCoordinator) @testable import Auth

@Suite("Auth2 Store")
final class Auth2StoreTests {
  private final class AttemptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthLoginAttempt?

    func set(_ attempt: AuthLoginAttempt) {
      lock.withLock { value = attempt }
    }

    func get() -> AuthLoginAttempt? {
      lock.withLock { value }
    }
  }

  private final class BoolProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    func get() -> Bool { lock.withLock { value } }
  }

  private final class FakeKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var dataByKey: [String: Data]
    private var statusByKey: [String: OSStatus]
    private let defaultMissingStatus: OSStatus

    private(set) var lastResultCode: OSStatus = noErr

    init(
      dataByKey: [String: Data] = [:],
      statusByKey: [String: OSStatus] = [:],
      defaultMissingStatus: OSStatus = errSecItemNotFound
    ) {
      self.dataByKey = dataByKey
      self.statusByKey = statusByKey
      self.defaultMissingStatus = defaultMissingStatus
    }

    @discardableResult
    func set(_ value: String, forKey key: String, withAccess access: KeychainAccess? = nil) -> Bool {
      set(Data(value.utf8), forKey: key, withAccess: access)
    }

    @discardableResult
    func set(_ value: Data, forKey key: String, withAccess access: KeychainAccess? = nil) -> Bool {
      lock.withLock {
        if let status = statusByKey[key], status != errSecSuccess {
          lastResultCode = status
          return false
        }

        dataByKey[key] = value
        lastResultCode = errSecSuccess
        return true
      }
    }

    func getData(_ key: String) -> Data? {
      lock.withLock {
        if let data = dataByKey[key] {
          lastResultCode = errSecSuccess
          return data
        }

        lastResultCode = statusByKey[key] ?? defaultMissingStatus
        return nil
      }
    }

    @discardableResult
    func delete(_ key: String) -> Bool {
      lock.withLock {
        dataByKey[key] = nil
        lastResultCode = errSecSuccess
        return true
      }
    }
  }

  private final class SnapshotDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: AuthSnapshot

    init(_ snapshot: AuthSnapshot) {
      _snapshot = snapshot
    }

    func get() -> AuthSnapshot {
      lock.withLock { _snapshot }
    }

    func set(_ snapshot: AuthSnapshot) {
      lock.withLock { _snapshot = snapshot }
    }
  }

  private struct Harness {
    let namespace: String
    let userDefaultsKey: String
    let logoutPendingKey: String
    let logoutAttemptIDKey: String
    let loginCommitPendingKey: String

    init() {
      namespace = UUID().uuidString
      let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
      userDefaultsKey = "\(prefix)userId"
      logoutPendingKey = "\(prefix)logoutPending"
      logoutAttemptIDKey = "\(prefix)logoutAttemptID"
      loginCommitPendingKey = "\(prefix)loginCommitPendingAttemptID"
    }

    func resetStorage() {
      AuthKeychainConfig.mockDelete("token", namespace: namespace)
      AuthKeychainConfig.mockDelete("credentials_v2", namespace: namespace)
      AuthKeychainConfig.mockDelete("inline_protocol_credentials_v1", namespace: namespace)
      DatabaseKeyStore.delete(mocked: true, namespace: namespace)
      UserDefaults.standard.removeObject(forKey: userDefaultsKey)
      UserDefaults.standard.removeObject(forKey: logoutPendingKey)
      UserDefaults.standard.removeObject(forKey: logoutAttemptIDKey)
      UserDefaults.standard.removeObject(forKey: loginCommitPendingKey)
    }

    func makeStore(
      credentialDeletionOverride: (@Sendable () -> Bool)? = nil,
      authorityReplacementDeletionOverride: (@Sendable (String) -> Bool?)? = nil,
      authorityRestoreOverride: (@Sendable () -> Bool)? = nil,
      logoutFencePersistenceOverride: (@Sendable (UUID) -> Bool)? = nil,
      credentialWriteInterleavingHook: (@Sendable () -> Void)? = nil,
      authorityFinalizationInterleavingHook: (@Sendable () -> Void)? = nil
    ) -> (cache: AuthSnapshotCache, store: AuthStore) {
      let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
      let store = AuthStore(
        cache: cache,
        mocked: true,
        namespace: namespace,
        credentialDeletionOverride: credentialDeletionOverride,
        authorityReplacementDeletionOverride: authorityReplacementDeletionOverride,
        authorityRestoreOverride: authorityRestoreOverride,
        logoutFencePersistenceOverride: logoutFencePersistenceOverride,
        credentialWriteInterleavingHook: credentialWriteInterleavingHook,
        authorityFinalizationInterleavingHook: authorityFinalizationInterleavingHook
      )
      return (cache: cache, store: store)
    }
  }

  private func v3Credentials(userID: Int64 = 42) throws -> InlineProtocolSessionCredentials {
    let key = Array(UInt8.min...UInt8.max)
    let authorization = try InlineProtocolAuthorization(
      key: key,
      keyID: InlineSecureTransport.authKeyID(key),
      serverSalt: 7,
      temporary: false,
      expiresAt: nil
    )
    return InlineProtocolSessionCredentials(
      userId: userID,
      accountSessionId: 84,
      permanent: authorization
    )
  }

  private func completeLogoutForTest(_ store: AuthStore) async throws -> Bool {
    let fence = try store.beginLogoutSynchronously()
    guard let credentialProof = await store.destroyCredentialsForPendingLogout(fence: fence) else {
      return false
    }
    return await store.completePendingLogout(
      fence: fence,
      databaseProof: AuthDatabaseCleanupProof(fence: fence),
      credentialProof: credentialProof,
      completionPermit: AuthLogoutCompletionPermit(fence: fence)
    )
  }

  @Test("loads authenticated snapshot from credentials_v2")
  func loadsV2Credentials() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let expected = AuthCredentials(userId: 42, token: "42:tok", createdAt: createdAt)
    let data = try JSONEncoder().encode(expected)
    AuthKeychainConfig.mockSet(data, forKey: "credentials_v2", namespace: h.namespace)

    let (cache, _) = h.makeStore()
    let snapshot = cache.snapshot()

    if case let .authenticated(creds) = snapshot.status {
      #expect(creds == expected)
    } else {
      #expect(Bool(false), "Expected authenticated status")
    }

    #expect(UserDefaults.standard.object(forKey: h.userDefaultsKey) == nil)
  }

  @Test("saving V3 credentials removes bearer authority")
  func savingV3RemovesBearerAuthority() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    try await store.saveCredentials(token: "42:legacy", userId: 42)
    try await store.saveInlineProtocolCredentials(v3Credentials())

    #expect(AuthKeychainConfig.mockGetString("token", namespace: h.namespace) == nil)
    #expect(AuthKeychainConfig.mockGetData("credentials_v2", namespace: h.namespace) == nil)
    #expect(cache.snapshot().status == .authenticatedV3(userId: 42))
    #expect(cache.snapshot().token == nil)
  }

  @Test("saving bearer credentials removes V3 authority")
  func savingBearerRemovesV3Authority() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    try await store.saveInlineProtocolCredentials(v3Credentials())
    try await store.saveCredentials(token: "42:legacy", userId: 42)

    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: h.namespace) == nil)
    guard case let .authenticated(credentials) = cache.snapshot().status else {
      Issue.record("Expected bearer-authenticated status")
      return
    }
    #expect(credentials.token == "42:legacy")
    #expect(cache.snapshot().inlineProtocol == nil)
  }

  @Test("V2 to V2 authority replacement keeps only the latest bearer across relaunch")
  func bearerToBearerReplacementIsRestartStable() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }
    let (cache, store) = h.makeStore()
    try await store.saveCredentials(token: "7:old", userId: 7)
    let existingAccountToken = try cache.makeAccountMutationToken()
    let pendingInteractiveLogin = try await store.beginLoginAttempt(allowAuthenticated: true)
    try await store.saveCredentials(token: "7:new", userId: 7)
    try cache.validateAccountMutationToken(existingAccountToken)
    try await store.validateLoginAttempt(pendingInteractiveLogin)

    let (relaunchedCache, _) = h.makeStore()
    #expect(relaunchedCache.snapshot().token == "7:new")
    #expect(relaunchedCache.snapshot().currentUserId == 7)
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: h.namespace) == nil)
  }

  @Test("reauth-required and mixed stale authority can recover through one submitted login attempt")
  func submittedLoginRecoversStaleAuthority() async throws {
    let missing = Harness()
    missing.resetStorage()
    defer { missing.resetStorage() }
    UserDefaults.standard.set(NSNumber(value: Int64(7)), forKey: missing.userDefaultsKey)
    let (missingCache, missingStore) = missing.makeStore()
    #expect(missingCache.snapshot().status == .reauthRequired(userIdHint: 7))
    let missingAttempt = try await missingStore.beginLoginAttempt(allowAuthenticated: false)
    try await missingStore.saveCredentials(
      token: "7:recovered",
      userId: 7,
      loginAttempt: missingAttempt
    )
    _ = try await missingStore.finalizeCredentialsCommittedByLoginAttempt(missingAttempt)
    #expect(missingCache.snapshot().token == "7:recovered")

    let mixed = Harness()
    mixed.resetStorage()
    defer { mixed.resetStorage() }
    AuthKeychainConfig.mockSet("8:stale", forKey: "token", namespace: mixed.namespace)
    AuthKeychainConfig.mockSet(
      try JSONEncoder().encode(AuthCredentials(userId: 8, token: "8:stale")),
      forKey: "credentials_v2",
      namespace: mixed.namespace
    )
    AuthKeychainConfig.mockSet(
      try JSONEncoder().encode(v3Credentials(userID: 8)),
      forKey: "inline_protocol_credentials_v1",
      namespace: mixed.namespace
    )
    let (mixedCache, mixedStore) = mixed.makeStore()
    #expect(mixedCache.snapshot().status == .reauthRequired(userIdHint: nil))
    let mixedAttempt = try await mixedStore.beginLoginAttempt(allowAuthenticated: false)
    try await mixedStore.saveCredentials(
      token: "8:recovered",
      userId: 8,
      loginAttempt: mixedAttempt
    )
    _ = try await mixedStore.finalizeCredentialsCommittedByLoginAttempt(mixedAttempt)
    #expect(mixedCache.snapshot().token == "8:recovered")
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: mixed.namespace) == nil)
  }

  @Test("hydration fails closed without mutating mixed stored authority")
  func hydrationFailsClosedForMixedAuthority() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let v2 = try JSONEncoder().encode(AuthCredentials(userId: 7, token: "7:legacy"))
    let v3 = try JSONEncoder().encode(v3Credentials(userID: 42))
    AuthKeychainConfig.mockSet("7:legacy", forKey: "token", namespace: h.namespace)
    AuthKeychainConfig.mockSet(v2, forKey: "credentials_v2", namespace: h.namespace)
    AuthKeychainConfig.mockSet(v3, forKey: "inline_protocol_credentials_v1", namespace: h.namespace)

    let (cache, _) = h.makeStore()
    #expect(cache.snapshot().status == .reauthRequired(userIdHint: nil))
    #expect(cache.snapshot().inlineProtocol == nil)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: h.namespace) == "7:legacy")
    #expect(AuthKeychainConfig.mockGetData("credentials_v2", namespace: h.namespace) == v2)
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: h.namespace) == v3)
  }

  @Test("launch repair remains read-only when the userId hint is missing")
  func launchRepairDoesNotPersistMissingUserIdHint() async {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let creds = AuthCredentials(userId: 77, token: "77:tok")
    let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: h.namespace,
      readSnapshot: { _, _, _ in
        AuthSnapshot(status: .authenticated(creds), didHydrate: true)
      }
    )

    #expect(UserDefaults.standard.object(forKey: h.userDefaultsKey) == nil)

    await store.repairUserIdHint()

    #expect(UserDefaults.standard.object(forKey: h.userDefaultsKey) == nil)
  }

  @Test("loads authenticated snapshot from legacy token + userId hint")
  func loadsLegacyTokenWithHint() async {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let token = "42:legacyTok"
    AuthKeychainConfig.mockSet(token, forKey: "token", namespace: h.namespace)
    UserDefaults.standard.set(NSNumber(value: Int64(42)), forKey: h.userDefaultsKey)

    let (cache, _) = h.makeStore()
    let snapshot = cache.snapshot()

    guard case let .authenticated(creds) = snapshot.status else {
      #expect(Bool(false), "Expected authenticated status")
      return
    }

    #expect(creds.userId == 42)
    #expect(creds.token == token)
  }

  @Test("parses userId from legacy token when hint is missing")
  func parsesUserIdFromToken() async {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let token = "99:legacyTok"
    AuthKeychainConfig.mockSet(token, forKey: "token", namespace: h.namespace)

    let (cache, _) = h.makeStore()
    let snapshot = cache.snapshot()

    guard case let .authenticated(creds) = snapshot.status else {
      #expect(Bool(false), "Expected authenticated status")
      return
    }

    #expect(creds.userId == 99)
    #expect(creds.token == token)

    #expect(UserDefaults.standard.object(forKey: h.userDefaultsKey) == nil)
  }

  @Test("returns reauthRequired when userId hint exists but token is missing")
  func returnsReauthRequiredWhenMissingToken() async {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    UserDefaults.standard.set(NSNumber(value: Int64(123)), forKey: h.userDefaultsKey)

    let (cache, _) = h.makeStore()
    let snapshot = cache.snapshot()

    #expect(snapshot.status == .reauthRequired(userIdHint: 123))
  }

  @Test("emits login then logout events")
  func emitsLoginAndLogoutEvents() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (_, store) = h.makeStore()
    var it = store.events().makeAsyncIterator()

    try await store.saveCredentials(token: "1:eventTok", userId: 1)
    let e1 = await it.next()
    #expect(e1 == .login(userId: 1, token: "1:eventTok"))

    #expect(try await completeLogoutForTest(store))
    let e2 = await it.next()
    #expect(e2 == .logout)
  }

  @Test("pending logout keeps restart in recovery until app cleanup completes")
  func pendingLogoutBlocksRestartUntilAppCleanup() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (_, store) = h.makeStore()
    try await store.saveInlineProtocolCredentials(v3Credentials())
    _ = try await store.beginLogout()

    let recoveredCache = AuthSnapshotCache(
      initial: AuthSnapshot(status: .hydrating, didHydrate: false)
    )
    let recovered = AuthStore(cache: recoveredCache, mocked: true, namespace: h.namespace)
    #expect(recoveredCache.snapshot().status == .loggingOut(userIdHint: 42))
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: h.namespace) != nil)
    #expect(await recovered.hasPendingLogout() == true)

    #expect(try await completeLogoutForTest(recovered))
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: h.namespace) == nil)
    #expect(await recovered.hasPendingLogout() == false)
    #expect(recoveredCache.snapshot().status == .unauthenticated)
  }

  @Test("pending logout rejects login preparation before network redemption")
  func pendingLogoutRejectsLoginPreparation() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    _ = try await store.beginLogout()
    await store.publishLogoutInProgress()

    do {
      try await store.requireLoginAllowed()
      Issue.record("Expected login preparation to remain fenced by logout")
    } catch AuthStorageError.logoutInProgress {
      // The app-owned cleanup is the only operation allowed to remove this fence.
    } catch {
      Issue.record("Unexpected login preparation error: \(error)")
    }

    #expect(cache.snapshot().status == .loggingOut(userIdHint: nil))
    #expect(await store.hasPendingLogout())
  }

  @Test("synchronous logout fence rejects a pre-existing completion before an actor hop")
  func synchronousLogoutFenceBeatsQueuedLoginCommit() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    let loginAttempt = try await store.beginLoginAttempt(allowAuthenticated: false)
    let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
    let queuedCommit = Task {
      var iterator = gate.makeAsyncIterator()
      _ = await iterator.next()
      try await store.saveCredentials(
        token: "42:queued",
        userId: 42,
        loginAttempt: loginAttempt
      )
    }

    // No await: the durable marker and cache generation close before the queued actor call runs.
    _ = try store.beginLogoutSynchronously()
    #expect(cache.hasPendingLogout())
    continuation.yield(())
    continuation.finish()

    do {
      try await queuedCommit.value
      Issue.record("Expected the synchronously fenced commit to be rejected")
    } catch AuthStorageError.logoutInProgress {
      // This is the release invariant: UI routing is not the credential-write fence.
    } catch {
      Issue.record("Unexpected queued credential error: \(error)")
    }
    #expect(AuthKeychainConfig.mockGetString("token", namespace: h.namespace) == nil)
  }

  @Test("pending logout rejects stale bearer and V3 credential writers")
  func pendingLogoutRejectsCredentialWriters() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    _ = try await store.beginLogout()
    do {
      try await store.saveCredentials(token: "42:stale", userId: 42)
      Issue.record("Expected pending logout to reject bearer credential persistence")
    } catch AuthStorageError.logoutInProgress {
      // The logout marker owns authority destruction until app cleanup finishes.
    } catch {
      Issue.record("Unexpected bearer credential persistence error: \(error)")
    }

    do {
      try await store.saveInlineProtocolCredentials(v3Credentials())
      Issue.record("Expected pending logout to reject V3 credential persistence")
    } catch AuthStorageError.logoutInProgress {
      // The logout marker owns authority destruction until app cleanup finishes.
    } catch {
      Issue.record("Unexpected credential persistence error: \(error)")
    }

    #expect(await store.hasPendingLogout())
    #expect(cache.snapshot().status == .unauthenticated)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: h.namespace) == nil)
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: h.namespace) == nil)
  }

  @Test("credential destruction cannot remove the logout fence before the final commit")
  func credentialDestructionPreservesFenceUntilCompletion() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    try await store.saveCredentials(token: "42:legacy", userId: 42)
    let fence = try await store.beginLogout()
    await store.publishLogoutInProgress()

    let credentialProof = await store.destroyCredentialsForPendingLogout(fence: fence)
    #expect(credentialProof != nil)
    #expect(await store.hasPendingLogout())
    if case .loggingOut = cache.snapshot().status {
      // Exact account hints are not required for the recovery surface.
    } else {
      Issue.record("Expected non-loginable recovery status")
    }
    #expect(AuthKeychainConfig.mockGetString("token", namespace: h.namespace) == nil)

    guard let credentialProof else {
      Issue.record("Expected credential destruction proof")
      return
    }
    #expect(await store.completePendingLogout(
      fence: fence,
      databaseProof: AuthDatabaseCleanupProof(fence: fence),
      credentialProof: credentialProof,
      completionPermit: AuthLogoutCompletionPermit(fence: fence)
    ))
    #expect(await store.hasPendingLogout() == false)
    #expect(cache.snapshot().status == .unauthenticated)
  }

  @Test("logout permanently invalidates login work started by the previous UI generation")
  func logoutInvalidatesEarlierLoginGeneration() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (_, store) = h.makeStore()
    let staleAttempt = try await store.beginLoginAttempt(allowAuthenticated: false)
    _ = try await store.beginLogout()
    #expect(try await completeLogoutForTest(store))

    do {
      try await store.validateLoginAttempt(staleAttempt)
      Issue.record("Expected an attempt created before logout to remain invalid after cleanup")
    } catch AuthStorageError.loginSuperseded {
      // Marker removal permits a fresh login, never resumption of old onboarding work.
    } catch {
      Issue.record("Unexpected stale-attempt error: \(error)")
    }

    do {
      try await store.saveCredentials(
        token: "42:stale",
        userId: 42,
        loginAttempt: staleAttempt
      )
      Issue.record("Expected stale credentials to remain rejected after marker removal")
    } catch AuthStorageError.loginSuperseded {
      // Credential persistence shares the same generation fence.
    } catch {
      Issue.record("Unexpected stale credential error: \(error)")
    }
  }

  @Test("broadcasts login and logout events to every subscriber")
  func broadcastsAuthEventsToEverySubscriber() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (_, store) = h.makeStore()
    var first = store.events().makeAsyncIterator()
    var second = store.events().makeAsyncIterator()

    try await store.saveCredentials(token: "1:eventTok", userId: 1)
    #expect(await first.next() == .login(userId: 1, token: "1:eventTok"))
    #expect(await second.next() == .login(userId: 1, token: "1:eventTok"))

    #expect(try await completeLogoutForTest(store))
    #expect(await first.next() == .logout)
    #expect(await second.next() == .logout)
  }

  @Test("snapshot subscribers start with current state and receive future changes")
  func snapshotSubscribersStartCurrentAndReceiveChanges() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    try await store.saveCredentials(token: "1:eventTok", userId: 1)

    var first = store.snapshots().makeAsyncIterator()
    var second = store.snapshots().makeAsyncIterator()
    let authenticated = cache.snapshot()
    #expect(await first.next() == authenticated)
    #expect(await second.next() == authenticated)

    #expect(try await completeLogoutForTest(store))
    #expect(await first.next() == AuthSnapshot(status: .unauthenticated, didHydrate: true))
    #expect(await second.next() == AuthSnapshot(status: .unauthenticated, didHydrate: true))
  }

  @Test("snapshot subscribers do not coalesce rapid auth transitions")
  func snapshotSubscribersPreserveRapidAuthTransitions() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    try await store.saveCredentials(token: "1:firstToken", userId: 1)
    var snapshots = store.snapshots().makeAsyncIterator()
    #expect(await snapshots.next() == cache.snapshot())

    #expect(try await completeLogoutForTest(store))
    try await store.saveCredentials(token: "2:secondToken", userId: 2)

    #expect(await snapshots.next() == AuthSnapshot(status: .unauthenticated, didHydrate: true))
    let reloggedSnapshot = await snapshots.next()
    #expect(reloggedSnapshot?.token == "2:secondToken")
    #expect(reloggedSnapshot?.currentUserId == 2)
    #expect(reloggedSnapshot?.didHydrate == true)
  }

  @Test("snapshot stream buffers transitions before iteration begins")
  func snapshotStreamBuffersTransitionsBeforeIteration() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (_, store) = h.makeStore()
    try await store.saveCredentials(token: "1:firstToken", userId: 1)

    // Creating the stream is the subscription boundary used by task-based observers.
    let snapshots = store.snapshots()
    #expect(try await completeLogoutForTest(store))
    try await store.saveCredentials(token: "2:secondToken", userId: 2)

    var iterator = snapshots.makeAsyncIterator()
    #expect((await iterator.next())?.token == "1:firstToken")
    #expect(await iterator.next() == AuthSnapshot(status: .unauthenticated, didHydrate: true))
    #expect((await iterator.next())?.token == "2:secondToken")
  }

  @Test("event subscribers receive transitions buffered while no subscriber was active")
  func eventSubscribersReceiveIdleTransitions() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (_, store) = h.makeStore()
    try await store.saveCredentials(token: "1:eventTok", userId: 1)
    var events = store.events().makeAsyncIterator()

    #expect(await events.next() == .login(userId: 1, token: "1:eventTok"))
  }

  @Test("staged authority remains non-loginable until the exact attempt finalizes")
  func stagedAuthorityPublishesOnlyAtFinalize() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore()
    let attempt = try await store.beginLoginAttempt(allowAuthenticated: false)
    try await store.saveCredentials(token: "42:staged", userId: 42, loginAttempt: attempt)

    #expect(cache.snapshot().status == .unauthenticated)
    #expect(cache.hasPendingLoginCommit())
    #expect(UserDefaults.standard.string(forKey: h.loginCommitPendingKey) == attempt.correlationID.uuidString)
    do {
      _ = try await store.beginLoginAttempt(allowAuthenticated: false)
      Issue.record("Expected a second login attempt to be rejected during authority staging")
    } catch AuthStorageError.loginUnavailable {
      // One staged authority owner is the beta-sized linearization contract.
    } catch {
      Issue.record("Unexpected duplicate login error: \(error)")
    }

    let accountMutationToken = try await store.finalizeCredentialsCommittedByLoginAttempt(attempt)
    #expect(cache.snapshot().token == "42:staged")
    #expect(cache.hasPendingAccountTransition() == false)
    #expect(UserDefaults.standard.object(forKey: h.loginCommitPendingKey) == nil)
    #expect(cache.invalidateLoginAttempt(attempt) == false)
    do {
      try cache.validateAccountMutationToken(accountMutationToken)
    } catch {
      Issue.record("Finalized login cancellation must not invalidate the committed account token")
    }

    // Merely opening another login flow supersedes stale login callbacks, not the current account.
    // Existing account work remains valid until a replacement authority actually commits or logout
    // installs its synchronous fence.
    _ = cache.makeLoginAttempt()
    do {
      try cache.validateAccountMutationToken(accountMutationToken)
    } catch {
      Issue.record("A new uncommitted login attempt must not invalidate the current account token")
    }
  }

  @Test("projection commit reserves finalization against stale cancellation")
  func projectionCommitReservesAuthorityFinalization() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    let box = AttemptBox()
    let cancellationWon = BoolProbe()
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: h.namespace,
      authorityFinalizationInterleavingHook: {
        if let attempt = box.get(), cache.invalidateLoginAttempt(attempt) {
          cancellationWon.set()
        }
      }
    )
    let attempt = try await store.beginLoginAttempt(allowAuthenticated: false)
    box.set(attempt)
    try await store.saveCredentials(token: "42:committed", userId: 42, loginAttempt: attempt)

    // The production caller reaches this only after its minimum DB projection commits. From that
    // linearization point, a stale UI cancellation may not turn a complete account into a failure.
    _ = try await store.finalizeCredentialsCommittedByLoginAttempt(attempt)

    #expect(cancellationWon.get() == false)
    #expect(cache.snapshot().token == "42:committed")
    #expect(cache.hasPendingAccountTransition() == false)
    #expect(UserDefaults.standard.object(forKey: h.loginCommitPendingKey) == nil)
  }

  @Test("canceling an attempt during credential persistence restores authority and user hint")
  func cancellationDuringCredentialPersistenceRestoresBaseline() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    let box = AttemptBox()
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: h.namespace,
      credentialWriteInterleavingHook: {
        if let attempt = box.get() {
          _ = cache.invalidateLoginAttempt(attempt)
        }
      }
    )
    let attempt = try await store.beginLoginAttempt(allowAuthenticated: false)
    box.set(attempt)

    do {
      try await store.saveCredentials(token: "99:canceled", userId: 99, loginAttempt: attempt)
      Issue.record("Expected the canceled authority stage to be rejected")
    } catch AuthStorageError.loginSuperseded {
      // The baseline is restored below; no rejected account hint may remain durable.
    } catch AuthStorageError.loginUnavailable {
      // The generation fence may surface as unavailable once staging has been aborted.
    } catch {
      Issue.record("Unexpected canceled stage error: \(error)")
    }

    #expect(cache.snapshot().status == .unauthenticated)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: h.namespace) == nil)
    #expect(AuthKeychainConfig.mockGetData("credentials_v2", namespace: h.namespace) == nil)
    #expect(UserDefaults.standard.object(forKey: h.userDefaultsKey) == nil)
    #expect(UserDefaults.standard.object(forKey: h.loginCommitPendingKey) == nil)
  }

  @Test("logout fence persistence failure aborts before cleanup and preserves signed-in authority")
  func logoutFencePersistenceFailureAbortsCleanly() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (cache, store) = h.makeStore(logoutFencePersistenceOverride: { _ in false })
    try await store.saveCredentials(token: "42:still-signed-in", userId: 42)
    do {
      _ = try store.beginLogoutSynchronously()
      Issue.record("Expected durable logout fence persistence to fail")
    } catch AuthStorageError.logoutFencePersistenceFailed {
      // No destructive operation has started and the in-memory fence is aborted.
    } catch {
      Issue.record("Unexpected persistence error: \(error)")
    }

    #expect(cache.snapshot().token == "42:still-signed-in")
    #expect(store.hasPendingLogout() == false)
    #expect(UserDefaults.standard.object(forKey: h.logoutPendingKey) == nil)
    #expect(UserDefaults.standard.object(forKey: h.logoutAttemptIDKey) == nil)
  }

  @Test("failed staged-authority restore with fence persistence failure signals platform recovery")
  func failedAuthorityRestoreSignalsActionableRecovery() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }
    let probe = BoolProbe()
    let observer = NotificationCenter.default.addObserver(
      forName: .authAccountRecoveryRequired,
      object: nil,
      queue: nil
    ) { _ in
      probe.set()
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let (cache, store) = h.makeStore(
      authorityReplacementDeletionOverride: { _ in false },
      authorityRestoreOverride: { false },
      logoutFencePersistenceOverride: { _ in false }
    )
    let attempt = try await store.beginLoginAttempt(allowAuthenticated: false)

    do {
      try await store.saveCredentials(
        token: "42:ambiguous",
        userId: 42,
        loginAttempt: attempt
      )
      Issue.record("Expected staged-authority persistence failure")
    } catch AuthStorageError.keychainDeleteFailed {
      // Restore then fence persistence both fail; the platform receives an actionable signal.
    }

    #expect(probe.get())
    if case .loggingOut = cache.snapshot().status {
      // The platform recovery signal, not an account hint, is the actionable contract.
    } else {
      Issue.record("Expected non-loginable recovery status")
    }
    #expect(cache.hasPendingAccountTransition())
    #expect(UserDefaults.standard.object(forKey: h.loginCommitPendingKey) != nil)
  }

  @Test("malformed logout marker and orphan attempt ID both recover fail closed")
  func malformedAndOrphanLogoutMarkersRecoverFailClosed() async {
    let malformed = Harness()
    malformed.resetStorage()
    UserDefaults.standard.set("not-a-boolean", forKey: malformed.logoutPendingKey)
    let (malformedCache, malformedStore) = malformed.makeStore()
    #expect(malformedCache.snapshot().status == .loggingOut(userIdHint: nil))
    #expect(malformedStore.hasPendingLogout())
    #expect(UUID(uuidString: UserDefaults.standard.string(forKey: malformed.logoutAttemptIDKey) ?? "") != nil)
    malformed.resetStorage()

    let orphan = Harness()
    orphan.resetStorage()
    defer { orphan.resetStorage() }
    let orphanID = UUID()
    UserDefaults.standard.set(orphanID.uuidString, forKey: orphan.logoutAttemptIDKey)
    let (orphanCache, orphanStore) = orphan.makeStore()
    #expect(orphanCache.snapshot().status == .loggingOut(userIdHint: nil))
    #expect(orphanStore.currentLogoutFence()?.correlationID == orphanID)
    #expect(orphanStore.hasPendingLogout())
  }

  @Test("corrupt staged-login marker promotes launch into logout recovery")
  func corruptStagedLoginMarkerRecoversFailClosed() async {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }
    UserDefaults.standard.set("corrupt", forKey: h.loginCommitPendingKey)

    let (cache, store) = h.makeStore()
    #expect(cache.snapshot().status == .loggingOut(userIdHint: nil))
    #expect(store.hasPendingLogout())
    #expect(UUID(uuidString: UserDefaults.standard.string(forKey: h.logoutAttemptIDKey) ?? "") != nil)
  }

  @Test("repeated logout begin reuses one proof identity and leaves no marker after completion")
  func repeatedLogoutBeginIsIdempotent() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }
    let (cache, store) = h.makeStore()
    try await store.saveCredentials(token: "42:logout", userId: 42)

    let first = try store.beginLogoutSynchronously()
    let second = try store.beginLogoutSynchronously()
    #expect(first == second)
    #expect(cache.currentLogoutFence() == first)
    guard let credentialProof = await store.destroyCredentialsForPendingLogout(fence: first) else {
      Issue.record("Expected verified credential destruction")
      return
    }
    #expect(await store.completePendingLogout(
      fence: first,
      databaseProof: AuthDatabaseCleanupProof(fence: first),
      credentialProof: credentialProof,
      completionPermit: AuthLogoutCompletionPermit(fence: first)
    ))
    #expect(UserDefaults.standard.object(forKey: h.logoutPendingKey) == nil)
    #expect(UserDefaults.standard.object(forKey: h.logoutAttemptIDKey) == nil)
    #expect(cache.snapshot().status == .unauthenticated)
  }

  @Test("credential deletion failure retains marker and relaunch retry completes")
  func credentialDeletionFailureRetainsMarkerForRetry() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }
    let (_, failingStore) = h.makeStore(credentialDeletionOverride: { false })
    try await failingStore.saveCredentials(token: "42:retry", userId: 42)
    let fence = try failingStore.beginLogoutSynchronously()
    #expect(await failingStore.destroyCredentialsForPendingLogout(fence: fence) == nil)
    #expect(failingStore.hasPendingLogout())
    #expect(UserDefaults.standard.string(forKey: h.logoutAttemptIDKey) == fence.correlationID.uuidString)

    let (recoveredCache, recoveredStore) = h.makeStore()
    #expect(recoveredStore.currentLogoutFence()?.correlationID == fence.correlationID)
    #expect(try await completeLogoutForTest(recoveredStore))
    #expect(recoveredCache.snapshot().status == .unauthenticated)
    #expect(UserDefaults.standard.object(forKey: h.logoutPendingKey) == nil)
  }

  @Test("revoked finalization permit cannot remove the durable logout marker")
  func revokedCompletionPermitRetainsMarker() async throws {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }
    let (cache, store) = h.makeStore()
    try await store.saveCredentials(token: "42:deadline", userId: 42)
    let fence = try store.beginLogoutSynchronously()
    await store.publishLogoutInProgress()
    guard let credentialProof = await store.destroyCredentialsForPendingLogout(fence: fence) else {
      Issue.record("Expected verified credential destruction")
      return
    }
    let permit = AuthLogoutCompletionPermit(fence: fence)
    #expect(permit.revoke())
    #expect(await store.completePendingLogout(
      fence: fence,
      databaseProof: AuthDatabaseCleanupProof(fence: fence),
      credentialProof: credentialProof,
      completionPermit: permit
    ) == false)
    #expect(cache.snapshot().status == .loggingOut(userIdHint: 42))
    #expect(store.hasPendingLogout())
    #expect(UserDefaults.standard.string(forKey: h.logoutAttemptIDKey) == fence.correlationID.uuidString)
  }

  @Test("authority replacement deletion failure restores the previously valid authority")
  func authorityReplacementFailureRestoresBaselineInBothDirections() async throws {
    let bearerHarness = Harness()
    bearerHarness.resetStorage()
    defer { bearerHarness.resetStorage() }
    let (_, bearerSeed) = bearerHarness.makeStore()
    try await bearerSeed.saveCredentials(token: "7:bearer", userId: 7)
    let (bearerCache, bearerToV3) = bearerHarness.makeStore(
      authorityReplacementDeletionOverride: { label in label == "bearer" ? false : nil }
    )
    do {
      try await bearerToV3.saveInlineProtocolCredentials(v3Credentials(userID: 7))
      Issue.record("Expected bearer-to-V3 old-authority deletion failure")
    } catch AuthStorageError.keychainDeleteFailed {
      // Newly written V3 authority is rolled back and the bearer baseline remains restart-safe.
    }
    #expect(bearerCache.snapshot().token == "7:bearer")
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: bearerHarness.namespace) == nil)

    let v3Harness = Harness()
    v3Harness.resetStorage()
    defer { v3Harness.resetStorage() }
    let (_, v3Seed) = v3Harness.makeStore()
    try await v3Seed.saveInlineProtocolCredentials(v3Credentials(userID: 9))
    let (v3Cache, v3ToBearer) = v3Harness.makeStore(
      authorityReplacementDeletionOverride: { label in label == "inline_protocol" ? false : nil }
    )
    do {
      try await v3ToBearer.saveCredentials(token: "9:bearer", userId: 9)
      Issue.record("Expected V3-to-bearer old-authority deletion failure")
    } catch AuthStorageError.keychainDeleteFailed {
      // Newly written bearer authority is rolled back and the V3 baseline remains restart-safe.
    }
    #expect(v3Cache.snapshot().status == .authenticatedV3(userId: 9))
    #expect(AuthKeychainConfig.mockGetString("token", namespace: v3Harness.namespace) == nil)
    #expect(AuthKeychainConfig.mockGetData("credentials_v2", namespace: v3Harness.namespace) == nil)
  }

  @Test("DatabaseKeyStore getOrCreate is stable and deletable (mocked)")
  func databaseKeyStoreRoundTrip() async {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let first = DatabaseKeyStore.getOrCreate(mocked: true, namespace: h.namespace)
    guard case let .available(key: key1) = first else {
      #expect(Bool(false), "Expected available dbKey")
      return
    }

    let second = DatabaseKeyStore.load(mocked: true, namespace: h.namespace)
    guard case let .available(key: key2) = second else {
      #expect(Bool(false), "Expected available dbKey on load")
      return
    }

    #expect(key1 == key2)

    DatabaseKeyStore.delete(mocked: true, namespace: h.namespace)
    #expect(DatabaseKeyStore.load(mocked: true, namespace: h.namespace) == .notFound)
  }

  @Test("build config uses the expected keychain base prefix")
  func buildConfigUsesExpectedKeychainBasePrefix() {
    #if DEBUG
    #expect(AuthKeychainConfig.keychainBasePrefix(userProfile: nil) == "inline_dev_")
    #else
    #expect(AuthKeychainConfig.keychainBasePrefix(userProfile: nil) == "inline_")
    #endif
  }

  @Test("refreshFromStorage does not regress authenticated -> locked (transient keychain lock)")
  func refreshDoesNotRegressAuthenticatedToLocked() async {
    let namespace = UUID().uuidString
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
    let userDefaultsKey = "\(prefix)userId"
    UserDefaults.standard.removeObject(forKey: userDefaultsKey)

    let initialCreds = AuthCredentials(userId: 7, token: "7:tok")
    let driver = SnapshotDriver(AuthSnapshot(status: .authenticated(initialCreds), didHydrate: true))

    let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: namespace,
      readSnapshot: { _, _, _ in
        driver.get()
      }
    )

    // Seeded authenticated from readSnapshot.
    #expect(cache.snapshot().status == .authenticated(initialCreds))

    // Simulate "keychain locked/unavailable" on a later refresh.
    driver.set(AuthSnapshot(status: .locked(userIdHint: 7), didHydrate: true))
    await store.refreshFromStorage()

    // Should keep the in-memory authenticated credentials.
    #expect(cache.snapshot().status == .authenticated(initialCreds))
  }

  @Test("refreshFromStorage applies locked when not authenticated (initial unauthenticated)")
  func refreshCanEnterLockedWhenNotAuthenticated() async {
    let namespace = UUID().uuidString
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
    let userDefaultsKey = "\(prefix)userId"
    UserDefaults.standard.removeObject(forKey: userDefaultsKey)

    let driver = SnapshotDriver(AuthSnapshot(status: .unauthenticated, didHydrate: true))
    let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    let store = AuthStore(
      cache: cache,
      mocked: true,
      namespace: namespace,
      readSnapshot: { _, _, _ in driver.get() }
    )

    #expect(cache.snapshot().status == .unauthenticated)

    driver.set(AuthSnapshot(status: .locked(userIdHint: nil), didHydrate: true))
    await store.refreshFromStorage()

    #expect(cache.snapshot().status == .locked(userIdHint: nil))
  }

  @Test("readData uses fallback keychain when primary cannot read")
  func readDataUsesFallbackWhenPrimaryCannotRead() {
    let primary = FakeKeychain(statusByKey: ["token": errSecMissingEntitlement])
    let fallback = FakeKeychain(dataByKey: ["token": Data("42:fallback".utf8)])

    let outcome = AuthKeychainConfig.readString("token", primary: primary, fallback: fallback)

    guard case let .success(token, usedFallback) = outcome else {
      #expect(Bool(false), "Expected fallback token")
      return
    }

    #expect(token == "42:fallback")
    #expect(usedFallback)
  }

  @Test("readData reports locked when primary is unavailable and fallback is missing")
  func readDataReportsLockedWhenPrimaryUnavailableAndFallbackMissing() {
    let primary = FakeKeychain(statusByKey: ["token": errSecInteractionNotAllowed])
    let fallback = FakeKeychain()

    let outcome = AuthKeychainConfig.readString("token", primary: primary, fallback: fallback)

    guard case let .interactionNotAllowed(status) = outcome else {
      #expect(Bool(false), "Expected locked status")
      return
    }

    #expect(status == errSecInteractionNotAllowed)
  }

  @Test("snapshot authenticates from fallback credentials when primary errors")
  func snapshotAuthenticatesFromFallbackCredentialsWhenPrimaryErrors() throws {
    let userDefaultsKey = "test_\(UUID().uuidString)_userId"
    defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

    let creds = AuthCredentials(userId: 42, token: "42:fallback")
    let data = try JSONEncoder().encode(creds)
    let primary = FakeKeychain(statusByKey: ["credentials_v2": errSecMissingEntitlement])
    let fallback = FakeKeychain(dataByKey: ["credentials_v2": data])

    let snapshot = AuthStore.readSnapshot(
      primaryKeychain: primary,
      fallbackKeychain: fallback,
      userDefaultsKey: userDefaultsKey,
      mocked: false,
      namespace: nil
    )

    #expect(snapshot.status == .authenticated(creds))
  }

  @Test("snapshot preserves reauthRequired when v2 errors but legacy token is missing")
  func snapshotPreservesReauthRequiredWhenV2ErrorsButLegacyTokenMissing() {
    let userDefaultsKey = "test_\(UUID().uuidString)_userId"
    UserDefaults.standard.set(NSNumber(value: Int64(42)), forKey: userDefaultsKey)
    defer { UserDefaults.standard.removeObject(forKey: userDefaultsKey) }

    let primary = FakeKeychain(statusByKey: [
      "credentials_v2": errSecDecode,
      "token": errSecItemNotFound,
    ])

    let snapshot = AuthStore.readSnapshot(
      primaryKeychain: primary,
      fallbackKeychain: nil,
      userDefaultsKey: userDefaultsKey,
      mocked: false,
      namespace: nil
    )

    #expect(snapshot.status == .reauthRequired(userIdHint: 42))
  }
}
