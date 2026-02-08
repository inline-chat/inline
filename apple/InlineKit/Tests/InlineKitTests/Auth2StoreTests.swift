import Foundation
import KeychainSwift
import Testing

@testable import Auth

@Suite("Auth2 Store")
final class Auth2StoreTests {
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
    let keychain: KeychainSwift
    let userDefaultsKey: String

    init() {
      namespace = UUID().uuidString
      keychain = AuthKeychainConfig.makePrimaryKeychain(mocked: true, namespace: namespace)
      userDefaultsKey = "\(AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace))userId"
    }

    func resetStorage() {
      _ = keychain.delete("token")
      _ = keychain.delete("credentials_v2")
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
    #expect(h.keychain.set(data, forKey: "credentials_v2", withAccess: .accessibleAfterFirstUnlock))

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
    #expect(h.keychain.set(token, forKey: "token", withAccess: .accessibleAfterFirstUnlock))
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
    #expect(h.keychain.set(token, forKey: "token", withAccess: .accessibleAfterFirstUnlock))

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
}
