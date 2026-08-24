import InlineKit
import SwiftUI

struct Welcome: View {
  @State private var isVisible = false
  @EnvironmentObject var nav: OnboardingNavigation

  var animation: Animation {
    .easeOut(duration: 0.25)
  }

  var body: some View {
    VStack {
      Spacer()

      VStack(alignment: .leading, spacing: 18) {
        Image(onboardingAppIconName)
          .resizable()
          .scaledToFit()
          .frame(width: 64, height: 64)
          .opacity(isVisible ? 1 : 0)
          .offset(y: isVisible ? 0 : -30)
          .animation(animation.delay(0.05), value: isVisible)

        VStack(alignment: .leading, spacing: 4) {
          Text("Welcome to Inline")
            .font(.onboardingIOSTitle.weight(.medium))
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 20)
            .animation(animation.delay(0.2), value: isVisible)

          Text("A fast, tranquil, AI native work chat app")
            .font(.onboardingIOSTitle2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 20)
            .animation(animation.delay(0.25), value: isVisible)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, OnboardingUtils.shared.hPadding)

      Spacer()

      Button {
        nav.push(.getStarted)
      } label: {
        Text("Get Started").padding(.horizontal, 40)
      }
      .buttonStyle(OnboardingAccentButtonStyle())
      .frame(maxWidth: .infinity)
      .padding(.horizontal, OnboardingUtils.shared.hPadding)
      .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : 20)
      .animation(animation.delay(0.3), value: isVisible)

      Footer()
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .opacity(isVisible ? 1 : 0)
        .animation(animation.delay(0.45), value: isVisible)
    }
    .frame(minHeight: 400)
    .onAppear {
      isVisible = true
    }
    .navigationBarBackButtonHidden()
  }

  private var onboardingAppIconName: String {
    #if IOS_ONBOARDING_GALLERY_APP
    "AppIcon-384"
    #else
    "AppIconSmall"
    #endif
  }

  struct Footer: View {
    var body: some View {
      HStack(alignment: .bottom) {
        Spacer()

        Text(
          "By continuing, you acknowledge that you understand and agree to the [Terms of Service](https://inline.chat/legal/terms) and [Privacy Policy](https://inline.chat/legal/privacy)."
        )
        .font(.onboardingIOSFootnote)
        .tint(Color.secondary)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)

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
