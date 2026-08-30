import Foundation
import InlineProtocol
import Logger

public extension Notification.Name {
  /// A staged credential transition could not be safely rolled back and now requires the
  /// platform-owned logout recovery flow. Carries no account data.
  static let authAccountRecoveryRequired = Notification.Name(
    "inline.auth.accountRecoveryRequired"
  )
}

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

  func validate() throws {
    guard userId > 0, accountSessionId > 0,
          !permanent.temporary, permanent.expiresAt == nil
    else { throw InlineProtocolError.invalidInput }
    _ = try InlineProtocolAuthorization(
      key: permanent.key, keyID: permanent.keyID, serverSalt: permanent.serverSalt,
      temporary: permanent.temporary, expiresAt: permanent.expiresAt
    )
    if let temporary {
      guard temporary.temporary, let expiresAt = temporary.expiresAt, expiresAt > 0 else {
        throw InlineProtocolError.invalidInput
      }
      _ = try InlineProtocolAuthorization(
        key: temporary.key, keyID: temporary.keyID, serverSalt: temporary.serverSalt,
        temporary: temporary.temporary, expiresAt: temporary.expiresAt
      )
      // An expired, well-formed temporary key is recoverable using the permanent
      // authority. Do not use local wall time to invalidate that account.
    }
  }
}

public enum AuthStorageError: Error, LocalizedError, Sendable, PrivacySafeErrorCategoryProviding {
  case encodingFailed
  case keychainWriteFailed
  case keychainDeleteFailed
  case logoutInProgress
  case logoutFencePersistenceFailed
  case loginUnavailable
  case loginSuperseded
  case alreadyAuthenticated

  public var errorDescription: String? {
    switch self {
    case .encodingFailed, .keychainWriteFailed:
      "Inline couldn’t securely save your session. Please try again."
    case .keychainDeleteFailed:
      "Inline couldn’t finish signing out. Quit and reopen Inline to try again safely."
    case .logoutInProgress:
      "Inline is still finishing sign out. Quit and reopen Inline, then try again."
    case .logoutFencePersistenceFailed:
      "Inline couldn’t safely begin signing out. Quit and reopen Inline, then try again."
    case .loginUnavailable:
      "Inline is still preparing secure account storage. Quit and reopen Inline, then try again."
    case .loginSuperseded:
      "This sign-in attempt expired while Inline changed accounts. Please try again."
    case .alreadyAuthenticated:
      "Inline is already signed in."
    }
  }

  public var privacySafeErrorCategory: String {
    switch self {
    case .encodingFailed: "auth_storage:encoding_failed"
    case .keychainWriteFailed: "auth_storage:keychain_write_failed"
    case .keychainDeleteFailed: "auth_storage:keychain_delete_failed"
    case .logoutInProgress: "auth_storage:logout_in_progress"
    case .logoutFencePersistenceFailed: "auth_storage:logout_fence_persistence_failed"
    case .loginUnavailable: "auth_storage:login_unavailable"
    case .loginSuperseded: "auth_storage:login_superseded"
    case .alreadyAuthenticated: "auth_storage:already_authenticated"
    }
  }
}

/// Identifies one in-process login attempt. A newer login or logout advances the generation, so
/// work begun by an older onboarding screen cannot commit after the owning UI has been superseded.
public struct AuthLoginAttempt: Sendable, Equatable {
  let generation: UInt64
  public let correlationID: UUID

  init(generation: UInt64, correlationID: UUID = UUID()) {
    self.generation = generation
    self.correlationID = correlationID
  }
}

/// A synchronous lease for one authenticated account generation. Work admitted before an
/// account transition must revalidate this immediately before every account-owned DB projection.
public struct AuthAccountMutationToken: Sendable, Equatable {
  let generation: UInt64
  public let userID: Int64

  init(generation: UInt64, userID: Int64) {
    self.generation = generation
    self.userID = userID
  }
}

/// One durable logout transition. Repeated begin calls and launch recovery reuse the same opaque
/// identifier so cleanup proofs and privacy-safe diagnostics cannot be mixed across attempts.
public struct AuthLogoutFence: Sendable, Equatable {
  let generation: UInt64
  public let correlationID: UUID

  init(generation: UInt64, correlationID: UUID) {
    self.generation = generation
    self.correlationID = correlationID
  }
}

