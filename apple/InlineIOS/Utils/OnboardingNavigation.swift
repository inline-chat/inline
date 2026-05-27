import SwiftUI

enum OnboardingStep: Identifiable, Hashable {
  case welcome
  case email(prevEmail: String? = nil)
  case code(email: String, challengeToken: String? = nil, inviteCode: String? = nil)
  case inviteCodeForEmail(email: String, challengeToken: String? = nil)
  case inviteCodeForPhone(phoneNumber: String)
  case profile
  case main
  case phoneNumber(prevPhoneNumber: String? = nil)
  case phoneNumberCode(phoneNumber: String, inviteCode: String? = nil)

  var id: String {
    switch self {
      case .welcome: "welcome"
      case let .email(prevEmail): "email-\(prevEmail ?? "")"
      case let .code(email, challengeToken, inviteCode): "code-\(email)-\(challengeToken ?? "")-\(inviteCode ?? "")"
      case let .inviteCodeForEmail(email, challengeToken): "inviteCodeForEmail-\(email)-\(challengeToken ?? "")"
      case let .inviteCodeForPhone(phoneNumber): "inviteCodeForPhone-\(phoneNumber)"
      case .profile: "profile"
      case .main: "main"
      case let .phoneNumber(prevPhoneNumber): "phoneNumber-\(prevPhoneNumber ?? "")"
      case let .phoneNumberCode(phoneNumber, inviteCode): "phoneNumberCode-\(phoneNumber)-\(inviteCode ?? "")"
    }
  }
}

@MainActor
class OnboardingNavigation: ObservableObject {
  @Published var path: [OnboardingStep] = [.welcome]
  @Published var email: String = ""
  @Published var existingUser: Bool? = nil
  @Published var goingBack = false

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

  func reset() {
    path = [.welcome]
    email = ""
    existingUser = nil
    goingBack = false
  }
}
