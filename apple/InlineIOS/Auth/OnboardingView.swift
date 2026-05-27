import InlineKit
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
            case let .code(email, challengeToken, inviteCode):
              Code(email: email, challengeToken: challengeToken, inviteCode: inviteCode)
            case let .inviteCodeForEmail(email, challengeToken):
              InviteCode(destination: .email(email: email, challengeToken: challengeToken))
            case let .inviteCodeForPhone(phoneNumber):
              InviteCode(destination: .phone(phoneNumber: phoneNumber))
            case .profile:
              Profile()
            case .welcome:
              Welcome()
            case .main:
              HomeView()
            case let .phoneNumber(prevPhoneNumber):
              PhoneNumber(prevPhoneNumber: prevPhoneNumber)
            case let .phoneNumberCode(phoneNumber, inviteCode):
              PhoneNumberCode(phoneNumber: phoneNumber, inviteCode: inviteCode)
          }
        }
    }
    .animation(.snappy, value: navigation.path)
  }
}

#Preview("OnboardingView - Light Mode") {
  OnboardingView()
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("OnboardingView - Dark Mode") {
  OnboardingView()
    .preferredColorScheme(.dark)
    .environmentObject(OnboardingNavigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("OnboardingView - Email Step") {
  @Previewable @State var navigation = OnboardingNavigation()

  OnboardingView()
    .preferredColorScheme(.light)
    .environmentObject(navigation)
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
    .onAppear {
      navigation.push(.email())
    }
}

#Preview("OnboardingView - Phone Step") {
  @Previewable @State var navigation = OnboardingNavigation()

  OnboardingView()
    .preferredColorScheme(.light)
    .environmentObject(navigation)
    .environmentObject(ApiClient.shared)
    .environmentObject(UserData())
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
    .onAppear {
      navigation.push(.phoneNumber())
    }
}
