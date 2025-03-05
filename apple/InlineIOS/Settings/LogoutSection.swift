import Auth
import InlineKit
import SwiftUI

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
        
      // 3. Tell server about logout
      _ = try await ApiClient.shared.logout()
        
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
      // Handle errors appropriately
      await MainActor.run {
        // Show error to user
        print("Logout failed: \(error.localizedDescription)")
      }
    }
  }
}
