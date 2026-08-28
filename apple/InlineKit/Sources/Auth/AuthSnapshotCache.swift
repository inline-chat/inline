import Foundation

/// Thread-safe snapshot cache so synchronous callers (DB init, HTTP headers, etc.) can read auth state
/// without `await`.
///
/// Swift can't prove thread-safety here, but all access is protected by a lock.
final class AuthSnapshotCache: @unchecked Sendable {
  private let lock = NSLock()
  private var _snapshot: AuthSnapshot
  private var loginGeneration: UInt64 = 0
  private var accountMutationGeneration: UInt64 = 0
  private var logoutFence: AuthLogoutFence?
  private var stagedAuthorityOwner: AuthLoginAttempt?
  private var stagedAuthoritySnapshot: AuthSnapshot?
  private var loginCommitPending = false
  private var stagedAuthorityFinalizing = false
  private var stagedAuthorityPreservesAccountMutationGeneration = false
  private var committedAuthorityOwner: AuthLoginAttempt?

  init(initial: AuthSnapshot) {
    _snapshot = initial
  }

  func snapshot() -> AuthSnapshot {
    lock.withLock { _snapshot }
  }

  @discardableResult
  func update(_ snapshot: AuthSnapshot) -> Bool {
    lock.withLock {
      if logoutFence != nil {
        guard case .loggingOut = snapshot.status else { return false }
      }
      if loginCommitPending, snapshot.status.isAuthenticated {
        return false
      }
      _snapshot = snapshot
      if snapshot.status.isAuthenticated == false {
        accountMutationGeneration &+= 1
        committedAuthorityOwner = nil
      }
      return true
    }
  }

  /// Closes account-mutation admission before a login attempt writes durable authority.
  /// Only one staged owner exists; duplicate attempts are rejected until it publishes or rolls back.
  func beginAuthorityStaging(
    _ attempt: AuthLoginAttempt,
    preservesAccountMutationGeneration: Bool = false
  ) -> Bool {
    lock.withLock {
      guard logoutFence == nil, loginCommitPending == false,
            attempt.generation == loginGeneration
      else { return false }
      loginCommitPending = true
      stagedAuthorityOwner = attempt
      stagedAuthoritySnapshot = nil
      stagedAuthorityFinalizing = false
      stagedAuthorityPreservesAccountMutationGeneration = preservesAccountMutationGeneration
      return true
    }
  }

  @discardableResult
  func cancelAuthorityStagingReservation(_ attempt: AuthLoginAttempt) -> Bool {
    lock.withLock {
      guard logoutFence == nil, loginCommitPending, stagedAuthorityOwner == attempt else {
        return false
      }
      stagedAuthorityOwner = nil
      stagedAuthoritySnapshot = nil
      loginCommitPending = false
      stagedAuthorityFinalizing = false
      stagedAuthorityPreservesAccountMutationGeneration = false
      return true
    }
  }

  func finishAuthorityStaging(_ snapshot: AuthSnapshot, owner attempt: AuthLoginAttempt) -> Bool {
    lock.withLock {
      guard logoutFence == nil, loginCommitPending,
            stagedAuthorityOwner == attempt,
            attempt.generation == loginGeneration,
            snapshot.status.isAuthenticated
      else { return false }
      stagedAuthoritySnapshot = snapshot
      return true
    }
  }

  func isStagedAuthorityOwned(by attempt: AuthLoginAttempt) -> Bool {
    lock.withLock { loginCommitPending && stagedAuthorityOwner == attempt }
  }

  /// Projection success is the login commit point. Once reserved, ordinary login cancellation can
  /// no longer supersede the completed projection; a logout fence can still win and clean it up.
  func prepareStagedAuthorityFinalization(_ attempt: AuthLoginAttempt) -> Bool {
    lock.withLock {
      guard logoutFence == nil, loginCommitPending,
            stagedAuthorityOwner == attempt,
            attempt.generation == loginGeneration,
            stagedAuthoritySnapshot != nil
      else { return false }
      if stagedAuthorityFinalizing { return true }
      stagedAuthorityFinalizing = true
      return true
    }
  }

