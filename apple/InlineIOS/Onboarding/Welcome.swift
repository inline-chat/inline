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

      VStack(spacing: 12) {
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
    .navigationBarBackButtonHidden()
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
      // .overlay(alignment: .bottomLeading) {
      //   Text("[inline.chat](https://inline.chat)")
      //     .font(.footnote)
      //     .tint(Color.secondary)
      // }
    }
  }
}
