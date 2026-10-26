import Auth
import InlineGrid
import InlineKit
import Logger
import UIKit
import UserNotifications

enum LogoutPerformer {
  @MainActor private static var isRunning = false

  @MainActor
  static func perform(
    notifyServer: Bool,
    invalidationReceipt: AuthInvalidationReceipt? = nil,
    mainRouter: MainViewRouter,
    navigation: Navigation,
    onboardingNavigation: OnboardingNavigation,
    router: Router
  ) async {
    guard !isRunning else { return }
    isRunning = true
    defer { isRunning = false }

    let logoutAccountID = Auth.shared.getCurrentUserId()
    let logoutFence: AuthLogoutFence
    do {
      // Exact first-suspension invariant shared with macOS.
      if let invalidationReceipt {
        guard let fence = try Auth.shared.beginLogoutSynchronously(ifCurrent: invalidationReceipt) else {
          Log.shared.info("iOS logout ignored stale account revocation")
          return
        }
        logoutFence = fence
      } else {
        logoutFence = try Auth.shared.beginLogoutSynchronously()
      }
    } catch {
      Log.shared.error("iOS logout durable fence failed", error: error)
      return
    }

    // The fence above already told the notification extension this account is signed out.
    // Also retire the push key and the account's visible notifications before any suspension.
    AppDelegate.retirePushContentKeyForLogout()
    let notificationCenter = UNUserNotificationCenter.current()
    notificationCenter.removeAllDeliveredNotifications()
    notificationCenter.removeAllPendingNotificationRequests()

    // Fence playback and pending download intent before the first suspension.
    SharedAudioPlayer.shared.stop()
    // Close media admission before logout's first suspension. Account fencing
    // alone does not stop a sender already running in the RTC engine.
    if let grid = GridRuntime.existing {
      grid.rooms.withdrawLocalAdmission()
      let mediaShutdown = await grid.prepareForLogout()
      guard mediaShutdown.isLocallyQuiescent else {
        Log.shared.error("iOS logout stopped: Grid local media shutdown could not be proven")
        return
      }
    }

    (UIApplication.shared.delegate as? AppDelegate)?.cancelPendingSpaceJoin()
    ProviderSignInCoordinator.shared.cancelPendingAttempt()

    await Auth.shared.publishLogoutInProgress()
    await InlineProtocolNativeLogin.shared.cancel()

    if notifyServer {
      await notifyServerLogout()
    }

    Analytics.logout()
    await IntentDonationCoordinator.deleteAll()
    do {
      try await AppDataUpdater.shared.clearSharedData()
    } catch {
      Log.shared.error("Share-extension logout cleanup failed", error: error)
    }

    // Stop every account-owned producer before clearing credentials or the database.
    await Api.realtime.loggedOut()
    await ReservedChatIDPool.shared.drainForAccountTransition()
    await Realtime.shared.loggedOut()
    await FileUploader.shared.cancelAll()
    await FileCache.shared.cancelAllDownloads()
    await FileDownloader.shared.resetSession(accountID: logoutAccountID)
    NotionTaskService.shared.resetSession()
    await Transactions.shared.clearAllAndWait()
    await AgentConfigurationCatalogStore.shared.clear()
    await MainActor.run {
      AgentWorkStateStore.shared.removeAll()
      AgentGrantStore.shared.removeAll()
    }

    BotAgentDirectory.shared.clear()
    TabsManager.shared.reset()
    TabsManager.shared.clearActiveSpaceId()
    ChatState.shared.reset()

    let databaseProof: AuthDatabaseCleanupProof
    do {
      databaseProof = try await AppDatabase.loggedOutAsync(fence: logoutFence)
    } catch {
      Log.shared.error("Local database logout cleanup failed: \(error.localizedDescription)")
      return
    }

    guard let credentialProof = await Auth.shared.destroyCredentialsForPendingLogout(
      fence: logoutFence
    ) else {
      Log.shared.error("iOS logout credential destruction failed")
      return
    }
    guard await LogoutCompletionCoordinator.complete(
      fence: logoutFence,
      databaseProof: databaseProof,
      credentialProof: credentialProof,
      completionPermit: AuthLogoutCompletionPermit(fence: logoutFence)
    ) else {
      Log.shared.error("iOS logout completion proof validation failed")
      return
    }

    navigation.reset()
    onboardingNavigation.reset()
    // The scene registry also resets on account changes; preserve here too in case
    // logout completes before that auth observation is delivered.
    router.reset(preservingSelectedTab: true)
    mainRouter.setRoute(route: .onboarding)
  }

  private static func notifyServerLogout() async {
    do {
      try await InlineRPCClient.shared.logout(timeout: .seconds(2))
    } catch {
      Log.shared.error("Logout API call failed: \(error.localizedDescription)")
    }
  }
}
