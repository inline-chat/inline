import InlineKit
import SwiftUI

struct LogoutSection: View {
  @EnvironmentObject private var webSocket: WebSocketManager
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

  private func performLogout() async {
    _ = try? await ApiClient.shared.logout()
    Auth.shared.logOut()
    webSocket.loggedOut()
    try? AppDatabase.loggedOut()
    mainRouter.setRoute(route: .onboarding)
    navigation.popToRoot()
    onboardingNavigation.push(.welcome)
  }
}
