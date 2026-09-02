import Auth
import Foundation
import InlineConfig
import InlineKit
import Logger

/// All macOS logout policy lives in this file. AppDelegate only owns the platform lifetime and
/// forwards entry points; Auth owns durable authority, proofs, and login admission.
private enum MacLogoutTimeouts {
  static let serverNotification: Duration = .seconds(2)
  static let overallRecoveryUI: Duration = .seconds(15)
}

enum MacLogoutPhase: String, Sendable {
  case durableFence = "durable_fence"
  case serverNotification = "server_notification"
  case loginCancellation = "login_cancellation"
  case accountTasks = "account_tasks"
  case grid = "grid"
  case realtimeV2 = "realtime_v2"
  case legacyRealtime = "legacy_realtime"
  case uploads = "uploads"
  case cachedDownloads = "cached_downloads"
  case downloads = "downloads"
  case drafts = "drafts"
  case quickSearch = "quick_search"
  case commandBar = "command_bar"
  case transactions = "transactions"
  case database = "database"
  case credentials = "credentials"

  var diagnosticCode: Int {
    switch self {
    case .durableFence: 1
    case .serverNotification: 2
    case .loginCancellation: 3
    case .accountTasks: 4
    case .grid: 5
    case .realtimeV2: 6
    case .legacyRealtime: 7
    case .uploads: 8
    case .cachedDownloads: 9
    case .downloads: 10
    case .drafts: 11
    case .quickSearch: 12
    case .commandBar: 13
    case .transactions: 14
    case .database: 15
    case .credentials: 16
    }
  }
}

fileprivate enum MacLogoutFailureKind: String, Sendable {
  case timeout
  case localQuiescence
  case database
  case credentials
}

private struct MacLogoutDiagnosticError: Error, LocalizedError, Sendable,
  PrivacySafeErrorCategoryProviding
{
  let phase: MacLogoutPhase
  let kind: MacLogoutFailureKind

  var errorDescription: String? {
    "macOS logout failed kind=\(kind.rawValue) phase=\(phase.rawValue)"
  }

  var privacySafeErrorCategory: String {
    "mac_logout:\(kind.rawValue):\(phase.rawValue)"
  }
}

@MainActor
final class MacLogoutAttempt {
  enum State {
    case active
    case finalizing
    case failed
    case finished
  }

  let transitionID: UUID
  let completionPermit: AuthLogoutCompletionPermit
  let startedAt = Date()
  var phase = MacLogoutPhase.durableFence
  var phaseStartedAt = Date()
  var deadlineTask: Task<Void, Never>?
  var state = State.active

  init(transitionID: UUID, completionPermit: AuthLogoutCompletionPermit) {
    self.transitionID = transitionID
    self.completionPermit = completionPermit
  }

  var elapsedMilliseconds: Int {
    max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
  }
}

