import SwiftUI
import InlineKit

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
    }
  }
}

@MainActor
class OnboardingNavigation: ObservableObject {
  @Published var path: [OnboardingStep] = [.welcome]
  @Published var email: String = ""
  @Published var existingUser: Bool? = nil
  @Published var goingBack = false
  @Published var profileName = ""
  @Published var profileUsername = ""
  private var profileDraftUserId: Int64?

  var canGoBack: Bool {
    path.count > 1
  }

  func push(_ step: OnboardingStep) {
    withAnimation(.snappy) {
      path.append(step)
    }
  }

  func pop() {
    guard canGoBack else { return }
    withAnimation(.snappy) {
      goingBack = true
      path.removeLast()

      // Reset going back flag after animation
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(0.3))
        goingBack = false
      }
    }
  }

  func prepareProfileDraft(for userId: Int64) {
    guard profileDraftUserId != userId else { return }
    profileDraftUserId = userId
    profileName = ""
    profileUsername = ""
  }

  func reset() {
    path = [.welcome]
    email = ""
    existingUser = nil
    goingBack = false
    profileDraftUserId = nil
    profileName = ""
    profileUsername = ""
  }
}
