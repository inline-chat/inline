#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
#endif
import SwiftUI
import UIKit

struct ProviderSignInProgress: View {
  let provider: ProviderSignInProvider

  #if IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject private var coordinator: OnboardingGalleryProviderState
  #else
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  #endif
  @State private var attemptID = UUID()
  @State private var openingBrowser = false
  @State private var signInURL: URL?

  var body: some View {
    OnboardingFormPage {
      VStack(spacing: 12) {
        OnboardingFormHeader(title: Text("Continue in your browser"), systemImage: "safari")

        Text(coordinator.errorMessage ?? statusDescription)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    } actions: {
      if coordinator.errorMessage != nil {
        Button("Try Again") {
          coordinator.clearError()
          signInURL = nil
          attemptID = UUID()
        }
        .buttonStyle(OnboardingFormButtonStyle())
      } else {
        Button {
          Task { await openSignInURL() }
        } label: {
          HStack(spacing: 8) {
            if isBusy {
              ProgressView()
            }
            Text(buttonTitle)
          }
        }
        .buttonStyle(OnboardingFormButtonStyle())
        .disabled(isBusy)
      }
    }
    .task(id: attemptID) {
      await start()
    }
    .onDisappear {
      #if !IOS_ONBOARDING_GALLERY_APP
      coordinator.cancelPendingAttempt()
      #endif
    }
  }

  private var isBusy: Bool {
    openingBrowser || coordinator.isRedeeming || signInURL == nil
  }

  private var statusDescription: String {
    if coordinator.isRedeeming { return "Finishing sign-in…" }
    if openingBrowser || signInURL == nil { return "Opening \(providerName) Sign-In…" }
    return "Complete \(providerName) Sign-In in your browser."
  }

  private var buttonTitle: String {
    if coordinator.isRedeeming { return "Finishing sign-in" }
    if openingBrowser || signInURL == nil { return "Opening \(providerName) Sign-In" }
    return "Open \(providerName) Sign-In"
  }

  private var providerName: String {
    provider == .google ? "Google" : "Apple"
  }

  private func start() async {
    #if IOS_ONBOARDING_GALLERY_APP
    // Keep the real page's waiting state without opening a browser or starting authentication.
    signInURL = URL(string: "https://example.invalid/onboarding-gallery")
    #else
    guard !openingBrowser, !coordinator.isRedeeming else { return }
    openingBrowser = true
    defer { openingBrowser = false }
    do {
      let url = try await coordinator.startURL(for: provider)
      signInURL = url
      guard await UIApplication.shared.open(url) else {
        coordinator.recordBrowserOpenFailure(APIError.invalidURL, for: url)
        return
      }
    } catch {
      // startURL records failures only when this is still the active attempt.
    }
    #endif
  }

  private func openSignInURL() async {
    #if IOS_ONBOARDING_GALLERY_APP
    coordinator.showBrowserPreviewNotice()
    #else
    guard let signInURL, !openingBrowser, !coordinator.isRedeeming else { return }
    openingBrowser = true
    defer { openingBrowser = false }
    guard await UIApplication.shared.open(signInURL) else {
      coordinator.recordBrowserOpenFailure(APIError.invalidURL, for: signInURL)
      return
    }
    #endif
  }
}
