import Foundation
import Security
import Testing

@testable import Auth

@Suite("Auth2 Store")
final class Auth2StoreTests {
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

    init() {
      namespace = UUID().uuidString
      userDefaultsKey = "\(AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace))userId"
    }

    func resetStorage() {
      AuthKeychainConfig.mockDelete("token", namespace: namespace)
      AuthKeychainConfig.mockDelete("credentials_v2", namespace: namespace)
      DatabaseKeyStore.delete(mocked: true, namespace: namespace)
      UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    func makeStore() -> (cache: AuthSnapshotCache, store: AuthStore) {
      let cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
      let store = AuthStore(cache: cache, mocked: true, namespace: namespace)
      return (cache: cache, store: store)
    }
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

    let writtenBack = UserDefaults.standard.object(forKey: h.userDefaultsKey) as? NSNumber
    #expect(writtenBack?.int64Value == 99)
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
  func emitsLoginAndLogoutEvents() async {
    let h = Harness()
    h.resetStorage()
    defer { h.resetStorage() }

    let (_, store) = h.makeStore()
    var it = store.events.makeAsyncIterator()

    await store.saveCredentials(token: "1:eventTok", userId: 1)
    let e1 = await it.next()
    #expect(e1 == .login(userId: 1, token: "1:eventTok"))

    await store.logOut()
    let e2 = await it.next()
    #expect(e2 == .logout)
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