  /// Durable marker removal happens after `prepareStagedAuthorityFinalization` and before this
  /// publication. A process loss in that interval is safe: credentials and minimum projection are
  /// already complete, so marker absence means launch may hydrate the committed account.
  func finalizeStagedAuthority(
    _ attempt: AuthLoginAttempt,
    publish: (AuthSnapshot) -> Void
  ) -> AuthAccountMutationToken? {
    lock.withLock {
      guard logoutFence == nil, loginCommitPending,
            stagedAuthorityOwner == attempt,
            stagedAuthorityFinalizing,
            let snapshot = stagedAuthoritySnapshot,
            let userID = snapshot.currentUserId
      else { return nil }
      _snapshot = snapshot
      stagedAuthorityOwner = nil
      stagedAuthoritySnapshot = nil
      loginCommitPending = false
      stagedAuthorityFinalizing = false
      let preservesAccountMutationGeneration = stagedAuthorityPreservesAccountMutationGeneration
      stagedAuthorityPreservesAccountMutationGeneration = false
      committedAuthorityOwner = attempt
      if preservesAccountMutationGeneration == false {
        accountMutationGeneration &+= 1
      }
      publish(snapshot)
      return AuthAccountMutationToken(generation: accountMutationGeneration, userID: userID)
    }
  }

  func abortAuthorityStaging(
    _ attempt: AuthLoginAttempt
  ) -> Bool {
    lock.withLock {
      guard logoutFence == nil, loginCommitPending,
            stagedAuthorityOwner == attempt
      else { return false }
      stagedAuthorityOwner = nil
      stagedAuthoritySnapshot = nil
      loginCommitPending = false
      stagedAuthorityFinalizing = false
      stagedAuthorityPreservesAccountMutationGeneration = false
      return true
    }
  }

  func seedLoginCommitPending(_ pending: Bool) {
    lock.withLock {
      guard pending else {
        stagedAuthorityOwner = nil
        stagedAuthoritySnapshot = nil
        loginCommitPending = false
        stagedAuthorityFinalizing = false
        stagedAuthorityPreservesAccountMutationGeneration = false
        committedAuthorityOwner = nil
        return
      }
      loginGeneration &+= 1
      accountMutationGeneration &+= 1
      committedAuthorityOwner = nil
      stagedAuthorityOwner = nil
      stagedAuthoritySnapshot = nil
      loginCommitPending = true
      stagedAuthorityFinalizing = false
      stagedAuthorityPreservesAccountMutationGeneration = false
    }
  }

  func seedLogoutPending(_ pending: Bool, correlationID: UUID? = nil) {
    lock.withLock {
      guard pending else {
        logoutFence = nil
        return
      }
      guard logoutFence == nil else { return }
      loginGeneration &+= 1
      accountMutationGeneration &+= 1
      committedAuthorityOwner = nil
      logoutFence = AuthLogoutFence(
        generation: loginGeneration,
        correlationID: correlationID ?? UUID()
      )
    }
  }

  func beginLogout(
    correlationID: UUID = UUID()
  ) -> AuthLogoutFence {
    lock.withLock {
      if let logoutFence { return logoutFence }
      loginGeneration &+= 1
      accountMutationGeneration &+= 1
      committedAuthorityOwner = nil
      let fence = AuthLogoutFence(generation: loginGeneration, correlationID: correlationID)
      // Close in-process admission immediately. Durable persistence happens synchronously after
      // this short critical section and before the platform starts any destructive/awaited work.
      logoutFence = fence
      return fence
    }
  }

  func currentLogoutFence() -> AuthLogoutFence? {
    lock.withLock { logoutFence }
  }

