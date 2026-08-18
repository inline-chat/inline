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
  @State private var signInURL: URL?

  var body: some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "safari")
        .font(.system(size: 28, weight: .regular))
        .foregroundStyle(.secondary)

      Text("Continue in your browser")
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)

      if let error = coordinator.errorMessage {
        Text(error)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 340)

        Button("Try Again") {
          coordinator.clearError()
          signInURL = nil
          attemptID = UUID()
        }
        .buttonStyle(SimpleButtonStyle())
      } else {
        Text(statusDescription)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        Button {
          Task { await openSignInURL() }
        } label: {
          HStack(spacing: 8) {
            if isBusy {
              ProgressView()
                .tint(.white)
            }
            Text(buttonTitle)
          }
        }
        .buttonStyle(SimpleButtonStyle())
        .disabled(isBusy)
        .frame(maxWidth: 340)
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
      guard await UIApplication.shared.open(url) else { throw APIError.invalidURL }
    } catch {
      coordinator.recordStartFailure(error)
    }
  }

  private func openSignInURL() async {
    guard let signInURL, !openingBrowser, !coordinator.isRedeeming else { return }
    openingBrowser = true
    defer { openingBrowser = false }
    guard await UIApplication.shared.open(signInURL) else {
      coordinator.recordStartFailure(APIError.invalidURL)
      return
    }
  }
}
