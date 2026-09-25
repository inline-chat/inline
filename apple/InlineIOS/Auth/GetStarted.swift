#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
#endif
import InlineUI
import SwiftUI

struct GetStarted: View {
  var body: some View {
    VStack {
      Spacer()

      GetStartedHeader()
      SignInMethods()
        .padding(.top, 24)

      Spacer()
    }
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
  }
}

private struct GetStartedHeader: View {
  var body: some View {
    VStack(spacing: 4) {
      Text("Get started")
        .font(.onboardingIOSTitle.weight(.medium))

      Text("Choose your sign in method")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
  }
}

private struct SignInMethods: View {
  @EnvironmentObject private var nav: OnboardingNavigation

  @ViewBuilder
  var body: some View {
    if #available(iOS 26.0, *) {
      GlassEffectContainer(spacing: 0) {
        buttons
      }
    } else {
      buttons
    }
  }

  private var buttons: some View {
    VStack(spacing: 8) {
      Button {
        nav.push(.provider(.google))
      } label: {
        loginMethodLabel("Continue with Google") {
          Image("google-g")
            .resizable()
            .scaledToFit()
            .scaledFrame(width: 18, height: 18)
        }
      }
      .buttonStyle(SimpleWhiteButtonStyle())

      Button {
        nav.push(.email())
      } label: {
        loginMethodLabel("Continue with Email") {
          Image(systemName: "envelope.fill")
            .scaledFont(size: 16)
            .foregroundStyle(.black)
            .scaledFrame(width: 18, height: 18)
        }
      }
      .buttonStyle(SimpleWhiteButtonStyle())

      Button {
        nav.push(.phoneNumber())
      } label: {
        loginMethodLabel("Continue with Phone") {
          Image(systemName: "checkmark.message.fill")
            .scaledFont(size: 16)
            .foregroundStyle(.black)
            .scaledFrame(width: 18, height: 18)
        }
      }
      .buttonStyle(SimpleWhiteButtonStyle())

      NativeAppleSignInButton(navigation: nav) {
        loginMethodLabel("Continue with Apple") {
          Image(systemName: "apple.logo")
            .scaledFont(size: 18, weight: .medium)
            .scaledFrame(width: 18, height: 18)
            .accessibilityHidden(true)
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
    .padding(.horizontal, 40)
    .frame(maxWidth: .infinity)
  }
}

#Preview("Get Started - Light Mode") {
  NavigationStack {
    GetStarted()
      .preferredColorScheme(.light)
      .environmentObject(OnboardingNavigation())
  }
}

#Preview("Get Started - Dark Mode") {
  NavigationStack {
    GetStarted()
      .preferredColorScheme(.dark)
      .environmentObject(OnboardingNavigation())
  }
}
