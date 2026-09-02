import Foundation

enum OnboardingGalleryPage: String, CaseIterable, Identifiable {
  case welcome, getStarted
  case email, emailCode, emailInvite
  case phone, phoneCode, phoneInvite
  case google, nativeApple, appleInvite, browserApple
  case profile, username

  enum Section: String, CaseIterable, Identifiable {
    case introduction = "Introduction"
    case email = "Email"
    case phone = "Phone"
    case providers = "Google & Apple"
    case profile = "Profile"

    var id: String { rawValue }
  }

  var id: String { rawValue }

  var section: Section {
    switch self {
      case .welcome, .getStarted: .introduction
      case .email, .emailCode, .emailInvite: .email
      case .phone, .phoneCode, .phoneInvite: .phone
      case .google, .nativeApple, .appleInvite, .browserApple: .providers
      case .profile, .username: .profile
    }
  }

  var title: String {
    switch self {
      case .welcome: "Welcome"
      case .getStarted: "Sign-in methods"
      case .email: "Email address"
      case .emailCode: "Email verification"
      case .emailInvite: "Email invite code"
      case .phone: "Phone number"
      case .phoneCode: "Phone verification"
      case .phoneInvite: "Phone invite code"
      case .google: "Google sign-in"
      case .nativeApple: "Apple sign-in"
      case .appleInvite: "Apple invite code"
      case .browserApple: "Apple browser fallback"
      case .profile: "Your profile"
      case .username: "Username"
    }
  }

  var symbol: String {
    switch self {
      case .welcome: "hand.wave"
      case .getStarted: "arrow.right.circle"
      case .email: "at"
      case .emailCode, .phoneCode: "number.square"
      case .emailInvite, .phoneInvite, .appleInvite: "ticket"
      case .phone: "phone"
      case .google, .browserApple: "safari"
      case .nativeApple: "apple.logo"
      case .profile: "person.crop.circle"
      case .username: "at.circle"
    }
  }

  var sourceFile: String {
    switch self {
      case .welcome: "Welcome.swift"
      case .getStarted: "GetStarted.swift"
      case .email: "Email.swift"
      case .emailCode: "Code.swift"
      case .emailInvite, .phoneInvite, .appleInvite: "InviteCode.swift"
      case .phone: "PhoneNumber.swift"
      case .phoneCode: "PhoneNumberCode.swift"
      case .google, .browserApple: "ProviderSignInProgress.swift"
      case .nativeApple: "NativeAppleSignInProgress.swift"
      case .profile, .username: "Profile.swift"
    }
  }

  var viewName: String {
    self == .username ? "OnboardingUsername" : String(sourceFile.dropLast(".swift".count))
  }

  var hint: String {
    switch self {
      case .welcome: "Get Started opens the real sign-in method picker."
      case .getStarted: "Choose any method to explore its pages. Apple authorization is simulated."
      case .email: "Enter any email to preview verification. No email is sent or validated by a server."
      case .emailCode, .phoneCode: "Enter any six digits to continue to profile setup. No code is verified."
      case .emailInvite, .phoneInvite, .appleInvite: "Enter any eight letters or digits to continue. No invite is redeemed."
      case .phone: "The country button opens the actual searchable country picker. No SMS is sent."
      case .google, .browserApple: "This is the real browser progress page. Browser sign-in is disabled in the gallery."
      case .nativeApple: "The real Apple completion page. Use the controls above to inspect progress and errors."
      case .profile: "Your name and photo stay in this preview. Photo-library selection and cropping are available; X lookup requires the Inline app."
      case .username: "Availability is simulated: enter “taken” for the unavailable state. Nothing is saved."
    }
  }

  var isProviderProgress: Bool {
    self == .google || self == .nativeApple || self == .browserApple
  }

  var route: OnboardingStep {
    switch self {
      case .welcome: .welcome
      case .getStarted: .getStarted
      case .email: .email()
      case .emailCode: .code(email: OnboardingGallerySession.email)
      case .emailInvite: .inviteCodeForEmail(email: OnboardingGallerySession.email)
      case .phone: .phoneNumber()
      case .phoneCode: .phoneNumberCode(phoneNumber: OnboardingGallerySession.phone)
      case .phoneInvite: .inviteCodeForPhone(phoneNumber: OnboardingGallerySession.phone)
      case .google: .provider(.google)
      case .nativeApple: .nativeAppleProgress
      case .appleInvite: .nativeAppleInvite
      case .browserApple: .provider(.apple)
      case .profile: .profile(userId: OnboardingGallerySession.userID)
      case .username: .username(userId: OnboardingGallerySession.userID)
    }
  }

  var path: [OnboardingStep] {
    switch self {
      case .welcome: [.welcome]
      case .getStarted: [.welcome, .getStarted]
      case .emailCode, .emailInvite:
        [.welcome, .getStarted, .email(prevEmail: OnboardingGallerySession.email), route]
      case .phoneCode, .phoneInvite:
        [.welcome, .getStarted, .phoneNumber(prevPhoneNumber: OnboardingGallerySession.phone), route]
      case .username:
        [.welcome, .getStarted, .profile(userId: OnboardingGallerySession.userID), route]
      default: [.welcome, .getStarted, route]
    }
  }

  init?(route: OnboardingStep) {
    switch route {
      case .welcome: self = .welcome
      case .getStarted: self = .getStarted
      case .email: self = .email
      case .code: self = .emailCode
      case .inviteCodeForEmail: self = .emailInvite
      case .phoneNumber: self = .phone
      case .phoneNumberCode: self = .phoneCode
      case .inviteCodeForPhone: self = .phoneInvite
      case .provider(.google): self = .google
      case .provider(.apple): self = .browserApple
      case .nativeAppleProgress: self = .nativeApple
      case .nativeAppleInvite: self = .appleInvite
      case .profile: self = .profile
      case .username: self = .username
      case .main: return nil
    }
  }
}
