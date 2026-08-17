import AppKit
import InlineKit
import SwiftUI

struct OnboardingProviderSignIn: View {
  let provider: ProviderSignInProvider

  @EnvironmentObject private var onboardingViewModel: OnboardingViewModel
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  @State private var attemptID = UUID()
  @State private var openingBrowser = false

  var body: some View {
    VStack(spacing: 16) {
      Spacer()

      providerIcon

      Text("Sign in with \(providerName)")
        .font(.custom(Fonts.RedHatDisplay, size: 24, relativeTo: .title).bold())

      if let error = coordinator.errorMessage {
        Text(error)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(width: 320)

        InlineButton(size: .large, style: .primary) {
          coordinator.clearError()
          attemptID = UUID()
        } label: {
          Text("Try Again")
            .frame(width: 170)
        }
      } else {
        Text("Continue in your browser, then return to Inline.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        ProgressView()
          .controlSize(.small)
          .padding(.top, 4)
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

  @ViewBuilder
  private var providerIcon: some View {
    if provider == .google {
      Image("google-g")
        .resizable()
        .scaledToFit()
        .frame(width: 44, height: 44)
    } else {
      Image(systemName: "apple.logo")
        .font(.system(size: 44, weight: .medium))
    }
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
      guard NSWorkspace.shared.open(url) else { throw APIError.invalidURL }
    } catch {
      coordinator.recordStartFailure(error)
    }
  }
}
