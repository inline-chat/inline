import Combine
import Foundation
import KeychainSwift
import Logger

public final class Auth: ObservableObject, @unchecked Sendable {
  public static let shared = Auth()

  private let log = Log.scoped("Auth")
  private let cache: AuthSnapshotCache
  private let store: AuthStore

  /// Sendable handle for RealtimeV2 / transports / actors.
  public let handle: AuthHandle

  // MARK: - Public observable state (UI)

  // Initialized with safe defaults and then synced from the snapshot cache on the MainActor.
  @MainActor @Published public private(set) var status: AuthStatus = .hydrating
  @MainActor @Published public private(set) var didHydrateCredentials: Bool = false
  @MainActor @Published public private(set) var isLoggedIn: Bool = false
  @MainActor @Published public private(set) var currentUserId: Int64? = nil
  @MainActor @Published public private(set) var token: String? = nil

  /// Auth lifecycle events (login/logout). Read-only.
  public var events: AsyncStream<AuthEvent> { store.events }

  private var snapshotsTask: Task<Void, Never>?

  private init() {
    cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    store = AuthStore(cache: cache, mocked: false)
    handle = AuthHandle(cache: cache, store: store, events: store.events)

    startListening()
    syncUIFromCache()
  }

  init(mockAuthenticated: Bool) {
    let namespace = UUID().uuidString

    // Seed mock storage synchronously before the store reads from it.
    let keychain = AuthKeychainConfig.makePrimaryKeychain(mocked: true, namespace: namespace)
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
    let userDefaultsKey = "\(prefix)userId"

    if mockAuthenticated {
      let token = "1:mockToken"
      _ = keychain.set(token, forKey: "token", withAccess: .accessibleAfterFirstUnlock)
      let creds = AuthCredentials(userId: 1, token: token)
      if let data = try? JSONEncoder().encode(creds) {
        _ = keychain.set(data, forKey: "credentials_v2", withAccess: .accessibleAfterFirstUnlock)
      }
      UserDefaults.standard.set(NSNumber(value: 1), forKey: userDefaultsKey)
    } else {
      _ = keychain.delete("token")
      _ = keychain.delete("credentials_v2")
      UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    cache = AuthSnapshotCache(initial: AuthSnapshot(status: .hydrating, didHydrate: false))
    store = AuthStore(cache: cache, mocked: true, namespace: namespace)
    handle = AuthHandle(cache: cache, store: store, events: store.events)

    startListening()
    syncUIFromCache()
  }

  deinit {
    snapshotsTask?.cancel()
    snapshotsTask = nil
  }

  private func startListening() {
    let snapshots = store.snapshots
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

  private func syncUIFromCache() {
    let snapshot = cache.snapshot()
    Task { @MainActor [weak self] in
      self?.apply(snapshot)
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

  // MARK: - Mutations

  public func saveCredentials(token: String, userId: Int64) async {
    log.info("AUTH2 saveCredentials called userId=\(userId)")
    await store.saveCredentials(token: token, userId: userId)
  }

  public func logOut() async {
    log.info("AUTH2 logout called")
    await store.logOut()
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
