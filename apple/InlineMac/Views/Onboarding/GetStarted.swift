import AppKit
import InlineKit
import SwiftUI

struct OnboardingGetStarted: View {
  @EnvironmentObject var windowViewModel: MainWindowViewModel
  @EnvironmentObject var onboardingViewModel: OnboardingViewModel
  @ObservedObject private var providerSignIn = ProviderSignInCoordinator.shared
  @State private var startingProvider: ProviderSignInProvider?
  @State private var providerError: String?

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

      if providerSignIn.isRedeeming || startingProvider != nil {
        ProgressView()
          .controlSize(.small)
          .padding(.top, 4)
      }

      if let providerError = providerError ?? providerSignIn.errorMessage {
        Text(providerError)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .frame(width: 280)
          .padding(.top, 4)
      }

      Spacer()
    }
    .padding()
    .onChange(of: providerSignIn.completion?.id) { _, _ in
      guard let completion = providerSignIn.completion else { return }
      AppSettings.shared.resolveSidebarModeForAccount(createdAt: completion.userCreatedAt)
      onboardingViewModel.navigateAfterLogin(pendingSetup: completion.pendingSetup)
    }
  }

  private func providerButton(_ provider: ProviderSignInProvider) -> some View {
    InlineButton(size: .large, style: .secondary) {
      start(provider)
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
    .disabled(startingProvider != nil || providerSignIn.isRedeeming)
  }

  private func start(_ provider: ProviderSignInProvider) {
    providerError = nil
    providerSignIn.clearError()
    startingProvider = provider
    Task {
      do {
        let url = try await providerSignIn.startURL(for: provider)
        guard NSWorkspace.shared.open(url) else { throw APIError.invalidURL }
      } catch {
        providerSignIn.cancelPendingAttempt()
        providerError = error.localizedDescription
      }
      startingProvider = nil
    }
  }
}

#Preview {
  OnboardingGetStarted()
    .environmentObject(MainWindowViewModel())
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
