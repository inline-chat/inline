import Foundation
import InlineConfig
import Logger

private struct VersionedAuthSnapshot: Sendable {
  let revision: UInt64
  let snapshot: AuthSnapshot
}

/// A current-value broadcast stream whose subscription boundary is `stream()` itself.
/// Registration and replay share the publication lock so a subscriber cannot miss or reorder
/// a snapshot while its observer task is still waiting to run.
private final class AuthSnapshotPipe: @unchecked Sendable {
  private let lock = NSLock()
  private var latest: VersionedAuthSnapshot?
  private var continuations: [UUID: AsyncStream<AuthSnapshot>.Continuation] = [:]

  func stream() -> AsyncStream<AuthSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: AuthSnapshot.self,
      bufferingPolicy: .unbounded
    )
    continuation.onTermination = { [weak self] _ in
      self?.removeContinuation(id: id)
    }

    lock.withLock {
      continuations[id] = continuation
      if let latest {
        continuation.yield(latest.snapshot)
      }
    }
    return stream
  }

  @discardableResult
  func yield(_ snapshot: AuthSnapshot) -> UInt64? {
    lock.withLock {
      guard latest?.snapshot != snapshot else { return nil }

      let versionedSnapshot = VersionedAuthSnapshot(
        revision: (latest?.revision ?? 0) &+ 1,
        snapshot: snapshot
      )
      latest = versionedSnapshot
      for continuation in continuations.values {
        continuation.yield(versionedSnapshot.snapshot)
      }
      return versionedSnapshot.revision
    }
  }

  private func removeContinuation(id: UUID) {
    _ = lock.withLock {
      continuations.removeValue(forKey: id)
    }
  }
}

private final class BufferedAsyncStreamBroadcaster<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
  private let idleReplayLimit: Int
  private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
  private var elementsWhileIdle: [Element] = []

  init(
    bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy,
    idleReplayLimit: Int = 0
  ) {
    self.bufferingPolicy = bufferingPolicy
    self.idleReplayLimit = idleReplayLimit
  }

  func stream() -> AsyncStream<Element> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: Element.self,
      bufferingPolicy: bufferingPolicy
    )
    continuation.onTermination = { [weak self] _ in
      self?.removeContinuation(id: id)
    }

    lock.withLock {
      continuations[id] = continuation
      for element in elementsWhileIdle {
        continuation.yield(element)
      }
      elementsWhileIdle.removeAll(keepingCapacity: true)
    }
    return stream
  }

  func yield(_ element: Element) {
    let currentContinuations = lock.withLock {
      if continuations.isEmpty, idleReplayLimit > 0 {
        elementsWhileIdle.append(element)
        if elementsWhileIdle.count > idleReplayLimit {
          elementsWhileIdle.removeFirst(elementsWhileIdle.count - idleReplayLimit)
        }
      }
      return Array(continuations.values)
    }
    for continuation in currentContinuations {
      continuation.yield(element)
    }
  }

  private func removeContinuation(id: UUID) {
    _ = lock.withLock {
      continuations.removeValue(forKey: id)
    }
  }
}

private struct StoredAuthorityBackup {
  var primary: [String: Data]
  var fallback: [String: Data]
  var mocked: [String: Data]
  var userIDHint: Int64?
}

