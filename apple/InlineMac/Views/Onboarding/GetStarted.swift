import SwiftUI

struct OnboardingGetStarted: View {
  @EnvironmentObject var windowViewModel: MainWindowViewModel
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
      .padding(.top, 24)

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
}

#Preview {
  OnboardingGetStarted()
    .environmentObject(MainWindowViewModel())
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
