import InlineKit
import SwiftUI

struct LogoutSection: View {
  @EnvironmentObject private var mainRouter: MainViewRouter
  @EnvironmentObject private var navigation: Navigation
  @EnvironmentObject private var onboardingNavigation: OnboardingNavigation
  @Environment(Router.self) private var router

  @State private var showLogoutAlert = false

  var body: some View {
    Section(header: Text("Actions")) {
      Button {
        showLogoutAlert = true
      } label: {
        HStack {
          Image(systemName: "rectangle.portrait.and.arrow.right.fill")
            .font(.callout)
            .foregroundColor(.white)
            .frame(width: 25, height: 25)
            .background(ThemeManager.shared.logoutRedColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
          Text("Logout")
            .foregroundColor(ThemeManager.shared.logoutRedColor)
            .padding(.leading, 4)
          Spacer()
        }
        .padding(.vertical, 2)
      }
    }
    .alert("Logout", isPresented: $showLogoutAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Logout", role: .destructive) {
        Task { await performLogout() }
      }
    } message: {
      Text("Are you sure you want to logout? This will clear your local data and return you to the welcome screen.")
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
    await LogoutPerformer.perform(
      notifyServer: true,
      mainRouter: mainRouter,
      navigation: navigation,
      onboardingNavigation: onboardingNavigation,
      router: router
    )
  }
}
