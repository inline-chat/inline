import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var navigation: OnboardingNavigation

  var body: some View {
    NavigationStack(path: $navigation.path) {
      Welcome()
        .navigationDestination(for: OnboardingStep.self) { step in
          switch step {
          case .email(let prevEmail):
            Email(prevEmail: prevEmail)
          case .code(let email):
            Code(email: email)
          case .profile:
            AddAccount()
          case .welcome:
            Welcome()
          case .main:
            MainView()
          }
        }
    }
    .animation(.snappy, value: navigation.path)
  }
}
