import SwiftUI

struct OnboardingWelcome: View {
  @EnvironmentObject var windowViewModel: MainWindowViewModel
  @EnvironmentObject var onboardingViewModel: OnboardingViewModel
  @State private var isVisible = false
  
  var animation: Animation {
    .easeOut(duration: 0.5)
  }

  var body: some View {
    VStack {
      Spacer()

      Image("AppIcon")
        .padding(.top, 30)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : -30)
        .animation(animation.delay(0.1), value: isVisible)

      Text("Welcome to Inline")
        .font(
          .custom(Fonts.RedHatDisplay, size: 32, relativeTo: .title)
        ).fontWeight(.bold)
        .padding(.bottom, 0.5)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(animation.delay(0.4), value: isVisible)

      Text("A fresh chatting experience")
        .font(.system(size: 20.0, weight: .regular))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : 20)
        .animation(animation.delay(0.5), value: isVisible)

      Spacer()

      InlineButton(size: .large, style: .primary) {
        onboardingViewModel.navigate(to: .enterEmail)
      } label: {
        Text("Get Started").padding(.horizontal, 40)
      }
      .padding(.bottom, 30)
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible ? 0 : 20)
      .animation(animation.delay(0.6), value: isVisible)

      Footer()
        .opacity(isVisible ? 1 : 0)
        .animation(animation.delay(0.9), value: isVisible)
    }
    .padding()
    .onAppear {
      isVisible = true
    }
  }

  struct Footer: View {
    var body: some View {
      HStack(alignment: .bottom) {
        Spacer()

        Text(
          "By continuing, you acknowledge that you understand and agree to the [Terms & Conditions](https://inline.chat/legal) and [Privacy Policy](https://inline.chat/legal)."
        )
        .font(.footnote)
        .tint(Color.secondary)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)

        Spacer()
      }
      .overlay(alignment: .bottomLeading) {
        Text("[inline.chat](https://inline.chat)")
          .font(.footnote)
          .tint(Color.secondary)
      }
    }
  }
}

#Preview {
  Onboarding()
    .environmentObject(MainWindowViewModel())
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