/// Opaque evidence that every credential authority was removed for one exact logout fence.
/// Only Auth can construct this value.
public struct AuthCredentialDestructionProof: Sendable {
  let fence: AuthLogoutFence

  init(fence: AuthLogoutFence) {
    self.fence = fence
  }
}

/// Opaque evidence that account database cleanup completed for one exact logout fence.
/// InlineKit is the only production module allowed to construct this value after clear/verify/rekey.
public struct AuthDatabaseCleanupProof: Sendable {
  let fence: AuthLogoutFence

  public init(fence: AuthLogoutFence) {
    self.fence = fence
  }
}

/// A platform-owned terminal gate for the final marker-removal commit. A UI deadline can revoke
/// it without an actor hop; Auth marks it completed atomically with in-memory logout completion.
public final class AuthLogoutCompletionPermit: @unchecked Sendable {
  private enum State { case active, revoked, completed }
  private let lock = NSLock()
  let fence: AuthLogoutFence
  private var state = State.active

  public init(fence: AuthLogoutFence) {
    self.fence = fence
  }

  @discardableResult
  public func revoke() -> Bool {
    lock.withLock {
      guard state == .active else { return false }
      state = .revoked
      return true
    }
  }

  func completeIfActive(_ operation: () -> Bool) -> Bool {
    lock.withLock {
      guard state == .active else { return false }
      let completed = operation()
      if completed { state = .completed }
      return completed
    }
  }
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

  var hasConsistentIdentity: Bool {
    guard userId > 0, !token.isEmpty else { return false }
    // Preserve opaque legacy tokens, but never project a different account
    // when the token carries the current numeric user-id prefix.
    guard let separator = token.firstIndex(of: ":"),
          let tokenUserId = Int64(token[..<separator]) else { return true }
    return tokenUserId == userId
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
  /// Durable logout recovery owns the account until app-level cleanup, credential destruction,
  /// and marker removal have all completed. Login must never be presented in this state.
  case loggingOut(userIdHint: Int64?)
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
    case .loggingOut(let hint): hint
    case .hydrating, .unauthenticated: nil
    }
  }

  public var token: String? {
    switch self {
    case .authenticated(let c): c.token
    case .hydrating, .unauthenticated, .locked, .reauthRequired, .loggingOut, .authenticatedV3: nil
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

  public func hasPendingLogout() -> Bool {
    store.hasPendingLogout()
  }

  public func hasPendingAccountTransition() -> Bool {
    store.hasPendingAccountTransition()
  }

  public func requireAccountMutationAllowed(allowDuringLogout: Bool = false) throws {
    if allowDuringLogout { return }
    _ = try cache.makeAccountMutationToken()
  }

  public func beginAccountMutation() throws -> AuthAccountMutationToken {
    try cache.makeAccountMutationToken()
  }

  public func validateAccountMutation(_ token: AuthAccountMutationToken) throws {
    try cache.validateAccountMutationToken(token)
  }

  @discardableResult
  public func cancelLoginAttempt(_ attempt: AuthLoginAttempt) -> Bool {
    cache.invalidateLoginAttempt(attempt)
  }

  public func invalidateLoginAttempts() {
    cache.invalidateLoginAttempts()
  }

  public func reserveLoginCommit(_ attempt: AuthLoginAttempt) -> Bool {
    cache.prepareStagedAuthorityFinalization(attempt)
  }

  public func finalizeCredentialsCommittedByLoginAttempt(
    _ attempt: AuthLoginAttempt
  ) async throws -> AuthAccountMutationToken {
    try await store.finalizeCredentialsCommittedByLoginAttempt(attempt)
  }

  public func saveInlineProtocolCredentials(
    _ credentials: InlineProtocolSessionCredentials,
    loginAttempt: AuthLoginAttempt? = nil
  ) async throws {
    try await store.saveInlineProtocolCredentials(credentials, loginAttempt: loginAttempt)
  }

  public func rollbackCredentialsCommittedByLoginAttempt(_ attempt: AuthLoginAttempt) async {
    await store.rollbackCredentialsCommittedByLoginAttempt(attempt)
  }

  public func promoteProjectedLoginToRecovery(_ attempt: AuthLoginAttempt) async {
    await store.promoteProjectedLoginToRecovery(attempt)
  }
}
