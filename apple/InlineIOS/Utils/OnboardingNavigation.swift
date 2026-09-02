import SwiftUI
#if !IOS_ONBOARDING_GALLERY_APP
import InlineKit
#endif

enum OnboardingStep: Identifiable, Hashable {
  case welcome
  case getStarted
  case email(prevEmail: String? = nil)
  case code(email: String, challengeToken: String? = nil, inviteCode: String? = nil)
  case inviteCodeForEmail(email: String, challengeToken: String? = nil)
  case inviteCodeForPhone(phoneNumber: String)
  case profile(userId: Int64)
  case username(userId: Int64)
  case main
  case phoneNumber(prevPhoneNumber: String? = nil)
  case phoneNumberCode(phoneNumber: String, inviteCode: String? = nil)
  case provider(ProviderSignInProvider)
  case nativeAppleProgress
  case nativeAppleInvite

  var id: String {
    switch self {
      case .welcome: "welcome"
      case .getStarted: "getStarted"
      case let .email(prevEmail): "email-\(prevEmail ?? "")"
      case let .code(email, challengeToken, inviteCode): "code-\(email)-\(challengeToken ?? "")-\(inviteCode ?? "")"
      case let .inviteCodeForEmail(email, challengeToken): "inviteCodeForEmail-\(email)-\(challengeToken ?? "")"
      case let .inviteCodeForPhone(phoneNumber): "inviteCodeForPhone-\(phoneNumber)"
      case let .profile(userId): "profile-\(userId)"
      case let .username(userId): "username-\(userId)"
      case .main: "main"
      case let .phoneNumber(prevPhoneNumber): "phoneNumber-\(prevPhoneNumber ?? "")"
      case let .phoneNumberCode(phoneNumber, inviteCode): "phoneNumberCode-\(phoneNumber)-\(inviteCode ?? "")"
      case let .provider(provider): "provider-\(provider.rawValue)"
      case .nativeAppleProgress: "nativeAppleProgress"
      case .nativeAppleInvite: "nativeAppleInvite"
    }
  }
}

@MainActor
class OnboardingNavigation: ObservableObject {
  @Published var path: [OnboardingStep] = [.welcome]
  @Published var email: String = ""
  @Published var existingUser: Bool? = nil
  @Published var profileName = ""
  @Published var profileUsername = ""
  @Published var profilePhoto: OnboardingProfilePhoto?
  private var profileDraftUserId: Int64?

  var canGoBack: Bool {
    path.count > 1
  }

  func push(_ step: OnboardingStep) {
    #if IOS_ONBOARDING_GALLERY_APP
    guard path.last != step else { return }
    #endif
    path.append(step)
  }

  func pop() {
    guard canGoBack else { return }
    path.removeLast()
  }

  func prepareProfileDraft(for userId: Int64) {
    guard profileDraftUserId != userId else { return }
    profileDraftUserId = userId
    profileName = ""
    profileUsername = ""
    profilePhoto = nil
  }

  func reset() {
    path = [.welcome]
    email = ""
    existingUser = nil
    profileDraftUserId = nil
    profileName = ""
    profileUsername = ""
    profilePhoto = nil
  }
}
