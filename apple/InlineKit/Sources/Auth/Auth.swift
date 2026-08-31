import Combine
import Foundation
import Logger

public final class Auth: ObservableObject, @unchecked Sendable {
  public static let shared = Auth()

  private let log = Log.scoped("Auth")
  private let cache: AuthSnapshotCache
  private let store: AuthStore

  /// Sendable handle for RealtimeV2 / transports / actors.
  public let handle: AuthHandle

  // MARK: - Public observable state (UI)

  // Initialized with safe defaults, then updated by the ordered snapshot stream on the MainActor.
  @MainActor @Published public private(set) var status: AuthStatus = .hydrating
  @MainActor @Published public private(set) var didHydrateCredentials: Bool = false
  @MainActor @Published public private(set) var isLoggedIn: Bool = false
  @MainActor @Published public private(set) var currentUserId: Int64? = nil
  @MainActor @Published public private(set) var token: String? = nil

  /// Auth lifecycle events (login/logout). Read-only.
  public var events: AsyncStream<AuthEvent> { store.events() }

  /// Current auth state followed by future changes. Each subscriber starts with the latest state.
  public var snapshots: AsyncStream<AuthSnapshot> { store.snapshots() }

  private var snapshotsTask: Task<Void, Never>?

  private init() {
    cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    store = AuthStore(cache: cache, mocked: false)
    handle = AuthHandle(cache: cache, store: store)

    startListening()
    repairUserIdHintOnLaunch()
  }

  init(mockAuthenticated: Bool) {
    let namespace = UUID().uuidString

    // Seed mock storage synchronously before the store reads from it.
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
    let userDefaultsKey = "\(prefix)userId"

    if mockAuthenticated {
      let token = "1:mockToken"
      AuthKeychainConfig.mockSet(token, forKey: "token", namespace: namespace)
      let creds = AuthCredentials(userId: 1, token: token)
      if let data = try? JSONEncoder().encode(creds) {
        AuthKeychainConfig.mockSet(data, forKey: "credentials_v2", namespace: namespace)
      }
      UserDefaults.standard.set(NSNumber(value: 1), forKey: userDefaultsKey)
    } else {
      AuthKeychainConfig.mockDelete("token", namespace: namespace)
      AuthKeychainConfig.mockDelete("credentials_v2", namespace: namespace)
      UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    store = AuthStore(cache: cache, mocked: true, namespace: namespace)
    handle = AuthHandle(cache: cache, store: store)

    startListening()
  }

  deinit {
    snapshotsTask?.cancel()
    snapshotsTask = nil
  }

  private func startListening() {
    // Subscription synchronously replays the current snapshot and buffers later changes.
    // A separate queued cache seed could duplicate or overwrite a newer stream update.
    let snapshots = store.snapshots()
    snapshotsTask?.cancel()
    snapshotsTask = Task { [weak self] in
      for await snapshot in snapshots {
        guard let self else { return }
        await MainActor.run {
          self.apply(snapshot)
        }
      }
    }
  }

  private func repairUserIdHintOnLaunch() {
    let store = store
    Task {
      await store.repairUserIdHint()
    }
  }

  @MainActor private func apply(_ snapshot: AuthSnapshot) {
    status = snapshot.status
    didHydrateCredentials = snapshot.didHydrate
    isLoggedIn = snapshot.isLoggedIn
    currentUserId = snapshot.currentUserId
    token = snapshot.token
  }

  // MARK: - Sync accessors (thread-safe via snapshot cache)

  public func getToken() -> String? { cache.snapshot().token }
  public func getIsLoggedIn() -> Bool { cache.snapshot().isLoggedIn }
  public func getCurrentUserId() -> Int64? { cache.snapshot().currentUserId }
  public func getStatus() -> AuthStatus { cache.snapshot().status }
  public func getInlineProtocolCredentials() -> InlineProtocolSessionCredentials? {
    cache.snapshot().inlineProtocol
  }

  // MARK: - Mutations

  public func saveCredentials(
    token: String,
    userId: Int64,
    loginAttempt: AuthLoginAttempt? = nil
  ) async throws {
    log.info("AUTH2 saveCredentials called userId=\(userId)")
    try await store.saveCredentials(
      token: token,
      userId: userId,
      loginAttempt: loginAttempt
    )
  }

  public func saveInlineProtocolCredentials(
    _ credentials: InlineProtocolSessionCredentials,
    loginAttempt: AuthLoginAttempt? = nil
  ) async throws {
    try await store.saveInlineProtocolCredentials(credentials, loginAttempt: loginAttempt)
  }

  public func destroyCredentialsForPendingLogout(
    fence: AuthLogoutFence
  ) async -> AuthCredentialDestructionProof? {
    await store.destroyCredentialsForPendingLogout(fence: fence)
  }

  public func beginLogout() async throws -> AuthLogoutFence {
    try await store.beginLogout()
  }

  /// Writes the durable marker and invalidates in-process login attempts without an actor hop.
  /// Platform logout owners call this before their first suspension point.
  public func beginLogoutSynchronously() throws -> AuthLogoutFence {
    try store.beginLogoutSynchronously()
  }

  public func publishLogoutInProgress() async {
    await store.publishLogoutInProgress()
  }

  public func hasPendingLogout() async -> Bool {
    store.hasPendingLogout()
  }

  public func requireLoginAllowed() async throws {
    try await store.requireLoginAllowed()
  }

  public func beginLoginAttempt(allowAuthenticated: Bool = false) async throws -> AuthLoginAttempt {
    try await store.beginLoginAttempt(allowAuthenticated: allowAuthenticated)
  }

  public func validateLoginAttempt(_ attempt: AuthLoginAttempt) async throws {
    try await store.validateLoginAttempt(attempt)
  }

  public func isLoginAttemptCurrent(_ attempt: AuthLoginAttempt) -> Bool {
    cache.isLoginAttemptCurrent(attempt)
  }

  @discardableResult
  public func cancelLoginAttempt(_ attempt: AuthLoginAttempt) -> Bool {
    cache.invalidateLoginAttempt(attempt)
  }

  public func invalidateLoginAttemptsSynchronously() {
    cache.invalidateLoginAttempts()
  }

  public func getHasPendingLogout() -> Bool {
    store.hasPendingLogout()
  }

  public func getCurrentLogoutFence() -> AuthLogoutFence? {
    store.currentLogoutFence()
  }

  public func getHasPendingAccountTransition() -> Bool {
    store.hasPendingAccountTransition()
  }

  public func rollbackCredentialsCommittedByLoginAttempt(_ attempt: AuthLoginAttempt) async {
    await store.rollbackCredentialsCommittedByLoginAttempt(attempt)
  }

  @_spi(LogoutCoordinator)
  public func completePendingLogout(
    fence: AuthLogoutFence,
    databaseProof: AuthDatabaseCleanupProof,
    credentialProof: AuthCredentialDestructionProof,
    completionPermit: AuthLogoutCompletionPermit
  ) async -> Bool {
    await store.completePendingLogout(
      fence: fence,
      databaseProof: databaseProof,
      credentialProof: credentialProof,
      completionPermit: completionPermit
    )
  }

  public func refreshFromStorage() async {
    await store.refreshFromStorage()
  }

  /// Used in previews/tests.
  public static func mocked(authenticated: Bool) -> Auth {
    Auth(mockAuthenticated: authenticated)
  }

  public nonisolated static func getCurrentUserId() -> Int64? {
    let key = "\(AuthKeychainConfig.userDefaultsPrefix(mocked: false))userId"
    guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return nil }
    return number.int64Value
  }
}
