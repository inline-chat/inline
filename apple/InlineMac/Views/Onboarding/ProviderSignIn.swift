import AppKit
import AuthenticationServices
import InlineKit
import SwiftUI

struct OnboardingProviderSignIn: View {
  let provider: ProviderSignInProvider

  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  @State private var attemptID = UUID()
  @State private var openingBrowser = false
  @State private var signInURL: URL?
  @StateObject private var webAuthentication = MacProviderWebAuthentication()

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
    .onDisappear {
      webAuthentication.cancel()
      coordinator.cancelPendingAttempt()
    }
  }

  private var isBusy: Bool {
    openingBrowser || coordinator.isRedeeming || signInURL == nil
  }

  private var statusDescription: LocalizedStringResource {
    if coordinator.isRedeeming { return "Finishing sign-in…" }
    if openingBrowser || signInURL == nil {
      return provider == .google ? "Opening Google Sign-In…" : "Opening Apple Sign-In…"
    }
    return provider == .google
      ? "Complete Google Sign-In in your browser."
      : "Complete Apple Sign-In in your browser."
  }

  private var buttonTitle: LocalizedStringResource {
    if coordinator.isRedeeming { return "Finishing sign-in" }
    if openingBrowser || signInURL == nil {
      return provider == .google ? "Opening Google Sign-In" : "Opening Apple Sign-In"
    }
    return provider == .google ? "Open Google Sign-In" : "Open Apple Sign-In"
  }

  private func start() async {
    guard !openingBrowser, !coordinator.isRedeeming else { return }
    openingBrowser = true
    defer { openingBrowser = false }
    do {
      let url = try await coordinator.startURL(for: provider)
      signInURL = url
      open(url)
    } catch {
      // startURL records failures only when this is still the active attempt.
    }
  }

  private func openSignInURL() async {
    guard let signInURL, !openingBrowser, !coordinator.isRedeeming else { return }
    openingBrowser = true
    defer { openingBrowser = false }
    open(signInURL)
  }

  private func open(_ url: URL) {
    if provider == .google {
      guard NSWorkspace.shared.open(url) else {
        coordinator.recordBrowserOpenFailure(APIError.invalidURL, for: url)
        return
      }
      return
    }

    let started = webAuthentication.start(
      url: url,
      callbackScheme: InlineDeepLink.configuredScheme,
      onCallback: { callback in
        Task { await coordinator.handleCallback(callback) }
      },
      onUnableToPresent: { _ in
        guard NSWorkspace.shared.open(url) else {
          coordinator.recordBrowserOpenFailure(APIError.invalidURL, for: url)
          return
        }
      }
    )
    if !started, !NSWorkspace.shared.open(url) {
      coordinator.recordBrowserOpenFailure(APIError.invalidURL, for: url)
    }
  }
}

@MainActor
private final class MacProviderWebAuthentication: NSObject, ObservableObject,
  ASWebAuthenticationPresentationContextProviding
{
  private var session: ASWebAuthenticationSession?

  func start(
    url: URL,
    callbackScheme: String,
    onCallback: @escaping @MainActor (URL) -> Void,
    onUnableToPresent: @escaping @MainActor (Error) -> Void
  ) -> Bool {
    session?.cancel()
    let session = ASWebAuthenticationSession(
      url: url,
      callbackURLScheme: callbackScheme
    ) { [weak self] callback, error in
      Task { @MainActor in
        self?.session = nil
        if let callback {
          onCallback(callback)
          return
        }
        let nsError = error as NSError?
        if nsError?.domain == ASWebAuthenticationSessionError.errorDomain,
           nsError?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
        {
          return
        }
        if let error { onUnableToPresent(error) }
      }
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    self.session = session
    if session.start() { return true }
    self.session = nil
    return false
  }

  func cancel() {
    session?.cancel()
    session = nil
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
  }
}
