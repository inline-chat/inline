import AuthenticationServices
import InlineKit
import SwiftUI
import UIKit

struct NativeAppleSignInButton: View {
  @EnvironmentObject private var navigation: OnboardingNavigation
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  @State private var isPreparing = false

  var body: some View {
    ZStack {
      NativeAppleAuthorizationButton(
        style: colorScheme == .dark ? .white : .whiteOutline,
        isEnabled: !coordinator.isRedeeming,
        prepare: coordinator.prepareNativeAppleAuthorization,
        onPreparingChanged: { isPreparing = $0 },
        onAuthorized: handleAuthorization,
        onCancelled: coordinator.cancelNativeAppleAuthorization,
        onFailure: handleFailure
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .id(colorScheme)

      if isPreparing {
        ProgressView()
          .tint(.black)
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 52)
  }

  private func handleAuthorization(_ credential: ASAuthorizationAppleIDCredential) {
    let profile = NativeAppleProfileCache.profile(for: credential)
    navigation.push(.nativeAppleProgress)
    Task {
      let serverAcceptedProfile = await coordinator.completeNativeAppleAuthorization(
        state: credential.state,
        authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
        identityToken: credential.identityToken.flatMap { String(data: $0, encoding: .utf8) },
        firstName: profile.firstName,
        lastName: profile.lastName
      )
      if serverAcceptedProfile {
        NativeAppleProfileCache.clear(forUser: credential.user)
      }
    }
  }

  private func handleFailure(_ error: Error) {
    coordinator.recordNativeAppleAuthorizationFailure(error)
    navigation.push(.nativeAppleProgress)
  }
}

private struct NativeAppleAuthorizationButton: UIViewRepresentable {
  let style: ASAuthorizationAppleIDButton.Style
  let isEnabled: Bool
  let prepare: @MainActor () async throws -> NativeAppleAuthorizationRequest
  let onPreparingChanged: @MainActor (Bool) -> Void
  let onAuthorized: @MainActor (ASAuthorizationAppleIDCredential) -> Void
  let onCancelled: @MainActor () -> Void
  let onFailure: @MainActor (Error) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
    let button = ASAuthorizationAppleIDButton(type: .continue, style: style)
    button.cornerRadius = 26
    button.addTarget(context.coordinator, action: #selector(Coordinator.begin), for: .touchUpInside)
    context.coordinator.button = button
    return button
  }

  func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
    context.coordinator.parent = self
    context.coordinator.updateButtonState()
  }

  @MainActor
  final class Coordinator: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    var parent: NativeAppleAuthorizationButton
    weak var button: ASAuthorizationAppleIDButton?
    var isPreparing = false
    private var authorizationController: ASAuthorizationController?

    init(parent: NativeAppleAuthorizationButton) {
      self.parent = parent
    }

    @objc func begin() {
      guard !isPreparing, authorizationController == nil else { return }
      isPreparing = true
      updateButtonState()
      parent.onPreparingChanged(true)

      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          let preparation = try await parent.prepare()
          let request = ASAuthorizationAppleIDProvider().createRequest()
          request.requestedScopes = [.fullName, .email]
          request.state = preparation.state
          request.nonce = preparation.nonce
          let controller = ASAuthorizationController(authorizationRequests: [request])
          controller.delegate = self
          controller.presentationContextProvider = self
          authorizationController = controller
          finishPreparing()
          controller.performRequests()
        } catch is CancellationError {
          finishPreparing()
        } catch {
          finishPreparing()
          parent.onFailure(error)
        }
      }
    }

    func authorizationController(
      controller: ASAuthorizationController,
      didCompleteWithAuthorization authorization: ASAuthorization
    ) {
      authorizationController = nil
      guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
        updateButtonState()
        parent.onFailure(APIError.invalidResponse)
        return
      }
      parent.onAuthorized(credential)
    }

    func authorizationController(
      controller: ASAuthorizationController,
      didCompleteWithError error: Error
    ) {
      authorizationController = nil
      updateButtonState()
      let nsError = error as NSError
      if nsError.domain == ASAuthorizationError.errorDomain,
         nsError.code == ASAuthorizationError.canceled.rawValue {
        parent.onCancelled()
      } else {
        parent.onFailure(error)
      }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
      if let window = button?.window { return window }
      return UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first ?? UIWindow()
    }

    private func finishPreparing() {
      isPreparing = false
      updateButtonState()
      parent.onPreparingChanged(false)
    }

    func updateButtonState() {
      button?.isEnabled = parent.isEnabled && !isPreparing && authorizationController == nil
    }
  }
}

private enum NativeAppleProfileCache {
  private struct Profile: Codable {
    let user: String
    let firstName: String?
    let lastName: String?
  }

  private static let key = "auth.native-apple.pending-profile"

  static func profile(for credential: ASAuthorizationAppleIDCredential) -> (firstName: String?, lastName: String?) {
    let firstName = clean(credential.fullName?.givenName)
    let lastName = clean(credential.fullName?.familyName)
    if firstName != nil || lastName != nil {
      let profile = Profile(user: credential.user, firstName: firstName, lastName: lastName)
      if let data = try? JSONEncoder().encode(profile) {
        UserDefaults.standard.set(data, forKey: key)
      }
      return (firstName, lastName)
    }
    guard
      let data = UserDefaults.standard.data(forKey: key),
      let cached = try? JSONDecoder().decode(Profile.self, from: data),
      cached.user == credential.user
    else {
      return (nil, nil)
    }
    return (cached.firstName, cached.lastName)
  }

  static func clear(forUser user: String) {
    guard
      let data = UserDefaults.standard.data(forKey: key),
      let cached = try? JSONDecoder().decode(Profile.self, from: data),
      cached.user == user
    else { return }
    UserDefaults.standard.removeObject(forKey: key)
  }

  private static func clean(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}