extension AppDelegate {
  @MainActor
  func performLogOut(notifyServer: Bool = true) async {
    guard !isLoggingOut else { return }
    guard !deferLogoutUntilLocalDataResetFinishes(notifyServer: notifyServer) else { return }
    isLoggingOut = true
    let logoutAccountID = Auth.shared.getCurrentUserId()

    let logoutFence: AuthLogoutFence
    do {
      // Exact first-suspension invariant: close durable and in-memory credential admission before
      // UI routing, RPCs, actor hops, or destructive cleanup.
      logoutFence = try Auth.shared.beginLogoutSynchronously()
    } catch {
      if Auth.shared.getHasPendingLogout() == false {
        if Auth.shared.getHasPendingAccountTransition() {
          dependencies.viewModel.navigate(.loading)
          LoggingOutWindowController.showRecoveryRequired()
          log.error("LOGOUT_TRACE event=durable_fence_ambiguous_account_transition", error: error)
          return
        }
        isLoggingOut = false
        ToastCenter.shared.showError("Sign out did not start. You are still signed in.")
        log.error("LOGOUT_TRACE event=durable_fence_aborted", error: error)
        return
      }
      guard let fallbackFence = Auth.shared.getCurrentLogoutFence() else {
        isLoggingOut = false
        ToastCenter.shared.showError("Sign out did not start. You are still signed in.")
        log.error("LOGOUT_TRACE event=durable_fence_failed_without_active_fence", error: error)
        return
      }
      let attempt = MacLogoutAttempt(
        transitionID: fallbackFence.correlationID,
        completionPermit: AuthLogoutCompletionPermit(fence: fallbackFence)
      )
      logoutAttempt = attempt
      dependencies.viewModel.navigate(.loading)
      LoggingOutWindowController.show()
      log.error("LOGOUT_TRACE event=durable_fence_failed", error: error)
      failLogout(attempt, kind: .credentials)
      return
    }

    let attempt = MacLogoutAttempt(
      transitionID: logoutFence.correlationID,
      completionPermit: AuthLogoutCompletionPermit(fence: logoutFence)
    )
    logoutAttempt = attempt

    // Cancel main-actor account continuations before any fallible/network suspension.
    cancelPendingSpaceJoin()
    ProviderSignInCoordinator.shared.cancelPendingAttempt()

    dependencies.viewModel.navigate(.loading)
    SettingsWindowController.closeIfOpen()
    LoggingOutWindowController.show()
    startLogoutDeadline(for: attempt)

    beginLogoutPhase(.durableFence, attempt: attempt)
    finishLogoutPhase(attempt: attempt)
    guard canContinueLogout(attempt) else { return }

    // The first awaited auth operation publishes the non-loginable state. Remote notification is
    // best effort and can never own or delay local authority cleanup beyond its request deadline.
    await Auth.shared.publishLogoutInProgress()
    guard canContinueLogout(attempt) else { return }

    beginLogoutPhase(.loginCancellation, attempt: attempt)
    await InlineProtocolNativeLogin.shared.cancel()
    finishLogoutPhase(attempt: attempt)
    guard canContinueLogout(attempt) else { return }

    if notifyServer {
      beginLogoutPhase(.serverNotification, attempt: attempt)
      let notified = await notifyServerLogout()
      finishLogoutPhase(attempt: attempt, success: notified)
      guard canContinueLogout(attempt) else { return }
    }

    Analytics.logout()

    guard await runLogoutPhase(.accountTasks, attempt: attempt, operation: {
      await dependencies.session.resetAndWait()
      await MainWindowController.cancelAccountTasksAndWait()
    }) else { return }

    beginLogoutPhase(.grid, attempt: attempt)
    let mediaShutdown = await dependencies.gridRuntime.prepareForLogout()
    finishLogoutPhase(attempt: attempt, success: mediaShutdown.isLocallyQuiescent)
    guard canContinueLogout(attempt) else { return }
    guard mediaShutdown.isLocallyQuiescent else {
      log.error(
        "Logout stopped because Grid local media shutdown could not be proven: active_rooms=\(mediaShutdown.locallyActiveRoomCount) rtc_media_mutations=\(mediaShutdown.rtcLocalMediaMutationCount) microphone_publications=\(mediaShutdown.microphonePublicationCount) screen_publications=\(mediaShutdown.screenSharePublicationCount) failures=\(mediaShutdown.failures.joined(separator: ", "))"
      )
      failLogout(attempt, kind: .localQuiescence)
      return
    }

    // Stop every account-owned producer before clearing credentials or the database.
    guard await runLogoutPhase(.realtimeV2, attempt: attempt, operation: {
      await Api.realtime.loggedOut()
      await ReservedChatIDPool.shared.drainForAccountTransition()
    }) else { return }
    guard await runLogoutPhase(.legacyRealtime, attempt: attempt, operation: {
      await dependencies.realtime.loggedOut()
    }) else { return }
    guard await runLogoutPhase(.uploads, attempt: attempt, operation: {
      await FileUploader.shared.cancelAll()
    }) else { return }
    guard await runLogoutPhase(.cachedDownloads, attempt: attempt, operation: {
      await FileCache.shared.cancelAllDownloads()
    }) else { return }
    guard await runLogoutPhase(.downloads, attempt: attempt, operation: {
      await FileDownloader.shared.resetSession()
    }) else { return }
    NotionTaskService.shared.resetSession()
    guard await runLogoutPhase(.drafts, attempt: attempt, operation: {
      await Drafts2.shared.resetForAccountChange()
    }) else { return }

    guard await runLogoutPhase(.quickSearch, attempt: attempt, operation: {
      if let logoutAccountID {
        await QuickSearchUsageStore.shared.clear(accountID: logoutAccountID)
      }
    }) else { return }
    guard await runLogoutPhase(.commandBar, attempt: attempt, operation: {
      await dependencies.commandBarCatalog.reset()
    }) else { return }
    guard await runLogoutPhase(.transactions, attempt: attempt, operation: {
      await Transactions.shared.clearAllAndWait()
    }) else { return }
    await AgentConfigurationCatalogStore.shared.clear()
    ObjectCache.shared.clear()

    beginLogoutPhase(.database, attempt: attempt)
    let databaseProof: AuthDatabaseCleanupProof
    do {
      databaseProof = try await AppDatabase.loggedOutAsync(fence: logoutFence)
    } catch {
      finishLogoutPhase(attempt: attempt, success: false)
      log.error(
        "Logout stopped because local database cleanup failed profile=\(ProjectConfig.userProfile ?? "default") reason=\(error.localizedDescription)",
        error: error
      )
      failLogout(attempt, kind: .database)
      return
    }
    finishLogoutPhase(attempt: attempt)
    guard canContinueLogout(attempt) else { return }

    dependencies.appUndo.clear()
    beginLogoutPhase(.credentials, attempt: attempt)
    let credentialProof = await Auth.shared.destroyCredentialsForPendingLogout(fence: logoutFence)
    finishLogoutPhase(attempt: attempt, success: credentialProof != nil)
    guard canContinueLogout(attempt) else { return }
    guard let credentialProof else {
      failLogout(attempt, kind: .credentials)
      return
    }

    // The same deadline remains armed through durable marker removal. Revocation and completion
    // are mutually exclusive, so a late actor continuation cannot route onboarding after timeout.
    guard attempt.state == .active else { return }
    attempt.state = .finalizing
    let completed = await LogoutCompletionCoordinator.complete(
      fence: logoutFence,
      databaseProof: databaseProof,
      credentialProof: credentialProof,
      completionPermit: attempt.completionPermit
    )
    guard completed, attempt.state == .finalizing else {
      failLogout(attempt, kind: .credentials)
      return
    }

    dependencies.navigation.reset()
    dependencies.nav.reset()
    dependencies.viewModel.navigate(.onboarding)
    MainWindowOpenCoordinator.shared.openOnboarding()

    attempt.state = .finished
    attempt.deadlineTask?.cancel()
    LoggingOutWindowController.dismiss()
    logoutAttempt = nil
    isLoggingOut = false
  }

