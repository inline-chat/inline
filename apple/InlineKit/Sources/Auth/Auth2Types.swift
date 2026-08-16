import Foundation
import InlineProtocol

public struct InlineProtocolSessionCredentials: Sendable, Codable, Equatable {
  public var userId: Int64
  public var accountSessionId: Int64
  public var permanent: InlineProtocolAuthorization
  public var temporary: InlineProtocolAuthorization?
  public var createdAt: Date

  public init(
    userId: Int64,
    accountSessionId: Int64,
    permanent: InlineProtocolAuthorization,
    temporary: InlineProtocolAuthorization? = nil,
    createdAt: Date = Date()
  ) {
    self.userId = userId
    self.accountSessionId = accountSessionId
    self.permanent = permanent
    self.temporary = temporary
    self.createdAt = createdAt
  }
}

public enum AuthStorageError: Error, Sendable {
  case encodingFailed
  case keychainWriteFailed
}

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
  /// V3-native account session authenticated by a permanent Inline Protocol authorization key.
  case authenticatedV3(userId: Int64)

  public var isAuthenticated: Bool {
    switch self {
    case .authenticated, .authenticatedV3: true
    default: false
    }
  }

  public var userId: Int64? {
    switch self {
    case .authenticated(let c): c.userId
    case .authenticatedV3(let userId): userId
    case .locked(let hint): hint
    case .reauthRequired(let hint): hint
    case .hydrating, .unauthenticated: nil
    }
  }

  public var token: String? {
    switch self {
    case .authenticated(let c): c.token
    case .hydrating, .unauthenticated, .locked, .reauthRequired, .authenticatedV3: nil
    }
  }
}

public struct AuthSnapshot: Sendable, Equatable {
  public var status: AuthStatus
  public var didHydrate: Bool
  public var inlineProtocol: InlineProtocolSessionCredentials?

  public init(
    status: AuthStatus,
    didHydrate: Bool,
    inlineProtocol: InlineProtocolSessionCredentials? = nil
  ) {
    self.status = status
    self.didHydrate = didHydrate
    self.inlineProtocol = inlineProtocol
  }

  public var isLoggedIn: Bool { status.isAuthenticated }
  public var currentUserId: Int64? {
    switch status {
    case .authenticated(let c): c.userId
    case .authenticatedV3(let userId): userId
    default: inlineProtocol?.userId
    }
  }
  public var token: String? { status.token }
}

public enum AuthEvent: Sendable, Equatable {
  case login(userId: Int64, token: String)
  case loginV3(userId: Int64)
  case logout
}

/// Sendable handle for non-UI code (actors, transports, etc.).
///
/// This avoids passing the `Auth` ObservableObject across concurrency domains.
public struct AuthHandle: Sendable {
  fileprivate let cache: AuthSnapshotCache
  fileprivate let store: AuthStore

  init(cache: AuthSnapshotCache, store: AuthStore) {
    self.cache = cache
    self.store = store
  }

  public func snapshot() -> AuthSnapshot { cache.snapshot() }
  public var events: AsyncStream<AuthEvent> { store.events() }
  public var snapshots: AsyncStream<AuthSnapshot> { store.snapshots() }
  public func token() -> String? { cache.snapshot().token }
  public func userId() -> Int64? { cache.snapshot().currentUserId }
  public func isLoggedIn() -> Bool { cache.snapshot().isLoggedIn }
  public func inlineProtocolCredentials() -> InlineProtocolSessionCredentials? {
    cache.snapshot().inlineProtocol
  }

  public func refreshFromStorage() async {
    await store.refreshFromStorage()
  }

  public func saveInlineProtocolCredentials(_ credentials: InlineProtocolSessionCredentials) async throws {
    try await store.saveInlineProtocolCredentials(credentials)
  }
}
