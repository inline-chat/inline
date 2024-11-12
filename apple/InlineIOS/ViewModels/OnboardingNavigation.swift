import SwiftUI

enum OnboardingStep: Identifiable, Hashable {
  case welcome
  case email(prevEmail: String? = nil)
  case code(email: String)
  case profile

  var id: String {
    switch self {
    case .welcome: return "welcome"
    case .email(let prevEmail): return "email-\(prevEmail ?? "")"
    case .code(let email): return "code-\(email)"
    case .profile: return "profile"
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
