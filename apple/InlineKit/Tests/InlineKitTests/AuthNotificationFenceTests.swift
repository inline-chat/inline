import Foundation
import InlineNotificationFence
import InlineProtocol
import Testing

@_spi(LogoutCoordinator) @testable import Auth

/// The iOS notification extension reads only this fence; these tests pin when AuthStore moves it.
@Suite("Auth notification account fence")
final class AuthNotificationFenceTests {
  private final class FenceStorage: NotificationAccountFenceStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NotificationAccountFence?

    var value: NotificationAccountFence? { lock.withLock { stored } }

    func read() -> NotificationAccountFenceRead {
      lock.withLock { stored.map(NotificationAccountFenceRead.present) ?? .missing }
    }

    func write(_ fence: NotificationAccountFence) -> Bool {
      lock.withLock { stored = fence }
      return true
    }

    func delete() -> Bool {
      lock.withLock { stored = nil }
      return true
    }
  }

  private let namespace = UUID().uuidString
  private let fence = FenceStorage()

  deinit {
    for key in ["token", "credentials_v2", "inline_protocol_credentials_v1"] {
      AuthKeychainConfig.mockDelete(key, namespace: namespace)
    }
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
    for key in ["userId", "logoutPending", "logoutAttemptID", "loginCommitPendingAttemptID"] {
      UserDefaults.standard.removeObject(forKey: "\(prefix)\(key)")
    }
  }

  private func makeStore(
    logoutFencePersistenceOverride: (@Sendable (UUID) -> Bool)? = nil
  ) -> AuthStore {
    AuthStore(
      cache: AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false)),
      mocked: true,
      namespace: namespace,
      logoutFencePersistenceOverride: logoutFencePersistenceOverride,
      notificationFence: NotificationAccountFencePublisher(storage: fence)
    )
  }

  private func completeLogout(_ store: AuthStore) async throws -> Bool {
    let logout = try store.beginLogoutSynchronously()
    guard let credentialProof = await store.destroyCredentialsForPendingLogout(fence: logout) else {
      return false
    }
    return await store.completePendingLogout(
      fence: logout,
      databaseProof: AuthDatabaseCleanupProof(fence: logout),
      credentialProof: credentialProof,
      completionPermit: AuthLogoutCompletionPermit(fence: logout)
    )
  }

  @Test("a fresh install publishes signed out, then the account that signs in")
  func loginPublishesOwner() async throws {
    let store = makeStore()
    #expect(fence.value?.userID == nil)
    #expect(fence.value != nil)

    try await store.saveCredentials(token: "42:token", userId: 42)
    #expect(fence.value?.userID == 42)
  }

  @Test("logout closes the fence before its first suspension")
  func logoutClosesFenceSynchronously() async throws {
    let store = makeStore()
    try await store.saveCredentials(token: "42:token", userId: 42)
    let signedIn = try #require(fence.value)

    // No await between the logout fence and this check: the best-effort logout RPC comes later.
    _ = try store.beginLogoutSynchronously()
    let signedOut = try #require(fence.value)
    #expect(signedOut.userID == nil)
    #expect(signedOut.generation != signedIn.generation)
  }

  @Test("A then logout then A gets a new generation")
  func sameAccountReloginChangesGeneration() async throws {
    let store = makeStore()
    try await store.saveCredentials(token: "42:token", userId: 42)
    let first = try #require(fence.value)

    #expect(try await completeLogout(store))
    #expect(fence.value?.userID == nil)

    try await store.saveCredentials(token: "42:token-2", userId: 42)
    let second = try #require(fence.value)
    #expect(second.userID == 42)
    #expect(second.generation != first.generation)
  }

  @Test("A then B publishes B")
  func accountSwitchPublishesNewOwner() async throws {
    let store = makeStore()
    try await store.saveCredentials(token: "42:token", userId: 42)
    #expect(try await completeLogout(store))
    try await store.saveInlineProtocolCredentials(.init(
      userId: 7,
      accountSessionId: 84,
      permanent: try InlineProtocolAuthorization(
        key: Array(UInt8.min...UInt8.max),
        keyID: InlineSecureTransport.authKeyID(Array(UInt8.min...UInt8.max)),
        serverSalt: 7,
        temporary: false,
        expiresAt: nil
      )
    ))
    #expect(fence.value?.userID == 7)
  }

  @Test("launch repairs the fence from stored credentials")
  func launchRepairsFence() throws {
    let credentials = AuthCredentials(userId: 42, token: "42:token")
    AuthKeychainConfig.mockSet(try JSONEncoder().encode(credentials), forKey: "credentials_v2", namespace: namespace)

    _ = makeStore()
    #expect(fence.value?.userID == 42)
  }

  @Test("a logout interrupted by process death stays signed out at relaunch")
  func pendingLogoutRelaunchStaysSignedOut() async throws {
    let store = makeStore()
    try await store.saveCredentials(token: "42:token", userId: 42)
    _ = try store.beginLogoutSynchronously()
    // A stale write from the old process must not survive relaunch recovery.
    _ = fence.write(.init(userID: 42, generation: 1))

    _ = makeStore()
    #expect(fence.value?.userID == nil)
  }

  @Test("a logout whose durable marker fails keeps the account and its fence")
  func failedLogoutMarkerKeepsFence() async throws {
    let store = makeStore(logoutFencePersistenceOverride: { _ in false })
    try await store.saveCredentials(token: "42:token", userId: 42)

    #expect(throws: AuthStorageError.self) { _ = try store.beginLogoutSynchronously() }
    #expect(fence.value?.userID == 42)
  }
}
