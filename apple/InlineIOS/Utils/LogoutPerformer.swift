import Auth
import InlineKit
import Logger

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

    defer {
      Task { @MainActor in
        isRunning = false
      }
    }

    await Realtime.shared.loggedOut()

    if notifyServer {
      await notifyServerLogout()
    }

    Analytics.logout()
    await Auth.shared.logOut()

    do {
      try AppDatabase.loggedOut()
    } catch {
      Log.shared.error("Local database logout cleanup failed: \(error.localizedDescription)")
    }

    Transactions.shared.clearAll()

    await MainActor.run {
      TabsManager.shared.reset()
      TabsManager.shared.clearActiveSpaceId()
      ChatState.shared.reset()
      navigation.reset()
      mainRouter.setRoute(route: .onboarding)
      onboardingNavigation.reset()
      router.reset()
    }
  }

  private static func notifyServerLogout() async {
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await ApiClient.shared.logout()
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
