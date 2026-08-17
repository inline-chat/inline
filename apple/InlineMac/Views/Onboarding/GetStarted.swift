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
        HStack(spacing: 10) {
          Image(systemName: "envelope")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .padding(.leading, 12)

          Text("Continue with Email")
            .frame(width: 170, alignment: .leading)
        }
      }
      InlineButton(size: .large, style: .secondary) {
        onboardingViewModel.navigate(to: .enterPhone)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: "checkmark.message")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .padding(.leading, 12)

          Text("Continue with Phone")
            .frame(width: 170, alignment: .leading)
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
      HStack(spacing: 10) {
        if provider == .google {
          Image("google-g")
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
        } else {
          Image(systemName: "apple.logo")
            .font(.system(size: 18, weight: .medium))
        }
        Group {
          if provider == .google {
            Text("Continue with Google")
          } else {
            Text("Continue with Apple")
          }
        }
        .frame(width: 170, alignment: .leading)
      }
      .padding(.leading, 12)
    }
  }
}

#Preview {
  OnboardingGetStarted()
    .environmentObject(MainWindowViewModel())
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
