import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var navigation: OnboardingNavigation

  var body: some View {
    NavigationStack(path: $navigation.path) {
      Welcome()
        .navigationDestination(for: OnboardingStep.self) { step in
          switch step {
            case let .email(prevEmail):
              Email(prevEmail: prevEmail)
            case let .code(email):
              Code(email: email)
            case .profile:
              Profile()
            case .welcome:
              Welcome()
            case .main:
              HomeView()
            case let .phoneNumber(prevPhoneNumber):
              PhoneNumber(prevPhoneNumber: prevPhoneNumber)
            case let .phoneNumberCode(phoneNumber):
              PhoneNumberCode(phoneNumber: phoneNumber)
          }
        }
    }
    .animation(.snappy, value: navigation.path)
  }
}
