import Foundation
import GRDB
import InlineProtocol
import Testing

@testable import Auth
@testable import InlineKit

@Suite("Login state preparation")
struct LoginStatePreparationTests {
  private enum FixtureError: Error {
    case projectionFailed
  }

  private struct Fixture {
    let namespace = UUID().uuidString
    let cache: AuthSnapshotCache
    let store: AuthStore
    let auth: AuthHandle
    let database: DatabaseQueue

    init(
      authorityReplacementDeletionOverride: (@Sendable (String) -> Bool?)? = nil,
      logoutFencePersistenceOverride: (@Sendable (UUID) -> Bool)? = nil
    ) throws {
      cache = AuthSnapshotCache(
        initial: AuthSnapshot(status: .hydrating, didHydrate: false)
      )
      store = AuthStore(
        cache: cache,
        mocked: true,
        namespace: namespace,
        authorityReplacementDeletionOverride: authorityReplacementDeletionOverride,
        logoutFencePersistenceOverride: logoutFencePersistenceOverride
      )
      auth = AuthHandle(cache: cache, store: store)
      database = try DatabaseQueue()
      try database.write { db in
        try db.execute(sql: "CREATE TABLE account_projection (id INTEGER PRIMARY KEY AUTOINCREMENT)")
        try db.execute(sql: "INSERT INTO account_projection (id) VALUES (1)")
      }
    }

    func reset() {
      AuthKeychainConfig.mockDelete("token", namespace: namespace)
      AuthKeychainConfig.mockDelete("credentials_v2", namespace: namespace)
      AuthKeychainConfig.mockDelete("inline_protocol_credentials_v1", namespace: namespace)
      DatabaseKeyStore.delete(mocked: true, namespace: namespace)
      let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: namespace)
      for suffix in ["userId", "logoutPending", "logoutAttemptID", "loginCommitPendingAttemptID"] {
        UserDefaults.standard.removeObject(forKey: "\(prefix)\(suffix)")
      }
    }

    func prepare(_ auth: AuthHandle, _ attempt: AuthLoginAttempt) async throws {
      try await database.write { db in
        try AppDatabase.prepareLoginDatabase(
          db,
          isCurrent: { auth.isLoginAttemptCurrent(attempt) }
        )
      }
    }

    func project<Result: Sendable>(
      _ auth: AuthHandle,
      _ attempt: AuthLoginAttempt,
      _ writer: @escaping @Sendable (Database) throws -> Result
    ) async throws -> Result {
      try await database.write { db in
        try AppDatabase.writeLoginProjection(
          db,
          isCurrent: { auth.isLoginAttemptCurrent(attempt) },
          reserveCommit: { auth.reserveLoginCommit(attempt) },
          writeProjection: writer
        )
      }
    }

