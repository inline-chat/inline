import Testing
@testable import InlineKit

@Suite("Onboarding startup")
struct OnboardingSessionTests {
  @Test("pending provider profiles resume even when a name was prefilled")
  func pendingProfile() {
    #expect(OnboardingSession.requiresSetup(pendingSetup: true, firstName: "Test"))
  }

  @Test("complete legacy profiles do not require a username or a new setup flag")
  func completedProfile() {
    #expect(!OnboardingSession.requiresSetup(pendingSetup: false, firstName: "Test"))
    #expect(!OnboardingSession.requiresSetup(pendingSetup: nil, firstName: "Test"))
  }

  @Test("missing profile data must not route to the main app")
  func missingProfile() {
    #expect(OnboardingSession.requiresSetup(pendingSetup: false, firstName: nil))
    #expect(OnboardingSession.requiresSetup(pendingSetup: nil, firstName: "  "))
  }
}
