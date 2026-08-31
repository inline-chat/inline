#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
#endif
import SwiftUI

struct NativeAppleSignInProgress: View {
  @EnvironmentObject private var navigation: OnboardingNavigation
  #if IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject private var coordinator: OnboardingGalleryProviderState
  #else
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  #endif

  var body: some View {
    OnboardingFormPage {
      if let error = coordinator.errorMessage {
        VStack(spacing: 12) {
          OnboardingFormHeader(title: Text("Apple Sign-In couldn’t finish"), systemImage: "apple.logo")

          Text(error)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      } else {
        OnboardingFormHeader(title: Text("Finishing Apple Sign-In…"), systemImage: "apple.logo")

        ProgressView()
          .controlSize(.large)
      }
    } actions: {
      if coordinator.errorMessage != nil {
        Button("Try Again") {
          coordinator.clearError()
          #if !IOS_ONBOARDING_GALLERY_APP
          coordinator.cancelNativeAppleAuthorization()
          #endif
          navigation.pop()
        }
        .buttonStyle(OnboardingFormButtonStyle())
      }
    }
  }
}
