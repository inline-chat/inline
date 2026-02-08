import Foundation
import InlineConfig
import KeychainSwift
import Logger

actor AuthStore: Sendable {
  private let log = Log.scoped("AuthStore")

  private static let legacyTokenKey = "token"
  private static let credentialsV2Key = "credentials_v2"

  private let primaryKeychain: KeychainSwift
  private let fallbackKeychain: KeychainSwift?
  private let userDefaultsKey: String
  private let readSnapshot: (KeychainSwift, KeychainSwift?, String) -> AuthSnapshot

  private let cache: AuthSnapshotCache

  nonisolated let snapshots: AsyncStream<AuthSnapshot>
  private let snapshotsContinuation: AsyncStream<AuthSnapshot>.Continuation

  nonisolated let events: AsyncStream<AuthEvent>
  private let eventsContinuation: AsyncStream<AuthEvent>.Continuation

  private var lastStatus: AuthStatus
  private var lockedRetryTask: Task<Void, Never>?

  init(
    cache: AuthSnapshotCache,
    mocked: Bool,
    namespace: String? = nil,
    readSnapshot: ((KeychainSwift, KeychainSwift?, String) -> AuthSnapshot)? = nil
  ) {
    self.cache = cache
    primaryKeychain = AuthKeychainConfig.makePrimaryKeychain(mocked: mocked, namespace: namespace)
    fallbackKeychain = AuthKeychainConfig.makeFallbackKeychainIfNeeded(mocked: mocked, namespace: namespace)

    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: mocked, namespace: namespace)
    userDefaultsKey = "\(prefix)userId"
    self.readSnapshot = readSnapshot ?? Self.readSnapshot

    var snapshotsContinuation: AsyncStream<AuthSnapshot>.Continuation!
    snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { snapshotsContinuation = $0 }
    self.snapshotsContinuation = snapshotsContinuation

    var eventsContinuation: AsyncStream<AuthEvent>.Continuation!
    events = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { eventsContinuation = $0 }
    self.eventsContinuation = eventsContinuation

    // Seed from storage immediately so sync callers (DB init) see the best answer we have.
    let initial = self.readSnapshot(primaryKeychain, fallbackKeychain, userDefaultsKey)
    cache.update(initial)
    lastStatus = initial.status

    snapshotsContinuation.yield(initial)

    if let fallback = fallbackKeychain {
      // Migrate legacy macOS keychain items (no access-group) to the primary access group.
      Self.migrateKeyIfFoundInFallback(Self.legacyTokenKey, primary: primaryKeychain, fallback: fallback)
      Self.migrateKeyIfFoundInFallback(Self.credentialsV2Key, primary: primaryKeychain, fallback: fallback)
    }

    if case .locked = initial.status {
      Task { [weak self] in
        await self?.startLockedRetryLoopIfNeeded()
      }
    }
  }

  // MARK: - Public API

  func saveCredentials(token: String, userId: Int64) async {
    // Persist legacy token for backward compatibility with older builds.
    let legacySavedPrimary = primaryKeychain.set(
      token,
      forKey: Self.legacyTokenKey,
      withAccess: .accessibleAfterFirstUnlock
    )
    let legacyPrimaryStatus = primaryKeychain.lastResultCode

    // Persist v2 record (token + userId together).
    let record = AuthCredentials(userId: userId, token: token)
    let encodedRecord: Data? = {
      do {
        return try JSONEncoder().encode(record)
      } catch {
        log.error("AUTH2 encode credentials failed", error: error)
        return nil
      }
    }()

    var v2SavedPrimary = false
    var v2PrimaryStatus = errSecSuccess
    if let encodedRecord {
      v2SavedPrimary = primaryKeychain.set(
        encodedRecord,
        forKey: Self.credentialsV2Key,
        withAccess: .accessibleAfterFirstUnlock
      )
      v2PrimaryStatus = primaryKeychain.lastResultCode
    }

    // Best-effort macOS fallback write if the primary access-group isn't working.
    var legacySavedFallback = false
    var legacyFallbackStatus = errSecSuccess
    var v2SavedFallback = false
    var v2FallbackStatus = errSecSuccess
    if let fallbackKeychain {
      if legacySavedPrimary == false {
        legacySavedFallback = fallbackKeychain.set(
          token,
          forKey: Self.legacyTokenKey,
          withAccess: .accessibleAfterFirstUnlock
        )
        legacyFallbackStatus = fallbackKeychain.lastResultCode
      }
      if v2SavedPrimary == false, let encodedRecord {
        v2SavedFallback = fallbackKeychain.set(
          encodedRecord,
          forKey: Self.credentialsV2Key,
          withAccess: .accessibleAfterFirstUnlock
        )
        v2FallbackStatus = fallbackKeychain.lastResultCode
      }
    }

    let legacySaved = legacySavedPrimary || legacySavedFallback
    let v2Saved = v2SavedPrimary || v2SavedFallback

    // Persist userId hint for routing + recovery.
    UserDefaults.standard.set(NSNumber(value: userId), forKey: userDefaultsKey)

    log.info(
      "AUTH2_SAVE userId=\(userId)" +
        " legacySaved=\(legacySaved ? 1 : 0) v2Saved=\(v2Saved ? 1 : 0)" +
        " legacyPrimary=\(legacySavedPrimary ? 1 : 0) legacyPrimaryStatus=\(legacyPrimaryStatus)" +
        " v2Primary=\(v2SavedPrimary ? 1 : 0) v2PrimaryStatus=\(v2PrimaryStatus)" +
        " legacyFallback=\(legacySavedFallback ? 1 : 0) legacyFallbackStatus=\(legacyFallbackStatus)" +
        " v2Fallback=\(v2SavedFallback ? 1 : 0) v2FallbackStatus=\(v2FallbackStatus)"
    )

    let snapshot = AuthSnapshot(status: .authenticated(record), didHydrate: true)
    await update(snapshot)
  }

  func logOut() async {
    _ = primaryKeychain.delete(Self.legacyTokenKey)
    _ = primaryKeychain.delete(Self.credentialsV2Key)
    if let fallbackKeychain {
      _ = fallbackKeychain.delete(Self.legacyTokenKey)
      _ = fallbackKeychain.delete(Self.credentialsV2Key)
    }
    UserDefaults.standard.removeObject(forKey: userDefaultsKey)

    log.info("AUTH2_LOGOUT")

    let snapshot = AuthSnapshot(status: .unauthenticated, didHydrate: true)
    await update(snapshot)
  }

  func refreshFromStorage() async {
    let snapshot = readSnapshot(primaryKeychain, fallbackKeychain, userDefaultsKey)

    // If we already have usable in-memory credentials, a transient keychain lock should not downgrade state.
    if lastStatus.isAuthenticated {
      if case .locked = snapshot.status {
        log.warning("AUTH2_REFRESH returned locked while already authenticated; keeping in-memory snapshot")
        return
      }
    }

    // If we recovered via macOS fallback keychain, re-save into primary access group.
    if case let .authenticated(creds) = snapshot.status {
      let legacySavedPrimary = primaryKeychain.set(
        creds.token,
        forKey: Self.legacyTokenKey,
        withAccess: .accessibleAfterFirstUnlock
      )
      let legacyPrimaryStatus = primaryKeychain.lastResultCode

      var v2SavedPrimary = false
      var v2PrimaryStatus = errSecSuccess
      do {
        let data = try JSONEncoder().encode(creds)
        v2SavedPrimary = primaryKeychain.set(
          data,
          forKey: Self.credentialsV2Key,
          withAccess: .accessibleAfterFirstUnlock
        )
        v2PrimaryStatus = primaryKeychain.lastResultCode
      } catch {
        log.error("AUTH2 encode credentials failed during refresh", error: error)
      }
      if let fallbackKeychain {
        // Only delete legacy items from the fallback if we successfully persisted them to primary.
        if legacySavedPrimary {
          _ = fallbackKeychain.delete(Self.legacyTokenKey)
        }
        if v2SavedPrimary {
          _ = fallbackKeychain.delete(Self.credentialsV2Key)
        }

        if legacySavedPrimary == false || v2SavedPrimary == false {
          log.warning(
            "AUTH2 refresh could not migrate credentials to primary; keeping fallback " +
              "legacySavedPrimary=\(legacySavedPrimary ? 1 : 0) legacyPrimaryStatus=\(legacyPrimaryStatus) " +
              "v2SavedPrimary=\(v2SavedPrimary ? 1 : 0) v2PrimaryStatus=\(v2PrimaryStatus)"
          )
        }
      }
      UserDefaults.standard.set(NSNumber(value: creds.userId), forKey: userDefaultsKey)
    }

    await update(snapshot)
  }

  // MARK: - Internals

  private func update(_ snapshot: AuthSnapshot) async {
    let prev = lastStatus
    lastStatus = snapshot.status
    cache.update(snapshot)
    snapshotsContinuation.yield(snapshot)
    updateLockedRetryLoop(for: snapshot.status)

    switch (prev.isAuthenticated, snapshot.status.isAuthenticated) {
    case (false, true):
      if case let .authenticated(creds) = snapshot.status {
        eventsContinuation.yield(.login(userId: creds.userId, token: creds.token))
      }
    case (true, false):
      eventsContinuation.yield(.logout)
    default:
      break
    }
  }

  private func updateLockedRetryLoop(for status: AuthStatus) {
    if case .locked = status {
      startLockedRetryLoopIfNeeded()
    } else {
      stopLockedRetryLoop()
    }
  }

  private func startLockedRetryLoopIfNeeded() {
    guard lockedRetryTask == nil else { return }
    lockedRetryTask = Task { [weak self] in
      await self?.runLockedRetryLoop()
    }
  }

  private func stopLockedRetryLoop() {
    lockedRetryTask?.cancel()
    lockedRetryTask = nil
  }

  private func runLockedRetryLoop() async {
    defer { lockedRetryTask = nil }

    // Exponential backoff: 0.3s -> 0.6s -> 1.2s -> ... up to 5s, and cap attempts.
    var delayNs: UInt64 = 300_000_000
    let maxDelayNs: UInt64 = 5_000_000_000
    let maxAttempts = 30

    for _ in 0..<maxAttempts {
      guard !Task.isCancelled else { return }

      try? await Task.sleep(nanoseconds: delayNs)
      await refreshFromStorage()

      if case .locked = lastStatus {
        delayNs = min(delayNs * 2, maxDelayNs)
        continue
      }

      return
    }

    log.warning("AUTH2 keychain remained locked after retry loop; waiting for external refresh trigger")
  }

  private static func migrateKeyIfFoundInFallback(_ key: String, primary: KeychainSwift, fallback: KeychainSwift) {
    // Already present in primary.
    if primary.getData(key) != nil {
      return
    }
    if primary.lastResultCode != errSecItemNotFound {
      // Keychain locked or other error; skip migration.
      return
    }

    if let data = fallback.getData(key) {
      if primary.set(data, forKey: key, withAccess: .accessibleAfterFirstUnlock) {
        _ = fallback.delete(key)
      }
    }
  }

  private static func readSnapshot(
    primaryKeychain: KeychainSwift,
    fallbackKeychain: KeychainSwift?,
    userDefaultsKey: String
  ) -> AuthSnapshot {
    let userIdHint = readUserId(key: userDefaultsKey)

    // 1) Try v2 record first.
    switch AuthKeychainConfig.readData(credentialsV2Key, primary: primaryKeychain, fallback: fallbackKeychain) {
    case .success(let data, _):
      if let creds = try? JSONDecoder().decode(AuthCredentials.self, from: data) {
        return AuthSnapshot(status: .authenticated(creds), didHydrate: true)
      }
      // Corrupt record; fall back to legacy pieces.

    case .interactionNotAllowed:
      // Keychain is currently unavailable (e.g. iOS before first unlock).
      return AuthSnapshot(status: .locked(userIdHint: userIdHint), didHydrate: true)

    case .notFound, .error:
      break
    }

    // 2) Legacy token + userId hint.
    let tokenOutcome = AuthKeychainConfig.readString(legacyTokenKey, primary: primaryKeychain, fallback: fallbackKeychain)

    let token: String? = switch tokenOutcome {
    case .success(let token, _): token
    case .notFound, .interactionNotAllowed, .error: nil
    }

    var userId = userIdHint
    if userId == nil, let token {
      userId = parseUserId(fromToken: token)
      if let userId {
        UserDefaults.standard.set(NSNumber(value: userId), forKey: userDefaultsKey)
      }
    }

    if let token, let userId {
      return AuthSnapshot(status: .authenticated(AuthCredentials(userId: userId, token: token)), didHydrate: true)
    }

    if userId != nil, token == nil {
      switch tokenOutcome {
      case .interactionNotAllowed:
        return AuthSnapshot(status: .locked(userIdHint: userId), didHydrate: true)
      case .notFound:
        return AuthSnapshot(status: .reauthRequired(userIdHint: userId), didHydrate: true)
      case .error:
        // Treat "unexpected" keychain errors as a temporary locked/unavailable state to avoid
        // destructive downstream behaviors (DB resets, forced logout).
        return AuthSnapshot(status: .locked(userIdHint: userId), didHydrate: true)
      case .success:
        // Unreachable since `token` is non-nil for `.success`.
        return AuthSnapshot(status: .reauthRequired(userIdHint: userId), didHydrate: true)
      }
    }

    if token == nil {
      if case .interactionNotAllowed = tokenOutcome {
        return AuthSnapshot(status: .locked(userIdHint: userIdHint), didHydrate: true)
      }
    }

    return AuthSnapshot(status: .unauthenticated, didHydrate: true)
  }

  private static func readUserId(key: String) -> Int64? {
    guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else {
      return nil
    }
    return number.int64Value
  }

  private static func parseUserId(fromToken token: String) -> Int64? {
    // Tokens currently look like "<userId>:<opaque>" in multiple call sites/tests.
    // Treat this as best-effort recovery; do not rely on it for security decisions.
    guard let prefix = token.split(separator: ":", maxSplits: 1).first else { return nil }
    return Int64(prefix)
  }
}