  @discardableResult
  func abortUnpersistedLogoutFence(durableMarkerIsAbsent: Bool) -> Bool {
    lock.withLock {
      guard logoutFence != nil, durableMarkerIsAbsent else { return false }
      logoutFence = nil
      // Do not revive work invalidated by the attempted transition.
      loginGeneration &+= 1
      accountMutationGeneration &+= 1
      committedAuthorityOwner = nil
      return true
    }
  }

  func completeLogout(
    _ fence: AuthLogoutFence,
    snapshot: AuthSnapshot,
    publish: () -> Void
  ) -> Bool {
    lock.withLock {
      guard logoutFence == fence else { return false }
      _snapshot = snapshot
      stagedAuthorityOwner = nil
      stagedAuthoritySnapshot = nil
      loginCommitPending = false
      stagedAuthorityFinalizing = false
      stagedAuthorityPreservesAccountMutationGeneration = false
      committedAuthorityOwner = nil
      logoutFence = nil
      publish()
      return true
    }
  }

  func makeLoginAttempt() -> AuthLoginAttempt {
    lock.withLock {
      loginGeneration &+= 1
      committedAuthorityOwner = nil
      return AuthLoginAttempt(generation: loginGeneration)
    }
  }

  /// Same-account credential rotation participates in authority staging without superseding an
  /// unrelated interactive login attempt. The staging reservation still serializes the actual
  /// keychain replacement against login and logout commits.
  func makeSameAccountAuthorityReplacementAttempt() -> AuthLoginAttempt? {
    lock.withLock {
      guard logoutFence == nil, loginCommitPending == false else { return nil }
      return AuthLoginAttempt(generation: loginGeneration)
    }
  }

  func isLoginAttemptCurrent(_ attempt: AuthLoginAttempt) -> Bool {
    lock.withLock {
      logoutFence == nil && attempt.generation == loginGeneration
    }
  }

  @discardableResult
  func invalidateLoginAttempt(_ attempt: AuthLoginAttempt) -> Bool {
    lock.withLock {
      guard logoutFence == nil, stagedAuthorityFinalizing == false,
            committedAuthorityOwner != attempt,
            attempt.generation == loginGeneration
      else { return false }
      loginGeneration &+= 1
      return true
    }
  }

  func invalidateLoginAttempts() {
    lock.withLock {
      guard logoutFence == nil, stagedAuthorityFinalizing == false,
            committedAuthorityOwner?.generation != loginGeneration
      else { return }
      loginGeneration &+= 1
    }
  }

  func isLogoutFenceCurrent(_ fence: AuthLogoutFence) -> Bool {
    lock.withLock { logoutFence == fence }
  }

  func hasPendingLogout() -> Bool {
    lock.withLock { logoutFence != nil }
  }

  func hasPendingAccountTransition() -> Bool {
    lock.withLock { logoutFence != nil || loginCommitPending }
  }

  func hasPendingLoginCommit() -> Bool {
    lock.withLock { loginCommitPending }
  }

  func makeAccountMutationToken() throws -> AuthAccountMutationToken {
    try lock.withLock {
      guard logoutFence == nil, loginCommitPending == false,
            let userID = _snapshot.currentUserId,
            _snapshot.status.isAuthenticated
      else {
        throw logoutFence != nil
          ? AuthStorageError.logoutInProgress
          : AuthStorageError.loginUnavailable
      }
      return AuthAccountMutationToken(generation: accountMutationGeneration, userID: userID)
    }
  }

  func validateAccountMutationToken(_ token: AuthAccountMutationToken) throws {
    try lock.withLock {
      guard logoutFence == nil, loginCommitPending == false,
            accountMutationGeneration == token.generation,
            _snapshot.status.isAuthenticated,
            _snapshot.currentUserId == token.userID
      else {
        throw logoutFence != nil
          ? AuthStorageError.logoutInProgress
          : AuthStorageError.loginUnavailable
      }
    }
  }
}
