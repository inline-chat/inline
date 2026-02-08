import Foundation

public struct AuthCredentials: Sendable, Codable, Equatable {
  public var userId: Int64
  public var token: String
  public var createdAt: Date

  public init(userId: Int64, token: String, createdAt: Date = Date()) {
    self.userId = userId
    self.token = token
    self.createdAt = createdAt
  }
}

public enum AuthStatus: Sendable, Equatable {
  /// The app hasn't successfully determined whether credentials exist yet.
  case hydrating
  /// No credentials exist (or we intentionally cleared them).
  case unauthenticated
  /// Credentials likely exist, but the keychain is currently unavailable (e.g. iOS before first unlock).
  case locked(userIdHint: Int64?)
  /// We have a userId hint, but the token is missing (keychain item not found / access-group mismatch / wiped).
  /// The app should treat this as logged out, but avoid destructive local recovery (DB deletion).
  case reauthRequired(userIdHint: Int64?)
  /// Credentials are present and usable.
  case authenticated(AuthCredentials)

  public var isAuthenticated: Bool {
    if case .authenticated = self { true } else { false }
  }

  public var userId: Int64? {
    switch self {
    case .authenticated(let c): c.userId
    case .locked(let hint): hint
    case .reauthRequired(let hint): hint
    case .hydrating, .unauthenticated: nil
    }
  }

  public var token: String? {
    switch self {
    case .authenticated(let c): c.token
    case .hydrating, .unauthenticated, .locked, .reauthRequired: nil
    }
  }
}

public struct AuthSnapshot: Sendable, Equatable {
  public var status: AuthStatus
  public var didHydrate: Bool

  public init(status: AuthStatus, didHydrate: Bool) {
    self.status = status
    self.didHydrate = didHydrate
  }

  public var isLoggedIn: Bool { status.isAuthenticated }
  public var currentUserId: Int64? {
    switch status {
    case .authenticated(let c): c.userId
    default: nil
    }
  }
  public var token: String? { status.token }
}

public enum AuthEvent: Sendable, Equatable {
  case login(userId: Int64, token: String)
  case logout
}

/// Sendable handle for non-UI code (actors, transports, etc.).
///
/// This avoids passing the `Auth` ObservableObject across concurrency domains.
public struct AuthHandle: Sendable {
  fileprivate let cache: AuthSnapshotCache
  fileprivate let store: AuthStore
  public let events: AsyncStream<AuthEvent>

  init(cache: AuthSnapshotCache, store: AuthStore, events: AsyncStream<AuthEvent>) {
    self.cache = cache
    self.store = store
    self.events = events
  }

  public func snapshot() -> AuthSnapshot { cache.snapshot() }
  public func token() -> String? { cache.snapshot().token }
  public func userId() -> Int64? { cache.snapshot().currentUserId }
  public func isLoggedIn() -> Bool { cache.snapshot().isLoggedIn }

  public func refreshFromStorage() async {
    await store.refreshFromStorage()
  }
}
