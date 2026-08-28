import Auth
import Foundation
import GRDB
import Logger

public enum LoginStatePreparationError: Error, LocalizedError, Sendable,
  PrivacySafeErrorCategoryProviding
{
  case localStateUnavailable
  case authenticatedAccountMismatch

  public var errorDescription: String? {
    switch self {
    case .localStateUnavailable:
      "Inline couldn’t prepare a clean local account. Quit and reopen Inline, then try again."
    case .authenticatedAccountMismatch:
      "Sign out before signing in to a different Inline account."
    }
  }

  public var privacySafeErrorCategory: String {
    switch self {
    case .localStateUnavailable: "login_preparation:local_state_unavailable"
    case .authenticatedAccountMismatch: "login_preparation:authenticated_account_mismatch"
    }
  }
}

public struct LoginStateCommit<Result: Sendable>: Sendable {
  public let value: Result
  public let accountMutationToken: AuthAccountMutationToken
}

/// One fail-closed local boundary shared by bearer, native-protocol, and provider login commits.
/// Old projection is cleared first, credential authority commits second, and only then is the new
/// user's minimum projection written. No failed credential write can leave old auth with new data.
public enum LoginStatePreparation {
  private static let log = Log.scoped("LoginStatePreparation")

  public static func commit<Result: Sendable>(
    auth: AuthHandle = Auth.shared.handle,
    loginAttempt: AuthLoginAttempt,
    targetUserID: Int64,
    existingAuthenticatedUserID: Int64? = nil,
    persistCredentials: @escaping @Sendable () async throws -> Void,
    writeProjection: @escaping @Sendable (Database) throws -> Result
  ) async throws -> LoginStateCommit<Result> {
    try await commitUsing(
      auth: auth,
      loginAttempt: loginAttempt,
      targetUserID: targetUserID,
      existingAuthenticatedUserID: existingAuthenticatedUserID,
      persistCredentials: persistCredentials,
      writeProjection: writeProjection,
      prepareDatabase: { auth, attempt in
        try await AppDatabase.prepareForLogin(auth: auth, loginAttempt: attempt)
      },
      commitProjection: { auth, attempt, writer in
        try await AppDatabase.commitLoginProjection(
          auth: auth,
          loginAttempt: attempt,
          writeProjection: writer
        )
      }
    )
  }

  /// Test seam for the database boundary. Production always supplies AppDatabase's clear/verify
  /// and projection transaction above; focused tests can exercise the real auth staging state
  /// machine against an isolated GRDB queue.
  static func commitUsing<Result: Sendable>(
    auth: AuthHandle,
    loginAttempt: AuthLoginAttempt,
    targetUserID: Int64,
    existingAuthenticatedUserID: Int64? = nil,
    persistCredentials: @escaping @Sendable () async throws -> Void,
    writeProjection: @escaping @Sendable (Database) throws -> Result,
    prepareDatabase: @escaping @Sendable (AuthHandle, AuthLoginAttempt) async throws -> Void,
    commitProjection: @escaping @Sendable (
      AuthHandle,
      AuthLoginAttempt,
      @escaping @Sendable (Database) throws -> Result
    ) async throws -> Result,
    afterProjectionCommit: @escaping @Sendable () -> Void = {}
  ) async throws -> LoginStateCommit<Result> {
    do {
      try await auth.validateLoginAttempt(loginAttempt)
      if let existingAuthenticatedUserID {
        guard existingAuthenticatedUserID == targetUserID,
              auth.userId() == existingAuthenticatedUserID
        else {
          throw LoginStatePreparationError.authenticatedAccountMismatch
        }
      } else {
        try await prepareDatabase(auth, loginAttempt)
      }
      try await auth.validateLoginAttempt(loginAttempt)

      do {
        try await persistCredentials()
      } catch {
        log.error(
          "LOGIN_TRACE transition_id=\(loginAttempt.correlationID.uuidString) phase=credential_commit_failed",
          error: error
        )
        throw error
      }

      let result: Result
      do {
        result = try await commitProjection(auth, loginAttempt, writeProjection)
      } catch {
        await auth.rollbackCredentialsCommittedByLoginAttempt(loginAttempt)
        throw error
      }
      afterProjectionCommit()

      let accountMutationToken: AuthAccountMutationToken
      do {
        accountMutationToken = try await auth.finalizeCredentialsCommittedByLoginAttempt(loginAttempt)
      } catch {
        // Projection success is irreversible at this boundary. Never restore prior credentials
        // over the committed new-account rows; promote the staged pair to platform recovery.
        await auth.promoteProjectedLoginToRecovery(loginAttempt)
        throw error
      }
      guard accountMutationToken.userID == targetUserID else {
        throw LoginStatePreparationError.authenticatedAccountMismatch
      }
      return LoginStateCommit(value: result, accountMutationToken: accountMutationToken)
    } catch let error as AuthStorageError {
      throw error
    } catch let error as LoginStatePreparationError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      log.error(
        "LOGIN_TRACE transition_id=\(loginAttempt.correlationID.uuidString) phase=local_state_preparation_failed",
        error: error
      )
      throw LoginStatePreparationError.localStateUnavailable
    }
  }
}
