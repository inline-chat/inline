import Foundation
import Testing

@testable import InlineIOSUI

@Suite("Next message view feature")
struct NextMessageViewFeatureTests {
  @Test("renderer defaults to the next view when the preference is absent")
  func rendererDefaultsToNext() throws {
    let defaults = try #require(UserDefaults(suiteName: "NextMessageViewFeatureTests.default.\(UUID())"))

    #expect(NextMessageViewFeature.selectedImplementation(defaults: defaults) == .next)
  }

  @Test("renderer uses the current view only when explicitly turned off")
  func rendererSelectsLegacyWhenDisabled() throws {
    let defaults = try #require(UserDefaults(suiteName: "NextMessageViewFeatureTests.legacy.\(UUID())"))
    defaults.set(false, forKey: NextMessageViewFeature.preferenceKey)

    #expect(NextMessageViewFeature.selectedImplementation(defaults: defaults) == .legacy)
  }

  @Test("renderer ignores a stored opt-out where the toggle isn't offered")
  func rendererIgnoresOptOutWithoutOverride() throws {
    let defaults = try #require(UserDefaults(suiteName: "NextMessageViewFeatureTests.noOverride.\(UUID())"))
    defaults.set(false, forKey: NextMessageViewFeature.preferenceKey)

    #expect(
      NextMessageViewFeature.selectedImplementation(defaults: defaults, allowsOverride: false) == .next
    )
  }
}
