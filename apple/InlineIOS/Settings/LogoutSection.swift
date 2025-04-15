import Auth
import InlineKit
import SwiftUI
import Logger

struct LogoutSection: View {
  @EnvironmentObject private var mainRouter: MainViewRouter
  @EnvironmentObject private var navigation: Navigation
  @EnvironmentObject private var onboardingNavigation: OnboardingNavigation

  var body: some View {
    Section(header: Text("Actions")) {
      Button("Logout", role: .destructive) {
        Task { await performLogout() }
      }
    }
  }

//  private func performLogout() async {
//    _ = try? await ApiClient.shared.logout()
//    await Auth.shared.logOut()
//    webSocket.loggedOut()
//    try? AppDatabase.loggedOut()
//    try? AppDatabase.clearDB()
//    mainRouter.setRoute(route: .onboarding)
//    navigation.popToRoot()
//    onboardingNavigation.push(.welcome)
//  }

  private func performLogout() async {
    do {
      // 2. Close active connections first
      await Realtime.shared.loggedOut()

      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          // Tell server about logout
          group.addTask {
            let _ = try await ApiClient.shared.logout()
          }

          // Timeout
          group.addTask {
            try await Task.sleep(nanoseconds: 2 * 1_000_000_000) // 2 seconds
            throw TimeoutError()
          }

          // Return first completed result or throw error
          let result = try await group.next()!
          group.cancelAll() // Cancel other tasks
          return result
        }
      } catch {
        // Handle logout error
        Log.shared.error("Logout API call failed: \(error.localizedDescription)")
      }

      // 4. Clear local authentication state
      await Auth.shared.logOut()

      // 5. Clear database (combine operations if possible)
      try AppDatabase.loggedOut()
      try AppDatabase.clearDB()

      // 6. Update UI on main thread
      await MainActor.run {
        mainRouter.setRoute(route: .onboarding)
        navigation.popToRoot()
        onboardingNavigation.push(.welcome)
      }
    } catch {
      // Show error to user
      Log.shared.error("Logout failed: \(error.localizedDescription)")
    }
  }
}

struct TimeoutError: Error {
  var localizedDescription: String {
    return "Logout timed out."
  }
}
