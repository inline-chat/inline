import AuthenticationServices
#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
#endif
import SwiftUI
import UIKit

struct NativeAppleSignInButton<Label: View>: View {
  #if IOS_ONBOARDING_GALLERY_APP
  @EnvironmentObject private var coordinator: OnboardingGalleryProviderState
  #else
  @ObservedObject private var coordinator = ProviderSignInCoordinator.shared
  #endif
  @StateObject private var authorization: NativeAppleAuthorizationCoordinator
  private let label: Label

  init(navigation: OnboardingNavigation, @ViewBuilder label: () -> Label) {
    #if IOS_ONBOARDING_GALLERY_APP
    _authorization = StateObject(wrappedValue: NativeAppleAuthorizationCoordinator(navigation: navigation))
    #else
    _authorization = StateObject(wrappedValue: NativeAppleAuthorizationCoordinator(
      navigation: navigation,
      coordinator: .shared
    ))
    #endif
    self.label = label()
  }

  var body: some View {
    Button(action: authorization.begin) {
      label
        .opacity(authorization.isPreparing ? 0 : 1)
        .overlay {
          if authorization.isPreparing {
            ProgressView()
          }
        }
    }
    .buttonStyle(SimpleWhiteButtonStyle())
    .disabled(coordinator.isRedeeming || authorization.isBusy)
    .accessibilityLabel("Continue with Apple")
    .background(NativeAppleAuthorizationAnchor(authorization: authorization))
  }
}

private struct NativeAppleAuthorizationAnchor: UIViewRepresentable {
  let authorization: NativeAppleAuthorizationCoordinator

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    authorization.presentationView = view
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    authorization.presentationView = view
  }
}

#if IOS_ONBOARDING_GALLERY_APP
@MainActor
private final class NativeAppleAuthorizationCoordinator: ObservableObject {
  let isPreparing = false
  let isBusy = false
  weak var presentationView: UIView?
  private let navigation: OnboardingNavigation

  init(navigation: OnboardingNavigation) {
    self.navigation = navigation
  }

  func begin() {
    navigation.push(.nativeAppleProgress)
  }
}
#else
@MainActor
private final class NativeAppleAuthorizationCoordinator: NSObject, ObservableObject,
  ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  @Published private(set) var isPreparing = false
  @Published private var authorizationController: ASAuthorizationController?
  weak var presentationView: UIView?

  private let navigation: OnboardingNavigation
  private let coordinator: ProviderSignInCoordinator

  var isBusy: Bool {
    isPreparing || authorizationController != nil
  }

  init(navigation: OnboardingNavigation, coordinator: ProviderSignInCoordinator) {
    self.navigation = navigation
    self.coordinator = coordinator
    super.init()
  }

  func begin() {
    guard !isBusy, !coordinator.isRedeeming else { return }
    isPreparing = true

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let preparation = try await coordinator.prepareNativeAppleAuthorization()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.state = preparation.state
        request.nonce = preparation.nonce
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        authorizationController = controller
        isPreparing = false
        controller.performRequests()
      } catch is CancellationError {
        isPreparing = false
      } catch {
        isPreparing = false
        handleFailure(error)
      }
    }
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    authorizationController = nil
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
      handleFailure(APIError.invalidResponse)
      return
    }
    handleAuthorization(credential)
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    authorizationController = nil
    let nsError = error as NSError
    if nsError.domain == ASAuthorizationError.errorDomain,
       nsError.code == ASAuthorizationError.canceled.rawValue {
      coordinator.cancelNativeAppleAuthorization()
    } else {
      handleFailure(error)
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    if let window = presentationView?.window { return window }
    return UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first ?? UIWindow()
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
#endif
