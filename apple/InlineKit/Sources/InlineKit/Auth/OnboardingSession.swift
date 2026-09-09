import Auth
import Foundation
import InlineProtocol
import Logger
import RealtimeV2

/// Uses the existing account and connection owners for short onboarding operations.
public enum OnboardingSession {
  public static func requiresSetup(pendingSetup: Bool?, firstName: String?) -> Bool {
    pendingSetup == true || firstName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
  }

  @MainActor
  public static func withConnection<Value: Sendable>(
    realtime: RealtimeV2,
    accountToken: AuthAccountMutationToken? = nil,
    operation: @escaping @Sendable (RealtimeV2) async throws -> Value
  ) async throws -> Value {
    let account = try accountToken ?? Auth.shared.handle.beginAccountMutation()
    _ = await AppDatabase.promoteSharedToPersistentIfPossible()
    try Auth.shared.handle.validateAccountMutation(account)
    guard await Api.admitPersistentStorage() else { throw RealtimeDirectRpcError.notConnected }
    if realtime !== Api.realtime {
      guard await realtime.admitPersistentStorage() else { throw RealtimeDirectRpcError.notConnected }
    }
    return try await realtime.withUserInitiatedConnection(accountToken: account, operation: operation)
  }

  /// Resolve before constructing the authenticated root. A missing cache row is unknown, not complete.
  @MainActor
  public static func pendingProfileUserID() async throws -> Int64? {
    try await pendingProfileUserID(database: AppDatabase.shared, auth: Auth.shared.handle) { account in
      let result = try await withConnection(realtime: Api.realtime, accountToken: account) { realtime in
        try await realtime.callRpcDirect(method: .getMe, input: .getMe(.init()), accountToken: account)
      }
      guard case let .getMe(response) = result, response.hasUser else {
        throw RealtimeDirectRpcError.notAuthorized
      }
      return response.user
    }
  }

  /// The normal path only reads local data. Construct/start realtime only in the missing-row branch.
  @MainActor
  static func pendingProfileUserID(
    database: AppDatabase,
    auth: AuthHandle,
    fetchMissingUser: (AuthAccountMutationToken) async throws -> InlineProtocol.User
  ) async throws -> Int64? {
    try Task.checkCancellation()
    let account = try auth.beginAccountMutation()
    let cacheSpan = PerformanceTrace.begin("StartupProfileCacheRead", category: .launch)
    var user: User?
    do {
      defer { cacheSpan.end() }
      user = try await User.fetch(id: account.userID, from: database)
    }
    try Task.checkCancellation()
    try auth.validateAccountMutation(account)
    if user == nil {
      let recoverySpan = PerformanceTrace.begin("StartupProfileRecovery", category: .launch)
      defer { recoverySpan.end() }
      let remoteUser = try await fetchMissingUser(account)
      try Task.checkCancellation()
      try auth.validateAccountMutation(account)
      guard remoteUser.id == account.userID else { throw RealtimeDirectRpcError.notAuthorized }
      user = try await database.dbWriter.write { db in
        try auth.validateAccountMutation(account)
        return try User.save(db, user: remoteUser)
      }
    }
    try Task.checkCancellation()
    try auth.validateAccountMutation(account)
    return requiresSetup(pendingSetup: user?.pendingSetup, firstName: user?.firstName) ? account.userID : nil
  }
}
