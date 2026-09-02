import Foundation
import Testing
@testable import InlineMacUI

@Suite("Getting-started visibility")
struct GettingStartedVisibilityTests {
  @Test("New signup remains visible until dismissal")
  func newSignupPersists() throws {
    try withUserDefaults { defaults in
      let userID: Int64 = 42

      GettingStartedVisibility.prepare(for: userID, isNewSignup: true, defaults: defaults)
      GettingStartedVisibility.prepare(for: userID, isNewSignup: false, defaults: defaults)

      #expect(GettingStartedVisibility.shouldShow(for: userID, defaults: defaults))
    }
  }

  @Test("Existing user is never shown the page")
  func existingUserStaysHidden() throws {
    try withUserDefaults { defaults in
      let userID: Int64 = 43

      GettingStartedVisibility.prepare(for: userID, isNewSignup: false, defaults: defaults)
      GettingStartedVisibility.prepare(for: userID, isNewSignup: true, defaults: defaults)

      #expect(!GettingStartedVisibility.shouldShow(for: userID, defaults: defaults))
    }
  }

  @Test("Dismissal cannot be undone by a later login")
  func dismissalIsPermanent() throws {
    try withUserDefaults { defaults in
      let userID: Int64 = 44

      GettingStartedVisibility.prepare(for: userID, isNewSignup: true, defaults: defaults)
      GettingStartedVisibility.dismiss(for: userID, defaults: defaults)
      GettingStartedVisibility.prepare(for: userID, isNewSignup: true, defaults: defaults)

      #expect(!GettingStartedVisibility.shouldShow(for: userID, defaults: defaults))
    }
  }

  private func withUserDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "GettingStartedVisibilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
  }
}