  @MainActor private func startLogoutDeadline(for attempt: MacLogoutAttempt) {
    attempt.deadlineTask = Task { @MainActor [weak self, weak attempt] in
      do {
        try await Task.sleep(for: MacLogoutTimeouts.overallRecoveryUI)
      } catch {
        return
      }
      guard let self, let attempt, self.logoutAttempt === attempt,
            !Task.isCancelled,
            attempt.state == .active || attempt.state == .finalizing,
            attempt.completionPermit.revoke()
      else { return }
      self.failLogout(attempt, kind: .timeout)
    }
  }

  @MainActor private func beginLogoutPhase(_ phase: MacLogoutPhase, attempt: MacLogoutAttempt) {
    attempt.phase = phase
    attempt.phaseStartedAt = Date()
    log.info(
      "LOGOUT_TRACE transition_id=\(attempt.transitionID.uuidString) event=phase_started phase=\(phase.rawValue) elapsed_ms=\(attempt.elapsedMilliseconds)"
    )
  }

  @MainActor private func finishLogoutPhase(attempt: MacLogoutAttempt, success: Bool = true) {
    let duration = max(0, Int(Date().timeIntervalSince(attempt.phaseStartedAt) * 1_000))
    let effectiveSuccess = success && canContinueLogout(attempt)
    log.info(
      "LOGOUT_TRACE transition_id=\(attempt.transitionID.uuidString) event=phase_finished phase=\(attempt.phase.rawValue) duration_ms=\(duration) success=\(effectiveSuccess ? 1 : 0)"
    )
    PerformanceTrace.breadcrumb(
      "mac_logout_phase",
      category: "auth.logout",
      level: effectiveSuccess ? .info : .warning,
      data: [
        "attempt": attempt.phase.diagnosticCode,
        "transition_id": attempt.transitionID.uuidString,
        "duration_ms": duration,
        "success": effectiveSuccess,
      ]
    )
  }

  @MainActor private func runLogoutPhase(
    _ phase: MacLogoutPhase,
    attempt: MacLogoutAttempt,
    operation: @MainActor () async -> Void
  ) async -> Bool {
    beginLogoutPhase(phase, attempt: attempt)
    await operation()
    finishLogoutPhase(attempt: attempt)
    return canContinueLogout(attempt)
  }

  @MainActor private func canContinueLogout(_ attempt: MacLogoutAttempt) -> Bool {
    logoutAttempt === attempt && attempt.state == .active
  }

  @MainActor private func failLogout(_ attempt: MacLogoutAttempt, kind: MacLogoutFailureKind) {
    guard logoutAttempt === attempt,
          attempt.state == .active || attempt.state == .finalizing
    else { return }
    attempt.state = .failed
    _ = attempt.completionPermit.revoke()
    attempt.deadlineTask?.cancel()
    let diagnostic = MacLogoutDiagnosticError(phase: attempt.phase, kind: kind)
    log.error(
      "LOGOUT_TRACE transition_id=\(attempt.transitionID.uuidString) event=failed phase=\(attempt.phase.rawValue) kind=\(kind.rawValue) elapsed_ms=\(attempt.elapsedMilliseconds)",
      error: diagnostic
    )
    PerformanceTrace.breadcrumb(
      "mac_logout_failed",
      category: "auth.logout",
      level: .error,
      data: [
        "attempt": attempt.phase.diagnosticCode,
        "transition_id": attempt.transitionID.uuidString,
        "elapsed_ms": attempt.elapsedMilliseconds,
        "success": false,
      ]
    )
    Task {
      await Auth.shared.publishLogoutInProgress()
    }
    LoggingOutWindowController.showRecoveryRequired()
  }

  private func notifyServerLogout() async -> Bool {
    do {
      try await InlineRPCClient.shared.logout(timeout: MacLogoutTimeouts.serverNotification)
      return true
    } catch {
      log.warning(
        "Server logout notification did not complete; continuing local logout reason=\(type(of: error))"
      )
      return false
    }
  }
}
