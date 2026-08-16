import InlineKit
import SwiftUI
import UIKit

struct Welcome: View {
  @State private var isVisible = false
  @EnvironmentObject var nav: OnboardingNavigation
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @ObservedObject private var providerSignIn = ProviderSignInCoordinator.shared
  @State private var startingProvider: ProviderSignInProvider?
  @State private var providerError: String?

  var animation: Animation {
    .easeOut(duration: 0.25)
  }

  var body: some View {
    VStack {
      Spacer()

      Image("AppIconSmall")
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : -30)
        .animation(animation.delay(0.05), value: isVisible)

      Text("Welcome to Inline")
        .font(.largeTitle)
        .fontWeight(.bold)
        .padding(.bottom, 0.5)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(animation.delay(0.2), value: isVisible)

      Text("A fresh chatting experience")
        .font(.system(size: 20.0, weight: .regular))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(animation.delay(0.25), value: isVisible)

      Spacer()

      VStack(spacing: 8) {
        providerButton(.google)
        providerButton(.apple)

        Button {
          nav.push(.email())
        } label: {
          Text("Continue with Email").padding(.horizontal, 40)
        }
        .buttonStyle(SimpleButtonStyle())
        .frame(maxWidth: .infinity)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(animation.delay(0.3), value: isVisible)

        Button("Continue with Phone") {
          nav.push(.phoneNumber())
        }
        .buttonStyle(SimpleWhiteButtonStyle())
        .frame(maxWidth: .infinity)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(animation.delay(0.35), value: isVisible)

        if providerSignIn.isRedeeming || startingProvider != nil {
          ProgressView()
            .padding(.top, 4)
        }

        if let providerError = providerError ?? providerSignIn.errorMessage {
          Text(providerError)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
        }
      }
      // .padding(.horizontal, OnboardingUtils.shared.hPadding)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)

      Footer()
        .opacity(isVisible ? 1 : 0)
        .animation(animation.delay(0.45), value: isVisible)
    }
    .padding()
    .frame(minHeight: 400)
    .onAppear {
      isVisible = true
    }
    .onChange(of: providerSignIn.completion?.id) { _, _ in
      guard let completion = providerSignIn.completion else { return }
      if completion.pendingSetup {
        nav.push(.profile)
      } else {
        nav.reset()
        mainViewRouter.setRoute(route: .main)
      }
    }
    .navigationBarBackButtonHidden()
  }

  @ViewBuilder
  private func providerButton(_ provider: ProviderSignInProvider) -> some View {
    Button {
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
        if provider == .google {
          Text("Continue with Google")
        } else {
          Text("Continue with Apple")
        }
      }
      .padding(.horizontal, 40)
    }
    .buttonStyle(SimpleWhiteButtonStyle())
    .frame(maxWidth: .infinity)
    .disabled(startingProvider != nil || providerSignIn.isRedeeming)
    .opacity(isVisible ? 1 : 0)
    .offset(y: isVisible ? 0 : 20)
    .animation(animation.delay(provider == .google ? 0.3 : 0.33), value: isVisible)
  }

  private func start(_ provider: ProviderSignInProvider) {
    providerError = nil
    providerSignIn.clearError()
    startingProvider = provider
    Task {
      do {
        let url = try await providerSignIn.startURL(for: provider)
        guard await UIApplication.shared.open(url) else {
          throw APIError.invalidURL
        }
      } catch {
        providerSignIn.cancelPendingAttempt()
        providerError = error.localizedDescription
      }
      startingProvider = nil
    }
  }

  struct Footer: View {
    var body: some View {
      HStack(alignment: .bottom) {
        Spacer()

        Text(
          "By continuing, you acknowledge that you understand and agree to the [Terms of Service](https://inline.chat/legal/terms) and [Privacy Policy](https://inline.chat/legal/privacy)."
        )
        .font(.footnote)
        .tint(Color.secondary)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)

        Spacer()
      }
      // .overlay(alignment: .bottomLeading) {
      //   Text("[inline.chat](https://inline.chat)")
      //     .font(.footnote)
      //     .tint(Color.secondary)
      // }
    }
  }
}

#Preview("Welcome - Light Mode") {
  Welcome()
    .preferredColorScheme(.light)
    .environmentObject(OnboardingNavigation())
}

#Preview("Welcome - Dark Mode") {
  Welcome()
    .preferredColorScheme(.dark)
    .environmentObject(OnboardingNavigation())
}

#Preview("Welcome - Interactive") {
  NavigationView {
    Welcome()
      .environmentObject(OnboardingNavigation())
  }
}
