import Auth
import InlineKit
import Logger
import UIKit

enum LogoutPerformer {
  @MainActor private static var isRunning = false

  @MainActor
  static func perform(
    notifyServer: Bool,
    mainRouter: MainViewRouter,
    navigation: Navigation,
    onboardingNavigation: OnboardingNavigation,
    router: Router
  ) async {
    guard !isRunning else { return }
    isRunning = true
    defer { isRunning = false }

    let logoutFence: AuthLogoutFence
    do {
      // Exact first-suspension invariant shared with macOS.
      logoutFence = try Auth.shared.beginLogoutSynchronously()
    } catch {
      Log.shared.error("iOS logout durable fence failed", error: error)
      return
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
    await FileDownloader.shared.resetSession()
    NotionTaskService.shared.resetSession()
    await Transactions.shared.clearAllAndWait()
    await AgentConfigurationCatalogStore.shared.clear()

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
    router.reset()
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
