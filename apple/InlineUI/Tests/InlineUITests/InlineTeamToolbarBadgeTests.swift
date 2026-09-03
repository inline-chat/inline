import InlineKit
import Testing

@testable import InlineUI

@Suite("Inline team toolbar badge")
struct InlineTeamToolbarBadgeTests {
  @Test("shows for the production Inline Team user IDs")
  func showsForProductionUserIDs() {
    #expect(shouldShow(userID: 1600))
    #expect(shouldShow(userID: 1900))
  }

  @Test("stays hidden for other production users")
  func staysHiddenForOtherProductionUsers() {
    #expect(!shouldShow(userID: 1599))
    #expect(!shouldShow(userID: 1901, email: "dena@inline.chat"))
  }

  @Test("allows Dena's email only for the development preview")
  func allowsDevelopmentPreviewEmail() {
    #expect(shouldShow(
      userID: 42,
      email: " DENA@inline.chat ",
      includesDevelopmentPreview: true
    ))
    #expect(!shouldShow(
      userID: 42,
      email: "someone@inline.chat",
      includesDevelopmentPreview: true
    ))
  }

  private func shouldShow(
    userID: Int64,
    email: String? = nil,
    includesDevelopmentPreview: Bool = false
  ) -> Bool {
    InlineTeamToolbarBadgeVisibility.shouldShow(
      for: User(id: userID, email: email, firstName: "User"),
      includesDevelopmentPreview: includesDevelopmentPreview
    )
  }
}
