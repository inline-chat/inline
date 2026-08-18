import AppKit
import InlineKit
import SwiftUI

struct OnboardingProviderSignIn: View {
  let provider: ProviderSignInProvider

  @EnvironmentObject private var onboardingViewModel: OnboardingViewModel
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  @State private var attemptID = UUID()
  @State private var openingBrowser = false
  @State private var signInURL: URL?

  var body: some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "safari")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)

      Text("Continue in your browser")
        .font(.title2.weight(.semibold))

      if let error = coordinator.errorMessage {
        Text(error)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(width: 320)

        InlineButton(size: .large, style: .primary) {
          coordinator.clearError()
          signInURL = nil
          attemptID = UUID()
        } label: {
          Text("Try Again")
            .frame(width: 170)
        }
      } else {
        Text(statusDescription)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        InlineButton(size: .large, style: .primary) {
          Task { await openSignInURL() }
        } label: {
          HStack(spacing: 8) {
            if isBusy {
              ProgressView()
                .controlSize(.small)
            }
            Text(buttonTitle)
          }
          .frame(width: 210)
        }
        .disabled(isBusy)
      }

      Spacer()
    }
    .padding()
    .task(id: attemptID) {
      await start()
    }
    .onChange(of: coordinator.completion?.id) { _, _ in
      guard let completion = coordinator.completion else { return }
      AppSettings.shared.resolveSidebarModeForAccount(createdAt: completion.userCreatedAt)
      onboardingViewModel.navigateAfterLogin(pendingSetup: completion.pendingSetup)
    }
    .onDisappear {
      coordinator.cancelPendingAttempt()
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
    guard !openingBrowser, !coordinator.isRedeeming else { return }
    openingBrowser = true
    defer { openingBrowser = false }
    do {
      let url = try await coordinator.startURL(for: provider)
      signInURL = url
      guard NSWorkspace.shared.open(url) else { throw APIError.invalidURL }
    } catch {
      coordinator.recordStartFailure(error)
    }
  }

  private func openSignInURL() async {
    guard let signInURL, !openingBrowser, !coordinator.isRedeeming else { return }
    openingBrowser = true
    defer { openingBrowser = false }
    guard NSWorkspace.shared.open(signInURL) else {
      coordinator.recordStartFailure(APIError.invalidURL)
      return
    }
  }
}
