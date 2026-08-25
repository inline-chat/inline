import InlineKit
import SwiftUI

struct OnboardingView: View {
  @EnvironmentObject private var navigation: OnboardingNavigation
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @ObservedObject private var providerSignIn = ProviderSignInCoordinator.shared

  var body: some View {
    NavigationStack(path: $navigation.path) {
      Welcome()
        .navigationDestination(for: OnboardingStep.self) { step in
          switch step {
            case .getStarted:
              GetStarted()
            case let .email(prevEmail):
              Email(prevEmail: prevEmail)
            case let .code(email, challengeToken, inviteCode):
              Code(email: email, challengeToken: challengeToken, inviteCode: inviteCode)
            case let .inviteCodeForEmail(email, challengeToken):
              InviteCode(destination: .email(email: email, challengeToken: challengeToken))
            case let .inviteCodeForPhone(phoneNumber):
              InviteCode(destination: .phone(phoneNumber: phoneNumber))
            case let .profile(userId):
              Profile(userId: userId)
                .id(userId)
            case let .username(userId):
              OnboardingUsername(userId: userId)
                .id(userId)
            case .welcome:
              Welcome()
            case .main:
              EmptyView()
            case let .phoneNumber(prevPhoneNumber):
              PhoneNumber(prevPhoneNumber: prevPhoneNumber)
            case let .phoneNumberCode(phoneNumber, inviteCode):
              PhoneNumberCode(phoneNumber: phoneNumber, inviteCode: inviteCode)
            case let .provider(provider):
              ProviderSignInProgress(provider: provider)
            case .nativeAppleProgress:
              NativeAppleSignInProgress()
            case .nativeAppleInvite:
              InviteCode(destination: .nativeApple)
          }
        }
    }
    .animation(.snappy, value: navigation.path)
    .onChange(of: providerSignIn.completion?.id, initial: true) { _, completionID in
      guard let completionID,
        let completion = providerSignIn.consumeCompletion(id: completionID)
      else { return }
      if completion.pendingSetup {
        navigation.push(.profile(userId: completion.userId))
      } else {
        navigation.reset()
        mainViewRouter.setRoute(route: .main)
      }
    }
    .onChange(of: providerSignIn.nativeAppleInviteRequest?.id, initial: true) { _, requestID in
      guard let requestID,
        providerSignIn.consumeNativeAppleInviteRequest(id: requestID) != nil
      else { return }
      navigation.push(.nativeAppleInvite)
    }
    .onDisappear {
      Task { await InlineProtocolNativeLogin.shared.cancel() }
    }
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
