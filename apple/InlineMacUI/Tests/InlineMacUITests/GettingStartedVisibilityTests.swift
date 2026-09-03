import Foundation
import Testing
@testable import InlineMacUI

@Suite("Getting-started visibility")
struct GettingStartedVisibilityTests {
  @Test("The page is visible by default")
  func startsVisible() throws {
    try withUserDefaults { defaults in
      #expect(GettingStartedVisibility.shouldShow(defaults: defaults))
    }
  }

  @Test("Legacy existing-user classification does not suppress the page")
  func legacyClassificationIsIgnored() throws {
    try withUserDefaults { defaults in
      let userID: Int64 = 44

      defaults.set(false, forKey: "gettingStarted.isVisible.\(userID)")

      #expect(GettingStartedVisibility.shouldShow(defaults: defaults))
    }
  }

  @Test("Dismissal hides the page globally")
  func dismissalIsGlobal() throws {
    try withUserDefaults { defaults in
      defaults.set(
        true,
        forKey: GettingStartedVisibility.dismissalPreferenceKey
      )

      #expect(!GettingStartedVisibility.shouldShow(defaults: defaults))
    }
  }

  private func withUserDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "GettingStartedVisibilityTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
  }
}
