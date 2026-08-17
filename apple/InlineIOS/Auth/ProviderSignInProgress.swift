import InlineKit
import SwiftUI
import UIKit

struct ProviderSignInProgress: View {
  let provider: ProviderSignInProvider

  @EnvironmentObject private var navigation: OnboardingNavigation
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  @State private var attemptID = UUID()
  @State private var openingBrowser = false

  var body: some View {
    VStack(spacing: 16) {
      Spacer()

      providerIcon

      Text("Sign in with \(providerName)")
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)

      if let error = coordinator.errorMessage {
        Text(error)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 340)

        Button("Try Again") {
          coordinator.clearError()
          attemptID = UUID()
        }
        .buttonStyle(SimpleButtonStyle())
      } else {
        Text("Continue in your browser, then return to Inline.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        ProgressView()
          .controlSize(.large)
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
      if completion.pendingSetup {
        navigation.push(.profile)
      } else {
        navigation.reset()
        mainViewRouter.setRoute(route: .main)
      }
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
      guard await UIApplication.shared.open(url) else { throw APIError.invalidURL }
    } catch {
      coordinator.recordStartFailure(error)
    }
  }
}
