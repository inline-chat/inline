import Foundation
import Testing

@testable import InlineIOSUI

@Suite("Next message view feature")
struct NextMessageViewFeatureTests {
  @Test("renderer defaults to legacy when the preference is absent")
  func rendererDefaultsToLegacy() throws {
    let defaults = try #require(UserDefaults(suiteName: "NextMessageViewFeatureTests.legacy.\(UUID())"))

    #expect(NextMessageViewFeature.selectedImplementation(defaults: defaults) == .legacy)
  }

  @Test("renderer selects the next view only when explicitly enabled")
  func rendererSelectsNextWhenEnabled() throws {
    let defaults = try #require(UserDefaults(suiteName: "NextMessageViewFeatureTests.next.\(UUID())"))
    defaults.set(true, forKey: NextMessageViewFeature.preferenceKey)

    #expect(NextMessageViewFeature.selectedImplementation(defaults: defaults) == .next)
  }

  @Test("renderer stays legacy when the experiment is unavailable")
  func rendererStaysLegacyOutsideExperimentAudience() throws {
    let defaults = try #require(UserDefaults(suiteName: "NextMessageViewFeatureTests.unavailable.\(UUID())"))
    defaults.set(true, forKey: NextMessageViewFeature.preferenceKey)

    #expect(
      NextMessageViewFeature.selectedImplementation(
        defaults: defaults,
        isExperimentAvailable: false
      ) == .legacy
    )
  }
}
