import InlineKit
import SwiftUI

struct OnboardingGetStarted: View {
  @EnvironmentObject var onboardingViewModel: OnboardingViewModel

  var body: some View {
    VStack {
      Spacer()

      Text("Get started")
        .font(
          .custom(Fonts.RedHatDisplay, size: 24, relativeTo: .title)
        ).fontWeight(.bold)
        .padding(.bottom, 0.5)

      Text("Choose your sign in method")
        .font(.system(size: 16.0, weight: .regular))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      providerButton(.google)
        .padding(.top, 24)

      providerButton(.apple)

      InlineButton(size: .large, style: .secondary) {
        onboardingViewModel.navigate(to: .enterEmail)
      } label: {
        loginMethodLabel("Continue with Email") {
          Image(systemName: "envelope")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .frame(width: 18, height: 18)
        }
      }
      InlineButton(size: .large, style: .secondary) {
        onboardingViewModel.navigate(to: .enterPhone)
      } label: {
        loginMethodLabel("Continue with Phone") {
          Image(systemName: "checkmark.message")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .frame(width: 18, height: 18)
        }
      }

      Spacer()
    }
    .padding()
  }

  private func providerButton(_ provider: ProviderSignInProvider) -> some View {
    InlineButton(size: .large, style: .secondary) {
      onboardingViewModel.navigate(to: .provider(provider))
    } label: {
      loginMethodLabel(provider == .google ? "Continue with Google" : "Continue with Apple") {
        if provider == .google {
          Image("google-g")
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
        } else {
          Image(systemName: "apple.logo")
            .font(.system(size: 18, weight: .medium))
            .frame(width: 18, height: 18)
        }
      }
    }
  }

  private func loginMethodLabel<Icon: View>(
    _ title: LocalizedStringKey,
    @ViewBuilder icon: () -> Icon
  ) -> some View {
    ZStack(alignment: .leading) {
      icon()

      Text(title)
        .frame(maxWidth: .infinity, alignment: .center)
    }
    .frame(width: 220)
  }
}

#Preview {
  OnboardingGetStarted()
    .environmentObject(MainWindowViewModel())
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