    func storedIDs() throws -> [Int64] {
      try database.read { db in
        try Int64.fetchAll(db, sql: "SELECT id FROM account_projection ORDER BY id")
      }
    }
  }

  private func v3Credentials(userID: Int64) throws -> InlineProtocolSessionCredentials {
    let key = Array(UInt8.min...UInt8.max)
    return try InlineProtocolSessionCredentials(
      userId: userID,
      accountSessionId: 84,
      permanent: InlineProtocolAuthorization(
        key: key,
        keyID: InlineSecureTransport.authKeyID(key),
        serverSalt: 7,
        temporary: false,
        expiresAt: nil
      )
    )
  }

  @Test("clear, authority staging, projection, and publication form one login commit")
  func freshLoginCommitOrder() async throws {
    let fixture = try Fixture()
    defer { fixture.reset() }
    let attempt = try await fixture.auth.beginLoginAttempt()

    let commit = try await LoginStatePreparation.commitUsing(
      auth: fixture.auth,
      loginAttempt: attempt,
      targetUserID: 42,
      persistCredentials: {
        try await fixture.store.saveCredentials(
          token: "42:committed",
          userId: 42,
          loginAttempt: attempt
        )
      },
      writeProjection: { db in
        try db.execute(sql: "INSERT INTO account_projection (id) VALUES (42)")
        return Int64(42)
      },
      prepareDatabase: fixture.prepare,
      commitProjection: { auth, attempt, writer in
        // Durable authority is staged, but observers and DB writers remain closed until the
        // minimum projection succeeds and the exact owner finalizes.
        #expect(fixture.cache.snapshot().status == .unauthenticated)
        #expect(throws: AuthStorageError.self) {
          _ = try auth.beginAccountMutation()
        }
        return try await fixture.project(auth, attempt, writer)
      }
    )

    #expect(commit.value == 42)
    #expect(commit.accountMutationToken.userID == 42)
    #expect(fixture.cache.snapshot().token == "42:committed")
    #expect(try fixture.storedIDs() == [42])
  }

  @Test("projection failure rolls back staged authority without exposing a new-user row")
  func projectionFailureRollsBackAuthority() async throws {
    let fixture = try Fixture()
    defer { fixture.reset() }
    let attempt = try await fixture.auth.beginLoginAttempt()

    do {
      _ = try await LoginStatePreparation.commitUsing(
        auth: fixture.auth,
        loginAttempt: attempt,
        targetUserID: 42,
        persistCredentials: {
          try await fixture.store.saveCredentials(
            token: "42:rolled-back",
            userId: 42,
            loginAttempt: attempt
          )
        },
        writeProjection: { _ in throw FixtureError.projectionFailed },
        prepareDatabase: fixture.prepare,
        commitProjection: fixture.project
      )
      Issue.record("Expected projection failure")
    } catch LoginStatePreparationError.localStateUnavailable {
      // Unknown database failures are normalized after Auth has rolled back authority.
    }

    #expect(fixture.cache.snapshot().status == .unauthenticated)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: fixture.namespace) == nil)
    #expect(AuthKeychainConfig.mockGetData("credentials_v2", namespace: fixture.namespace) == nil)
    #expect(try fixture.storedIDs().isEmpty)
  }

  @Test("cancellation before the projection commit reservation rolls back DB and authority")
  func cancellationBeforeProjectionReservationRollsBack() async throws {
    let fixture = try Fixture()
    defer { fixture.reset() }
    let attempt = try await fixture.auth.beginLoginAttempt()

    do {
      _ = try await LoginStatePreparation.commitUsing(
        auth: fixture.auth,
        loginAttempt: attempt,
        targetUserID: 42,
        persistCredentials: {
          try await fixture.store.saveCredentials(
            token: "42:canceled-before-commit",
            userId: 42,
            loginAttempt: attempt
          )
        },
        writeProjection: { db in
          try db.execute(sql: "INSERT INTO account_projection (id) VALUES (42)")
        },
        prepareDatabase: fixture.prepare,
        commitProjection: { auth, attempt, writer in
          try await fixture.database.write { db in
            try AppDatabase.writeLoginProjection(
              db,
              isCurrent: { auth.isLoginAttemptCurrent(attempt) },
              reserveCommit: {
                #expect(auth.cancelLoginAttempt(attempt))
                return auth.reserveLoginCommit(attempt)
              },
              writeProjection: writer
            )
          }
        }
      )
      Issue.record("Expected canceled projection commit to fail")
    } catch AuthStorageError.loginSuperseded {
      // The insertion transaction and staged authority are both rolled back.
    }

    #expect(fixture.cache.snapshot().status == .unauthenticated)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: fixture.namespace) == nil)
    #expect(try fixture.storedIDs().isEmpty)
  }

  @Test("credential persistence failure leaves the cleared database empty and unauthenticated")
  func credentialFailureDoesNotProjectNewUser() async throws {
    let fixture = try Fixture(
      authorityReplacementDeletionOverride: { label in
        label == "inline_protocol" ? false : nil
      }
    )
    defer { fixture.reset() }
    let attempt = try await fixture.auth.beginLoginAttempt()

    do {
      _ = try await LoginStatePreparation.commitUsing(
        auth: fixture.auth,
        loginAttempt: attempt,
        targetUserID: 42,
        persistCredentials: {
          try await fixture.store.saveCredentials(
            token: "42:must-not-persist",
            userId: 42,
            loginAttempt: attempt
          )
        },
        writeProjection: { db in
          try db.execute(sql: "INSERT INTO account_projection (id) VALUES (42)")
        },
        prepareDatabase: fixture.prepare,
        commitProjection: fixture.project
      )
      Issue.record("Expected credential authority replacement failure")
    } catch AuthStorageError.keychainDeleteFailed {
      // Projection is never called after authority persistence fails.
    }

    #expect(fixture.cache.snapshot().status == .unauthenticated)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: fixture.namespace) == nil)
    #expect(try fixture.storedIDs().isEmpty)
  }

  @Test("post-projection finalization failure promotes recovery without restoring old authority")
  func postProjectionFinalizationFailurePromotesRecovery() async throws {
    let fixture = try Fixture()
    defer { fixture.reset() }
    let attempt = try await fixture.auth.beginLoginAttempt()

    do {
      _ = try await LoginStatePreparation.commitUsing(
        auth: fixture.auth,
        loginAttempt: attempt,
        targetUserID: 42,
        persistCredentials: {
          try await fixture.store.saveCredentials(
            token: "42:recovery",
            userId: 42,
            loginAttempt: attempt
          )
        },
        writeProjection: { db in
          try db.execute(sql: "INSERT INTO account_projection (id) VALUES (42)")
        },
        prepareDatabase: fixture.prepare,
        commitProjection: fixture.project,
        afterProjectionCommit: {
          _ = fixture.cache.beginLogout(correlationID: attempt.correlationID)
        }
      )
      Issue.record("Expected the logout fence to reject final auth publication")
    } catch AuthStorageError.logoutInProgress {
      // Platform recovery now owns the committed DB and staged authority together.
    }

    #expect(try fixture.storedIDs() == [42])
    #expect(AuthKeychainConfig.mockGetString("token", namespace: fixture.namespace) == "42:recovery")
    #expect(fixture.cache.snapshot().status == .loggingOut(userIdHint: 42))
    #expect(fixture.store.hasPendingLogout())
    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: fixture.namespace)
    #expect(UserDefaults.standard.object(forKey: "\(prefix)logoutPending") != nil)
    #expect(UserDefaults.standard.object(forKey: "\(prefix)logoutAttemptID") != nil)
  }

  @Test("failed logout persistence after projection retains the new pair for restart recovery")
  func failedLogoutFenceAfterProjectionPromotesRestartRecovery() async throws {
    let fixture = try Fixture(logoutFencePersistenceOverride: { _ in false })
    defer { fixture.reset() }
    let attempt = try await fixture.auth.beginLoginAttempt()

    do {
      _ = try await LoginStatePreparation.commitUsing(
        auth: fixture.auth,
        loginAttempt: attempt,
        targetUserID: 42,
        persistCredentials: {
          try await fixture.store.saveCredentials(
            token: "42:restart-recovery",
            userId: 42,
            loginAttempt: attempt
          )
        },
        writeProjection: { db in
          try db.execute(sql: "INSERT INTO account_projection (id) VALUES (42)")
        },
        prepareDatabase: fixture.prepare,
        commitProjection: fixture.project,
        afterProjectionCommit: {
          _ = try? fixture.store.beginLogoutSynchronously()
        }
      )
      Issue.record("Expected failed logout persistence to invalidate final publication")
    } catch AuthStorageError.loginSuperseded {
      // The committed pair remains fenced for recovery instead of restoring old authority.
    } catch AuthStorageError.loginUnavailable {
      // Either fence error is fail-closed; the durable login marker drives launch recovery.
    }

    #expect(try fixture.storedIDs() == [42])
    #expect(
      AuthKeychainConfig.mockGetString("token", namespace: fixture.namespace)
        == "42:restart-recovery"
    )
    #expect(fixture.cache.snapshot().status == .loggingOut(userIdHint: 42))
    #expect(fixture.cache.hasPendingAccountTransition())

    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: true, namespace: fixture.namespace)
    #expect(UserDefaults.standard.object(forKey: "\(prefix)loginCommitPendingAttemptID") != nil)
    let restartCache = AuthSnapshotCache(
      initial: AuthSnapshot(status: .hydrating, didHydrate: false)
    )
    let restartStore = AuthStore(cache: restartCache, mocked: true, namespace: fixture.namespace)
    #expect(restartStore.hasPendingLogout())
    #expect(restartCache.snapshot().status == .loggingOut(userIdHint: 42))
  }

  @Test("same-user V2 to V3 failure preserves bearer authority and existing projection")
  func sameUserUpgradeFailurePreservesExistingAccount() async throws {
    let fixture = try Fixture(
      authorityReplacementDeletionOverride: { label in label == "bearer" ? false : nil }
    )
    defer { fixture.reset() }
    try await fixture.store.saveCredentials(token: "7:bearer", userId: 7)
    try await fixture.database.write { db in
      try db.execute(sql: "DELETE FROM account_projection")
      try db.execute(sql: "INSERT INTO account_projection (id) VALUES (7)")
    }
    let attempt = try await fixture.auth.beginLoginAttempt(allowAuthenticated: true)

    do {
      _ = try await LoginStatePreparation.commitUsing(
        auth: fixture.auth,
        loginAttempt: attempt,
        targetUserID: 7,
        existingAuthenticatedUserID: 7,
        persistCredentials: {
          try await fixture.store.saveInlineProtocolCredentials(
            try v3Credentials(userID: 7),
            loginAttempt: attempt
          )
        },
        writeProjection: { _ in () },
        prepareDatabase: { _, _ in
          Issue.record("Same-user upgrade must not clear the existing database")
        },
        commitProjection: fixture.project
      )
      Issue.record("Expected V3 authority replacement failure")
    } catch AuthStorageError.keychainDeleteFailed {
      // Bearer authority and the old projection remain intact.
    }

    #expect(fixture.cache.snapshot().token == "7:bearer")
    #expect(try fixture.storedIDs() == [7])
    #expect(AuthKeychainConfig.mockGetData("inline_protocol_credentials_v1", namespace: fixture.namespace) == nil)
  }

  @Test("same-account upgrade rejects a different completion user before clear or authority write")
  func sameUserUpgradeRejectsDifferentUser() async throws {
    let fixture = try Fixture()
    defer { fixture.reset() }
    try await fixture.store.saveCredentials(token: "7:bearer", userId: 7)
    let attempt = try await fixture.auth.beginLoginAttempt(allowAuthenticated: true)

    do {
      _ = try await LoginStatePreparation.commitUsing(
        auth: fixture.auth,
        loginAttempt: attempt,
        targetUserID: 8,
        existingAuthenticatedUserID: 7,
        persistCredentials: {
          Issue.record("Different-user upgrade must not write authority")
        },
        writeProjection: { _ in () },
        prepareDatabase: { _, _ in
          Issue.record("Different-user upgrade must not clear the database")
        },
        commitProjection: fixture.project
      )
      Issue.record("Expected account mismatch")
    } catch LoginStatePreparationError.authenticatedAccountMismatch {
      // A real logout is required for account replacement.
    }

    #expect(fixture.cache.snapshot().token == "7:bearer")
    #expect(try fixture.storedIDs() == [1])
  }
}
