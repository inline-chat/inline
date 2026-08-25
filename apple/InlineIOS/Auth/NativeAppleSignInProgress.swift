import InlineKit
import SwiftUI

struct NativeAppleSignInProgress: View {
  @EnvironmentObject private var navigation: OnboardingNavigation
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared

  var body: some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "apple.logo")
        .font(.system(size: 32, weight: .medium))

      if let error = coordinator.errorMessage {
        Text("Apple Sign-In couldn’t finish")
          .font(.onboardingIOSTitle.weight(.medium))
          .multilineTextAlignment(.center)

        Text(error)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 340)

        Button("Try Again") {
          coordinator.clearError()
          coordinator.cancelNativeAppleAuthorization()
          navigation.pop()
        }
        .buttonStyle(OnboardingAccentButtonStyle())
        .frame(maxWidth: 340)
      } else {
        Text("Finishing Apple Sign-In…")
          .font(.onboardingIOSTitle.weight(.medium))
          .multilineTextAlignment(.center)

        ProgressView()
          .controlSize(.large)
      }

      Spacer()
    }
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
  }
}
