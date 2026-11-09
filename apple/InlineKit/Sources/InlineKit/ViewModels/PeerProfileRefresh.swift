import Auth
import Foundation

/// Bounds background profile refreshes while a chat is open. Every new chat view
/// starts fresh; repeated history repairs share its cooldown and in-flight work.
actor PeerProfileRefresh {
  private var inFlight = false
  private var lastSuccess: (account: AuthAccountMutationToken, date: Date)?

  func refresh(
    account: AuthAccountMutationToken,
    force: Bool = false,
    now: Date = .now,
    operation: @Sendable () async throws -> Void
  ) async throws {
    guard !inFlight else { return }
    if !force, let lastSuccess, lastSuccess.account == account,
       now.timeIntervalSince(lastSuccess.date) < 30
    {
      return
    }

    inFlight = true
    defer { inFlight = false }
    try Task.checkCancellation()
    try await operation()
    lastSuccess = (account, now)
  }
}
