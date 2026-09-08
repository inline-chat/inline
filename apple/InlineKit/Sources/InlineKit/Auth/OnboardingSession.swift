import Auth
import Foundation
import InlineProtocol
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
    let account = try Auth.shared.handle.beginAccountMutation()
    var user = try await User.fetch(id: account.userID, from: AppDatabase.shared)
    if user == nil {
      let result = try await withConnection(realtime: Api.realtime, accountToken: account) { realtime in
        try await realtime.callRpcDirect(method: .getMe, input: .getMe(.init()), accountToken: account)
      }
      guard case let .getMe(response) = result, response.hasUser, response.user.id == account.userID else {
        throw RealtimeDirectRpcError.notAuthorized
      }
      user = try await AppDatabase.shared.dbWriter.write { db in
        try Auth.shared.handle.validateAccountMutation(account)
        return try User.save(db, user: response.user)
      }
    }
    try Task.checkCancellation()
    try Auth.shared.handle.validateAccountMutation(account)
    return requiresSetup(pendingSetup: user?.pendingSetup, firstName: user?.firstName) ? account.userID : nil
  }
}
