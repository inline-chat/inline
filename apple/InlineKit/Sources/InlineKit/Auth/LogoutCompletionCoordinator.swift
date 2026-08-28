@_spi(LogoutCoordinator) import Auth
import Foundation

/// Stateless proof gate for the final logout authority commit. It owns no lifecycle state; Auth's
/// durable fence remains authoritative, and only matching database and credential receipts can
/// remove it.
public enum LogoutCompletionCoordinator {
  public static func complete(
    fence: AuthLogoutFence,
    databaseProof: AuthDatabaseCleanupProof,
    credentialProof: AuthCredentialDestructionProof,
    completionPermit: AuthLogoutCompletionPermit,
    auth: Auth = .shared
  ) async -> Bool {
    await auth.completePendingLogout(
      fence: fence,
      databaseProof: databaseProof,
      credentialProof: credentialProof,
      completionPermit: completionPermit
    )
  }
}
