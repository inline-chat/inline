import Testing
@testable import InlineMacUI

@Test @MainActor
func gettingStartedVisibility_isOneShotForTheNewlyCreatedUser() {
  GettingStartedVisibility.prepare(for: 101, isNewSignup: true)

  #expect(GettingStartedVisibility.shouldShow(for: 202) == false)
  #expect(GettingStartedVisibility.shouldShow(for: 101))
  #expect(GettingStartedVisibility.shouldShow(for: 101) == false)
}

@Test @MainActor
func gettingStartedVisibility_existingUserClearsPendingPresentation() {
  GettingStartedVisibility.prepare(for: 101, isNewSignup: true)
  GettingStartedVisibility.prepare(for: 101, isNewSignup: false)

  #expect(GettingStartedVisibility.shouldShow(for: 101) == false)
}