actor AuthStore {
  private let log = Log.scoped("AuthStore")

  private static let legacyTokenKey = "token"
  private static let credentialsV2Key = "credentials_v2"
  private static let inlineProtocolCredentialsKey = "inline_protocol_credentials_v1"

  private let primaryKeychain: KeychainStore
  private let fallbackKeychain: KeychainStore?
  private let userDefaultsKey: String
  private nonisolated let logoutPendingKey: String
  private nonisolated let logoutAttemptIDKey: String
  private nonisolated let loginCommitPendingKey: String
  private let readSnapshot: (KeychainStore, KeychainStore?, String) -> AuthSnapshot
  private let credentialDeletionOverride: (@Sendable () -> Bool)?
  private let authorityReplacementDeletionOverride: (@Sendable (String) -> Bool?)?
  private let authorityRestoreOverride: (@Sendable () -> Bool)?
  private let logoutFencePersistenceOverride: (@Sendable (UUID) -> Bool)?
  private let credentialWriteInterleavingHook: (@Sendable () -> Void)?
  private let authorityFinalizationInterleavingHook: (@Sendable () -> Void)?
  private let mocked: Bool
  private let namespace: String?
  private nonisolated let logoutMarkerLock = NSLock()

  private nonisolated let cache: AuthSnapshotCache

  private nonisolated let snapshotPipe = AuthSnapshotPipe()
  private nonisolated let eventBroadcaster = BufferedAsyncStreamBroadcaster<AuthEvent>(
    bufferingPolicy: .unbounded,
    idleReplayLimit: 8
  )

  private var lastStatus: AuthStatus
  private var lockedRetryTask: Task<Void, Never>?
  private var stagedAuthorityBaseline: StoredAuthorityBackup?

  init(
    cache: AuthSnapshotCache,
    mocked: Bool,
    namespace: String? = nil,
    readSnapshot: ((KeychainStore, KeychainStore?, String) -> AuthSnapshot)? = nil,
    credentialDeletionOverride: (@Sendable () -> Bool)? = nil,
    authorityReplacementDeletionOverride: (@Sendable (String) -> Bool?)? = nil,
    authorityRestoreOverride: (@Sendable () -> Bool)? = nil,
    logoutFencePersistenceOverride: (@Sendable (UUID) -> Bool)? = nil,
    credentialWriteInterleavingHook: (@Sendable () -> Void)? = nil,
    authorityFinalizationInterleavingHook: (@Sendable () -> Void)? = nil
  ) {
    self.cache = cache
    self.mocked = mocked
    self.namespace = namespace
    primaryKeychain = AuthKeychainConfig.makePrimaryKeychain(mocked: mocked, namespace: namespace)
    fallbackKeychain = AuthKeychainConfig.makeFallbackKeychainIfNeeded(mocked: mocked, namespace: namespace)

    let prefix = AuthKeychainConfig.userDefaultsPrefix(mocked: mocked, namespace: namespace)
    let resolvedUserDefaultsKey = "\(prefix)userId"
    let resolvedLogoutPendingKey = "\(prefix)logoutPending"
    let resolvedLogoutAttemptIDKey = "\(prefix)logoutAttemptID"
    let resolvedLoginCommitPendingKey = "\(prefix)loginCommitPendingAttemptID"
    userDefaultsKey = resolvedUserDefaultsKey
    logoutPendingKey = resolvedLogoutPendingKey
    logoutAttemptIDKey = resolvedLogoutAttemptIDKey
    loginCommitPendingKey = resolvedLoginCommitPendingKey
    self.credentialDeletionOverride = credentialDeletionOverride
    self.authorityReplacementDeletionOverride = authorityReplacementDeletionOverride
    self.authorityRestoreOverride = authorityRestoreOverride
    self.logoutFencePersistenceOverride = logoutFencePersistenceOverride
    self.credentialWriteInterleavingHook = credentialWriteInterleavingHook
    self.authorityFinalizationInterleavingHook = authorityFinalizationInterleavingHook
    let snapshotReader = readSnapshot ?? { primaryKeychain, fallbackKeychain, userDefaultsKey in
      Self.readSnapshot(
        primaryKeychain: primaryKeychain,
        fallbackKeychain: fallbackKeychain,
        userDefaultsKey: userDefaultsKey,
        mocked: mocked,
        namespace: namespace
      )
    }
    self.readSnapshot = snapshotReader

    // Seed from storage immediately so sync callers (DB init) see the best answer we have.
    let loginCommitMarkerPresent = UserDefaults.standard.object(forKey: resolvedLoginCommitPendingKey) != nil
    let logoutMarkerPresent = UserDefaults.standard.object(forKey: resolvedLogoutPendingKey) != nil
    let logoutAttemptMarkerPresent = UserDefaults.standard.object(forKey: resolvedLogoutAttemptIDKey) != nil
    let loginCommitPendingID = UserDefaults.standard.string(forKey: resolvedLoginCommitPendingKey)
      .flatMap(UUID.init(uuidString:))
    let storedLogoutAttemptID = UserDefaults.standard.string(forKey: resolvedLogoutAttemptIDKey)
      .flatMap(UUID.init(uuidString:))
    let recoveredTransitionID = storedLogoutAttemptID ?? loginCommitPendingID ?? UUID()
    let effectiveLogoutPending = logoutMarkerPresent || logoutAttemptMarkerPresent || loginCommitMarkerPresent
    if effectiveLogoutPending {
      // A partial/corrupt logout marker or a crash during staged login cannot safely reconstruct
      // authority. Promote every marker presence to the same platform-owned recovery transition.
      UserDefaults.standard.set(recoveredTransitionID.uuidString, forKey: resolvedLogoutAttemptIDKey)
      UserDefaults.standard.set(true, forKey: resolvedLogoutPendingKey)
      _ = UserDefaults.standard.synchronize()
    }
    let initial = effectiveLogoutPending
      ? AuthSnapshot(
        status: .loggingOut(userIdHint: Self.readUserId(key: resolvedUserDefaultsKey)),
        didHydrate: true
      )
      : snapshotReader(primaryKeychain, fallbackKeychain, resolvedUserDefaultsKey)
    lastStatus = initial.status

    cache.seedLoginCommitPending(loginCommitMarkerPresent)
    cache.seedLogoutPending(effectiveLogoutPending, correlationID: recoveredTransitionID)
    if effectiveLogoutPending, storedLogoutAttemptID == nil,
      let recoveredFence = cache.currentLogoutFence()
    {
      UserDefaults.standard.set(recoveredFence.correlationID.uuidString, forKey: resolvedLogoutAttemptIDKey)
    }
    cache.update(initial)

    snapshotPipe.yield(initial)

    if case .locked = initial.status {
      Task { [weak self] in
        await self?.startLockedRetryLoopIfNeeded()
      }
    }
  }

  // MARK: - Public API

  /// Current auth state followed by future changes. Calling this method synchronously registers
  /// an independent subscriber and buffers changes until that stream begins iteration.
  nonisolated func snapshots() -> AsyncStream<AuthSnapshot> {
    snapshotPipe.stream()
  }

  /// Compatibility lifecycle events for authenticated-state transitions.
  /// Every subscriber receives an independent sequence; initial state is not synthesized.
  nonisolated func events() -> AsyncStream<AuthEvent> {
    eventBroadcaster.stream()
  }

  func saveCredentials(
    token: String,
    userId: Int64,
    loginAttempt: AuthLoginAttempt? = nil
  ) async throws {
    if let loginAttempt {
      try validateLoginAttempt(loginAttempt)
    }
    guard !hasPendingLogout() else {
      log.warning("AUTH2_SAVE rejected while logout cleanup is pending")
      throw AuthStorageError.logoutInProgress
    }

    let record = AuthCredentials(userId: userId, token: token)
    guard record.hasConsistentIdentity else { throw AuthStorageError.encodingFailed }
    let encodedRecord: Data
    do {
      encodedRecord = try JSONEncoder().encode(record)
    } catch {
      log.error("AUTH2 encode credentials failed", error: error)
      throw AuthStorageError.encodingFailed
    }

    let snapshot = AuthSnapshot(
      status: .authenticated(record),
      didHydrate: true
    )
    try persistCredentialAuthority(snapshot: snapshot, loginAttempt: loginAttempt) {
      try self.replaceStoredAuthority(
        with: [
          Self.legacyTokenKey: Data(token.utf8),
          Self.credentialsV2Key: encodedRecord,
        ],
        replacing: [Self.inlineProtocolCredentialsKey],
        replacementLabel: "inline_protocol"
      )
    }
    log.info("AUTH2_SAVE bearer authority persisted staged=\(loginAttempt == nil ? 0 : 1)")
  }

  func saveInlineProtocolCredentials(
    _ credentials: InlineProtocolSessionCredentials,
    loginAttempt: AuthLoginAttempt? = nil
  ) async throws {
    if let loginAttempt {
      try validateLoginAttempt(loginAttempt)
    }
    guard !hasPendingLogout() else {
      throw AuthStorageError.logoutInProgress
    }

    let data: Data
    do {
      try credentials.validate()
      data = try JSONEncoder().encode(credentials)
    } catch {
      throw AuthStorageError.encodingFailed
    }
    let snapshot = AuthSnapshot(
      status: .authenticatedV3(userId: credentials.userId),
      didHydrate: true,
      inlineProtocol: credentials
    )
    try persistCredentialAuthority(snapshot: snapshot, loginAttempt: loginAttempt) {
      try self.replaceStoredAuthority(
        with: [Self.inlineProtocolCredentialsKey: data],
        replacing: [Self.legacyTokenKey, Self.credentialsV2Key],
        replacementLabel: "bearer"
      )
    }
    log.info("AUTH2_SAVE inline protocol authority persisted staged=\(loginAttempt == nil ? 0 : 1)")
  }

  nonisolated func beginLogoutSynchronously() throws -> AuthLogoutFence {
    let storedID = UserDefaults.standard.string(forKey: logoutAttemptIDKey)
      .flatMap(UUID.init(uuidString:))
    let fence = cache.beginLogout(correlationID: storedID ?? UUID())
    do {
      try logoutMarkerLock.withLock {
        // Completion may have won after this caller observed an existing fence. Never recreate a
        // durable marker for a fence that is no longer the in-memory authority.
        guard cache.isLogoutFenceCurrent(fence) else {
          throw AuthStorageError.logoutFencePersistenceFailed
        }
        if let logoutFencePersistenceOverride,
           logoutFencePersistenceOverride(fence.correlationID) == false
        {
          throw AuthStorageError.logoutFencePersistenceFailed
        }
        UserDefaults.standard.set(fence.correlationID.uuidString, forKey: logoutAttemptIDKey)
        UserDefaults.standard.set(true, forKey: logoutPendingKey)
        guard UserDefaults.standard.synchronize(),
              UserDefaults.standard.bool(forKey: logoutPendingKey),
              UserDefaults.standard.string(forKey: logoutAttemptIDKey) == fence.correlationID.uuidString
        else { throw AuthStorageError.logoutFencePersistenceFailed }
      }
      return fence
    } catch {
      let durableMarkerIsAbsent = UserDefaults.standard.object(forKey: logoutPendingKey) == nil
        && UserDefaults.standard.object(forKey: logoutAttemptIDKey) == nil
      let aborted = cache.abortUnpersistedLogoutFence(
        durableMarkerIsAbsent: durableMarkerIsAbsent
      )
      if aborted {
        UserDefaults.standard.removeObject(forKey: logoutAttemptIDKey)
        _ = UserDefaults.standard.synchronize()
      }
      throw error
    }
  }

  func beginLogout() throws -> AuthLogoutFence {
    try beginLogoutSynchronously()
  }

  func publishLogoutInProgress() async {
    let userIdHint = cache.snapshot().currentUserId ?? Self.readUserId(key: userDefaultsKey)
    await update(AuthSnapshot(
      status: .loggingOut(userIdHint: userIdHint),
      didHydrate: true
    ))
  }

  nonisolated func hasPendingLogout() -> Bool {
    let durablePending = UserDefaults.standard.object(forKey: logoutPendingKey) != nil
      || UserDefaults.standard.object(forKey: logoutAttemptIDKey) != nil
    if durablePending, cache.hasPendingLogout() == false {
      let storedID = UserDefaults.standard.string(forKey: logoutAttemptIDKey)
        .flatMap(UUID.init(uuidString:))
      cache.seedLogoutPending(true, correlationID: storedID)
    }
    return durablePending || cache.hasPendingLogout()
  }

  nonisolated func currentLogoutFence() -> AuthLogoutFence? {
    cache.currentLogoutFence()
  }

  nonisolated func hasPendingAccountTransition() -> Bool {
    hasPendingLogout() || cache.hasPendingAccountTransition()
  }

  func requireLoginAllowed() throws {
    guard !hasPendingLogout() else {
      throw AuthStorageError.logoutInProgress
    }
    guard cache.hasPendingLoginCommit() == false else {
      throw AuthStorageError.loginUnavailable
    }
    switch lastStatus {
    case .unauthenticated, .reauthRequired:
      return
    case .loggingOut:
      throw AuthStorageError.logoutInProgress
    case .hydrating, .locked:
      throw AuthStorageError.loginUnavailable
    case .authenticated, .authenticatedV3:
      throw AuthStorageError.alreadyAuthenticated
    }
  }

  func beginLoginAttempt(allowAuthenticated: Bool) throws -> AuthLoginAttempt {
    guard !hasPendingLogout(), !cache.hasPendingLogout() else {
      throw AuthStorageError.logoutInProgress
    }
    guard cache.hasPendingLoginCommit() == false else {
      throw AuthStorageError.loginUnavailable
    }
    switch lastStatus {
    case .unauthenticated, .reauthRequired:
      return cache.makeLoginAttempt()
    case .loggingOut:
      throw AuthStorageError.logoutInProgress
    case .hydrating, .locked:
      throw AuthStorageError.loginUnavailable
    case .authenticated, .authenticatedV3:
      guard allowAuthenticated else {
        throw AuthStorageError.alreadyAuthenticated
      }
      return cache.makeLoginAttempt()
    }
  }

  func validateLoginAttempt(_ attempt: AuthLoginAttempt) throws {
    guard cache.isLoginAttemptCurrent(attempt) else {
      if hasPendingLogout() || cache.hasPendingLogout() {
        throw AuthStorageError.logoutInProgress
      }
      throw AuthStorageError.loginSuperseded
    }
  }

  func destroyCredentialsForPendingLogout(
    fence: AuthLogoutFence
  ) async -> AuthCredentialDestructionProof? {
    guard hasPendingLogout(), cache.isLogoutFenceCurrent(fence) else {
      log.error("AUTH2_LOGOUT rejected credential destruction for a stale logout fence")
      return nil
    }
    if let credentialDeletionOverride, credentialDeletionOverride() == false {
      await preserveLogoutAfterCredentialDeletionFailure()
      return nil
    }
    let userIdHint = cache.snapshot().currentUserId ?? Self.readUserId(key: userDefaultsKey)
    guard deleteAllStoredAuthority() else {
      log.error(
        "AUTH2_LOGOUT credential deletion incomplete; retaining logout marker",
        error: AuthStorageError.keychainDeleteFailed
      )
      await preserveLogoutAfterCredentialDeletionFailure(userIdHint: userIdHint)
      return nil
    }
    log.info("AUTH2_LOGOUT credentials destroyed verified_absent=1")
    return cache.isLogoutFenceCurrent(fence)
      ? AuthCredentialDestructionProof(fence: fence)
      : nil
  }

  private func preserveLogoutAfterCredentialDeletionFailure(userIdHint: Int64? = nil) async {
    log.error(
      "AUTH2_LOGOUT credential deletion incomplete; retaining logout marker",
      error: AuthStorageError.keychainDeleteFailed
    )
    await update(AuthSnapshot(
      status: .loggingOut(
        userIdHint: userIdHint ?? cache.snapshot().currentUserId ?? Self.readUserId(key: userDefaultsKey)
      ),
      didHydrate: true
    ))
  }

  func finalizeCredentialsCommittedByLoginAttempt(
    _ attempt: AuthLoginAttempt
  ) throws -> AuthAccountMutationToken {
    guard cache.prepareStagedAuthorityFinalization(attempt) else {
      throw credentialCommitFenceError(for: attempt)
    }
    UserDefaults.standard.removeObject(forKey: loginCommitPendingKey)
    guard UserDefaults.standard.synchronize(),
          UserDefaults.standard.object(forKey: loginCommitPendingKey) == nil
    else { throw AuthStorageError.loginUnavailable }
    authorityFinalizationInterleavingHook?()
    let accountMutationToken = cache.finalizeStagedAuthority(
      attempt,
      publish: { snapshot in
        self.publishAuthenticatedSnapshot(snapshot)
      }
    )
    guard let accountMutationToken else { throw credentialCommitFenceError(for: attempt) }
    stagedAuthorityBaseline = nil
    updateLockedRetryLoop(for: cache.snapshot().status)
    return accountMutationToken
  }

  func rollbackCredentialsCommittedByLoginAttempt(_ attempt: AuthLoginAttempt) async {
    guard cache.isStagedAuthorityOwned(by: attempt), hasPendingLogout() == false,
          let baseline = stagedAuthorityBaseline
    else { return }
    do {
      try restoreStoredAuthority(baseline)
      UserDefaults.standard.removeObject(forKey: loginCommitPendingKey)
      guard UserDefaults.standard.synchronize(),
            UserDefaults.standard.object(forKey: loginCommitPendingKey) == nil
      else { throw AuthStorageError.loginUnavailable }
      let aborted = cache.abortAuthorityStaging(attempt)
      guard aborted else { return }
      stagedAuthorityBaseline = nil
      if let userID = cache.snapshot().currentUserId {
        UserDefaults.standard.set(NSNumber(value: userID), forKey: userDefaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
      }
    } catch {
      log.error(
        "AUTH2_LOGIN rollback failed; retaining pending login authority fence",
        error: error
      )
      promoteFailedLoginToRecovery(correlationID: attempt.correlationID)
    }
  }

  /// The minimum database projection is already committed, so restoring the previous credential
  /// authority would create a cross-account half-state. Retain the staged authority behind a
  /// durable recovery transition and let the platform logout owner clear both sides together.
  func promoteProjectedLoginToRecovery(_ attempt: AuthLoginAttempt) {
    guard cache.isStagedAuthorityOwned(by: attempt) || hasPendingLogout() else { return }
    promoteFailedLoginToRecovery(correlationID: attempt.correlationID)
  }

  func completePendingLogout(
    fence: AuthLogoutFence,
    databaseProof: AuthDatabaseCleanupProof,
    credentialProof: AuthCredentialDestructionProof,
    completionPermit: AuthLogoutCompletionPermit
  ) async -> Bool {
    guard databaseProof.fence == fence, credentialProof.fence == fence,
          completionPermit.fence == fence,
          hasPendingLogout(), cache.isLogoutFenceCurrent(fence)
    else {
      log.error("AUTH2_LOGOUT refused completion without matching cleanup proofs")
      return false
    }

    let snapshot = AuthSnapshot(status: .unauthenticated, didHydrate: true)
    let previousStatus = lastStatus
    let completed = logoutMarkerLock.withLock {
      guard cache.isLogoutFenceCurrent(fence) else { return false }
      UserDefaults.standard.removeObject(forKey: userDefaultsKey)
      UserDefaults.standard.removeObject(forKey: logoutPendingKey)
      UserDefaults.standard.removeObject(forKey: logoutAttemptIDKey)
      UserDefaults.standard.removeObject(forKey: loginCommitPendingKey)
      let markersRemoved = UserDefaults.standard.synchronize()
        && UserDefaults.standard.object(forKey: logoutPendingKey) == nil
        && UserDefaults.standard.object(forKey: logoutAttemptIDKey) == nil
        && UserDefaults.standard.object(forKey: loginCommitPendingKey) == nil
      let didComplete = markersRemoved && completionPermit.completeIfActive {
        cache.completeLogout(
          fence,
          snapshot: snapshot,
          publish: {
            self.lastStatus = snapshot.status
            _ = self.snapshotPipe.yield(snapshot)
            if previousStatus.isAuthenticated {
              self.eventBroadcaster.yield(.logout)
            }
          }
        )
      }
      if didComplete == false, cache.isLogoutFenceCurrent(fence) {
        // Deadline revocation, persistence failure, or a mismatched fence is fail-closed. Restore
        // the exact durable pair before another begin call can cross this marker transaction.
        UserDefaults.standard.set(fence.correlationID.uuidString, forKey: logoutAttemptIDKey)
        UserDefaults.standard.set(true, forKey: logoutPendingKey)
        _ = UserDefaults.standard.synchronize()
      }
      return didComplete
    }
    guard completed else {
      log.error(
        "AUTH2_LOGOUT refused completion or could not durably remove transition marker",
        error: AuthStorageError.logoutFencePersistenceFailed
      )
      return false
    }
    updateLockedRetryLoop(for: snapshot.status)
    stagedAuthorityBaseline = nil
    log.info("AUTH2_LOGOUT completed transition_id=\(fence.correlationID.uuidString)")
    return true
  }

  func refreshFromStorage() async {
    guard cache.hasPendingAccountTransition() == false else {
      log.warning("AUTH2_REFRESH skipped while an account transition is pending")
      return
    }
    let snapshot = readSnapshot(primaryKeychain, fallbackKeychain, userDefaultsKey)

    // If we already have usable in-memory credentials, a transient keychain lock should not downgrade state.
    if lastStatus.isAuthenticated {
      if case .locked = snapshot.status {
        log.warning("AUTH2_REFRESH returned locked while already authenticated; keeping in-memory snapshot")
        return
      }
    }

    // Refresh is deliberately read-only. Opportunistic keychain migration used to write old
    // fallback credentials after this read, which could resurrect authority across a concurrent
    // synchronous logout fence. Authority changes now happen only in the staged login/logout paths.
    await update(snapshot)
  }

  func repairUserIdHint() async {
    guard Self.readUserId(key: userDefaultsKey) == nil else { return }
    // Keep launch repair read-only for the same reason as refreshFromStorage. The in-memory
    // snapshot can derive its user ID from V2/V3 credentials without repopulating logout-owned
    // UserDefaults after the transition begins.
    await refreshFromStorage()
    if cache.snapshot().currentUserId != nil {
      log.info("AUTH2_REPAIR_USER_ID_HINT source=credential_snapshot persistence=skipped")
    }
  }

  // MARK: - Internals

  private static let authorityKeys = [
    legacyTokenKey,
    credentialsV2Key,
    inlineProtocolCredentialsKey,
  ]

  private func persistCredentialAuthority(
    snapshot: AuthSnapshot,
    loginAttempt: AuthLoginAttempt?,
    writeAuthority: () throws -> Void
  ) throws {
    let finalizeImmediately = loginAttempt == nil
    let currentSnapshot = cache.snapshot()
    let preservesAccountMutationGeneration = finalizeImmediately &&
      currentSnapshot.isLoggedIn &&
      currentSnapshot.currentUserId == snapshot.currentUserId
    let authorityAttempt: AuthLoginAttempt
    if let loginAttempt {
      authorityAttempt = loginAttempt
    } else if preservesAccountMutationGeneration {
      guard let replacementAttempt = cache.makeSameAccountAuthorityReplacementAttempt() else {
        throw AuthStorageError.loginUnavailable
      }
      authorityAttempt = replacementAttempt
    } else {
      authorityAttempt = cache.makeLoginAttempt()
    }
    let baseline = try stagedAuthorityBaseline ?? captureStoredAuthority()
    guard cache.beginAuthorityStaging(
      authorityAttempt,
      preservesAccountMutationGeneration: preservesAccountMutationGeneration
    ) else {
      throw credentialCommitFenceError(for: loginAttempt)
    }
    do {
      UserDefaults.standard.set(
        authorityAttempt.correlationID.uuidString,
        forKey: self.loginCommitPendingKey
      )
      guard UserDefaults.standard.synchronize(),
            UserDefaults.standard.string(forKey: self.loginCommitPendingKey)
              == authorityAttempt.correlationID.uuidString
      else { throw AuthStorageError.loginUnavailable }
    } catch {
      let markerIsAbsent = UserDefaults.standard.object(forKey: loginCommitPendingKey) == nil
      if markerIsAbsent {
        _ = cache.cancelAuthorityStagingReservation(authorityAttempt)
      } else {
        promoteFailedLoginToRecovery(correlationID: authorityAttempt.correlationID)
      }
      throw error
    }
    stagedAuthorityBaseline = baseline

    do {
      try writeAuthority()
      if let userID = snapshot.currentUserId {
        UserDefaults.standard.set(NSNumber(value: userID), forKey: userDefaultsKey)
      }
      credentialWriteInterleavingHook?()
      guard cache.finishAuthorityStaging(snapshot, owner: authorityAttempt) else {
        // Logout owns all credential destruction once its synchronous fence is installed.
        if hasPendingLogout() {
          _ = deleteAllStoredAuthority()
        }
        throw credentialCommitFenceError(for: loginAttempt)
      }
      if finalizeImmediately {
        _ = try finalizeCredentialsCommittedByLoginAttempt(authorityAttempt)
      }
    } catch {
      if hasPendingLogout() == false {
        do {
          try restoreStoredAuthority(baseline)
          UserDefaults.standard.removeObject(forKey: loginCommitPendingKey)
          guard UserDefaults.standard.synchronize(),
                UserDefaults.standard.object(forKey: loginCommitPendingKey) == nil
          else { throw AuthStorageError.loginUnavailable }
          let aborted = cache.abortAuthorityStaging(authorityAttempt)
          if aborted {
            stagedAuthorityBaseline = nil
          }
        } catch {
          log.error(
            "AUTH2_LOGIN failed to restore prior authority; retaining transition fence",
            error: error
          )
          promoteFailedLoginToRecovery(correlationID: authorityAttempt.correlationID)
        }
      }
      throw error
    }
  }

  private func captureStoredAuthority() throws -> StoredAuthorityBackup {
    let userIDHint = Self.readUserId(key: userDefaultsKey)
    if mocked {
      var values: [String: Data] = [:]
      for key in Self.authorityKeys {
        values[key] = AuthKeychainConfig.mockGetData(key, namespace: namespace)
      }
      return StoredAuthorityBackup(
        primary: [:],
        fallback: [:],
        mocked: values,
        userIDHint: userIDHint
      )
    }

    func read(_ key: String, from keychain: KeychainStore) throws -> Data? {
      if let value = keychain.getData(key) { return value }
      guard keychain.lastResultCode == errSecItemNotFound else {
        throw AuthStorageError.keychainWriteFailed
      }
      return nil
    }

    var primary: [String: Data] = [:]
    var fallback: [String: Data] = [:]
    for key in Self.authorityKeys {
      primary[key] = try read(key, from: primaryKeychain)
      if let fallbackKeychain {
        fallback[key] = try read(key, from: fallbackKeychain)
      }
    }
    return StoredAuthorityBackup(
      primary: primary,
      fallback: fallback,
      mocked: [:],
      userIDHint: userIDHint
    )
  }

  private func restoreStoredAuthority(_ backup: StoredAuthorityBackup) throws {
    if let authorityRestoreOverride, authorityRestoreOverride() == false {
      throw AuthStorageError.keychainWriteFailed
    }
    guard deleteAllStoredAuthority() else { throw AuthStorageError.keychainDeleteFailed }
    if mocked {
      for (key, value) in backup.mocked {
        AuthKeychainConfig.mockSet(value, forKey: key, namespace: namespace)
      }
    } else {
      for (key, value) in backup.primary {
        guard primaryKeychain.set(value, forKey: key, withAccess: .accessibleAfterFirstUnlock) else {
          throw AuthStorageError.keychainWriteFailed
        }
      }
      if let fallbackKeychain {
        for (key, value) in backup.fallback {
          guard fallbackKeychain.set(value, forKey: key, withAccess: .accessibleAfterFirstUnlock) else {
            throw AuthStorageError.keychainWriteFailed
          }
        }
      }
    }
    let restored = try captureStoredAuthority()
    guard restored.primary == backup.primary,
          restored.fallback == backup.fallback,
          restored.mocked == backup.mocked
    else { throw AuthStorageError.keychainWriteFailed }
    if let userIDHint = backup.userIDHint {
      UserDefaults.standard.set(NSNumber(value: userIDHint), forKey: userDefaultsKey)
    } else {
      UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
    guard UserDefaults.standard.synchronize(),
          Self.readUserId(key: userDefaultsKey) == backup.userIDHint
    else { throw AuthStorageError.keychainWriteFailed }
  }

  private func promoteFailedLoginToRecovery(correlationID: UUID = UUID()) {
    UserDefaults.standard.set(correlationID.uuidString, forKey: loginCommitPendingKey)
    _ = UserDefaults.standard.synchronize()
    cache.seedLoginCommitPending(true)
    _ = try? beginLogoutSynchronously()
    let snapshot = AuthSnapshot(
      status: .loggingOut(userIdHint: cache.snapshot().currentUserId ?? Self.readUserId(key: userDefaultsKey)),
      didHydrate: true
    )
    if cache.update(snapshot) {
      lastStatus = snapshot.status
      _ = snapshotPipe.yield(snapshot)
    }
    NotificationCenter.default.post(name: .authAccountRecoveryRequired, object: nil)
  }

  private func replaceStoredAuthority(
    with values: [String: Data],
    replacing keys: [String],
    replacementLabel: String
  ) throws {
    if mocked {
      for (key, value) in values {
        AuthKeychainConfig.mockSet(value, forKey: key, namespace: namespace)
      }
    } else {
      for (key, value) in values {
        let primarySaved = primaryKeychain.set(
          value,
          forKey: key,
          withAccess: .accessibleAfterFirstUnlock
        )
        let fallbackSaved = if !primarySaved, let fallbackKeychain {
          fallbackKeychain.set(value, forKey: key, withAccess: .accessibleAfterFirstUnlock)
        } else { false }
        guard primarySaved || fallbackSaved else {
          throw AuthStorageError.keychainWriteFailed
        }
      }
    }

    if let override = authorityReplacementDeletionOverride?(replacementLabel), override == false {
      throw AuthStorageError.keychainDeleteFailed
    }
    guard deleteStoredKeys(keys) else { throw AuthStorageError.keychainDeleteFailed }
  }

  private func deleteStoredKeys(_ keys: [String]) -> Bool {
    if mocked {
      for key in keys {
        AuthKeychainConfig.mockDelete(key, namespace: namespace)
      }
      return keys.allSatisfy {
        AuthKeychainConfig.mockGetData($0, namespace: namespace) == nil
      }
    }

    func delete(_ key: String, from keychain: KeychainStore) -> Bool {
      let deleted = keychain.delete(key)
      let absent = keychain.lastResultCode == errSecItemNotFound
      guard deleted || absent else { return false }
      let value = keychain.getData(key)
      return value == nil && keychain.lastResultCode == errSecItemNotFound
    }

    var removed = true
    for key in keys {
      removed = delete(key, from: primaryKeychain) && removed
      if let fallbackKeychain {
        removed = delete(key, from: fallbackKeychain) && removed
      }
    }
    return removed
  }

  @discardableResult
  private func deleteAllStoredAuthority() -> Bool {
    deleteStoredKeys(Self.authorityKeys)
  }

  private func credentialCommitFenceError(for loginAttempt: AuthLoginAttempt?) -> AuthStorageError {
    if hasPendingLogout() { return .logoutInProgress }
    if let loginAttempt, cache.isLoginAttemptCurrent(loginAttempt) == false {
      return .loginSuperseded
    }
    return .loginUnavailable
  }

  private func publishAuthenticatedSnapshot(_ snapshot: AuthSnapshot) {
    let previousStatus = lastStatus
    lastStatus = snapshot.status
    let revision = snapshotPipe.yield(snapshot)
    if let revision {
      log.info(
        "AUTH2_STATE_CHANGE revision=\(revision)" +
          " from=\(Self.diagnosticName(for: previousStatus))" +
          " to=\(Self.diagnosticName(for: snapshot.status))" +
          " hydrated=\(snapshot.didHydrate ? 1 : 0)"
      )
    }
    if previousStatus.isAuthenticated == false {
      if case let .authenticated(credentials) = snapshot.status {
        eventBroadcaster.yield(.login(userId: credentials.userId, token: credentials.token))
      } else if case let .authenticatedV3(userId) = snapshot.status {
        eventBroadcaster.yield(.loginV3(userId: userId))
      }
    }
  }

  private func update(_ snapshot: AuthSnapshot) async {
    guard cache.update(snapshot) else {
      log.warning(
        "AUTH2_STATE_CHANGE suppressed non-logout projection while logout fence is active"
      )
      return
    }
    let previousStatus = lastStatus
    lastStatus = snapshot.status
    let revision = snapshotPipe.yield(snapshot)
    if let revision {
      log.info(
        "AUTH2_STATE_CHANGE revision=\(revision)" +
          " from=\(Self.diagnosticName(for: previousStatus))" +
          " to=\(Self.diagnosticName(for: snapshot.status))" +
          " hydrated=\(snapshot.didHydrate ? 1 : 0)"
      )
    }
    updateLockedRetryLoop(for: snapshot.status)

    switch (previousStatus.isAuthenticated, snapshot.status.isAuthenticated) {
    case (false, true):
      if case let .authenticated(credentials) = snapshot.status {
        eventBroadcaster.yield(.login(userId: credentials.userId, token: credentials.token))
      } else if case let .authenticatedV3(userId) = snapshot.status {
        eventBroadcaster.yield(.loginV3(userId: userId))
      }
    case (true, false):
      eventBroadcaster.yield(.logout)
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

  static func readSnapshot(
    primaryKeychain: any KeychainClient,
    fallbackKeychain: (any KeychainClient)?,
    userDefaultsKey: String,
    mocked: Bool,
    namespace: String?
  ) -> AuthSnapshot {
    let userIdHint = readUserId(key: userDefaultsKey)
    let inlineProtocolOutcome: KeychainReadOutcome<Data> = if mocked {
      if let data = AuthKeychainConfig.mockGetData(inlineProtocolCredentialsKey, namespace: namespace) {
        .success(data, usedFallback: false)
      } else {
        .notFound(status: errSecItemNotFound)
      }
    } else {
      AuthKeychainConfig.readData(
        inlineProtocolCredentialsKey, primary: primaryKeychain, fallback: fallbackKeychain
      )
    }
    let inlineProtocol: InlineProtocolSessionCredentials?
    switch inlineProtocolOutcome {
    case .success(let data, _):
      do {
        let credentials = try JSONDecoder().decode(InlineProtocolSessionCredentials.self, from: data)
        try credentials.validate()
        inlineProtocol = credentials
      } catch {
        // Codable bypasses the authorization's validating initializer. A corrupt
        // V3 record must not publish authentication or silently fall back to V2.
        return AuthSnapshot(status: .reauthRequired(userIdHint: userIdHint), didHydrate: true)
      }
    case .notFound, .interactionNotAllowed, .error:
      inlineProtocol = nil
    }

    if case .interactionNotAllowed = inlineProtocolOutcome {
      return AuthSnapshot(status: .locked(userIdHint: userIdHint), didHydrate: true)
    }

    if let inlineProtocol {
      let hasBearerAuthority: Bool = if mocked {
        AuthKeychainConfig.mockGetData(credentialsV2Key, namespace: namespace) != nil
          || AuthKeychainConfig.mockGetData(legacyTokenKey, namespace: namespace) != nil
      } else {
        switch AuthKeychainConfig.readData(
          credentialsV2Key,
          primary: primaryKeychain,
          fallback: fallbackKeychain
        ) {
        case .success: true
        case .notFound, .interactionNotAllowed, .error:
          switch AuthKeychainConfig.readData(
            legacyTokenKey,
            primary: primaryKeychain,
            fallback: fallbackKeychain
          ) {
          case .success: true
          case .notFound, .interactionNotAllowed, .error: false
          }
        }
      }
      guard hasBearerAuthority == false else {
        // Mixed durable authorities are never silently prioritized. A staged-login marker handles
        // expected crash recovery; without one, require an explicit reauthentication replacement.
        return AuthSnapshot(status: .reauthRequired(userIdHint: userIdHint), didHydrate: true)
      }
      return AuthSnapshot(
        status: .authenticatedV3(userId: inlineProtocol.userId),
        didHydrate: true,
        inlineProtocol: inlineProtocol
      )
    }

    // 1) Try v2 record first.
    let credentialsOutcome: KeychainReadOutcome<Data> = if mocked {
      if let data = AuthKeychainConfig.mockGetData(credentialsV2Key, namespace: namespace) {
        .success(data, usedFallback: false)
      } else {
        .notFound(status: errSecItemNotFound)
      }
    } else {
      AuthKeychainConfig.readData(credentialsV2Key, primary: primaryKeychain, fallback: fallbackKeychain)
    }

    switch credentialsOutcome {
    case .success(let data, _):
      if let creds = try? JSONDecoder().decode(AuthCredentials.self, from: data) {
        guard creds.hasConsistentIdentity else {
          return AuthSnapshot(status: .reauthRequired(userIdHint: userIdHint), didHydrate: true)
        }
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
    let tokenOutcome: KeychainReadOutcome<String> = if mocked {
      if let token = AuthKeychainConfig.mockGetString(legacyTokenKey, namespace: namespace) {
        .success(token, usedFallback: false)
      } else {
        .notFound(status: errSecItemNotFound)
      }
    } else {
      AuthKeychainConfig.readString(legacyTokenKey, primary: primaryKeychain, fallback: fallbackKeychain)
    }

    let token: String? = switch tokenOutcome {
    case .success(let token, _): token
    case .notFound, .interactionNotAllowed, .error: nil
    }

    var userId = userIdHint
    if userId == nil, let token {
      userId = parseUserId(fromToken: token)
    }

    if let token, let userId {
      let credentials = AuthCredentials(userId: userId, token: token)
      guard credentials.hasConsistentIdentity else {
        return AuthSnapshot(status: .reauthRequired(userIdHint: userId), didHydrate: true)
      }
      return AuthSnapshot(
        status: .authenticated(credentials),
        didHydrate: true,
        inlineProtocol: nil
      )
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

  private static func diagnosticName(for status: AuthStatus) -> String {
    switch status {
    case .hydrating: "hydrating"
    case .unauthenticated: "unauthenticated"
    case .locked: "locked"
    case .reauthRequired: "reauth_required"
    case .loggingOut: "logging_out"
    case .authenticated: "authenticated"
    case .authenticatedV3: "authenticated_v3"
    }
  }
}
