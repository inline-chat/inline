import Auth
import InlineKit
import Logger
import UIKit

enum LogoutPerformer {
  @MainActor private static var isRunning = false

  static func perform(
    notifyServer: Bool,
    mainRouter: MainViewRouter,
    navigation: Navigation,
    onboardingNavigation: OnboardingNavigation,
    router: Router
  ) async {
    let shouldRun = await MainActor.run {
      guard !isRunning else { return false }
      isRunning = true
      return true
    }
    guard shouldRun else { return }

    await MainActor.run {
      (UIApplication.shared.delegate as? AppDelegate)?.cancelPendingSpaceJoin()
    }

    await Auth.shared.beginLogout()

    defer {
      Task { @MainActor in
        isRunning = false
      }
    }

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
    await Realtime.shared.loggedOut()
    await FileUploader.shared.cancelAll()
    await FileCache.shared.cancelAllDownloads()
    await FileDownloader.shared.resetSession()
    await MainActor.run {
      NotionTaskService.shared.resetSession()
    }
    await Transactions.shared.clearAllAndWait()

    await MainActor.run {
      BotAgentDirectory.shared.clear()
      TabsManager.shared.reset()
      TabsManager.shared.clearActiveSpaceId()
      ChatState.shared.reset()
    }

    do {
      try AppDatabase.loggedOut()
    } catch {
      Log.shared.error("Local database logout cleanup failed: \(error.localizedDescription)")
      return
    }

    await Auth.shared.logOut()

    await MainActor.run {
      navigation.reset()
      onboardingNavigation.reset()
      router.reset()
      mainRouter.setRoute(route: .onboarding)
    }
  }

  private static func notifyServerLogout() async {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await InlineRPCClient.shared.logout()
        }

        group.addTask {
          try await Task.sleep(nanoseconds: 2 * 1_000_000_000)
          throw LogoutTimeoutError()
        }

        _ = try await group.next()
        group.cancelAll()
      }
    } catch {
      Log.shared.error("Logout API call failed: \(error.localizedDescription)")
    }
  }
}

private struct LogoutTimeoutError: Error {}
