import Foundation
import Testing

@testable import InlineIOSUI

@Suite("Message View 2 feature")
struct MessageView2FeatureTests {
  @Test("renderer defaults to legacy when the preference is absent")
  func rendererDefaultsToLegacy() throws {
    let defaults = try #require(UserDefaults(suiteName: "MessageView2FeatureTests.legacy.\(UUID())"))

    #expect(MessageView2Feature.selectedImplementation(defaults: defaults) == .legacy)
  }

  @Test("renderer selects V2 only when explicitly enabled")
  func rendererSelectsV2WhenEnabled() throws {
    let defaults = try #require(UserDefaults(suiteName: "MessageView2FeatureTests.v2.\(UUID())"))
    defaults.set(true, forKey: MessageView2Feature.preferenceKey)

    #expect(MessageView2Feature.selectedImplementation(defaults: defaults) == .v2)
  }

  @Test("renderer stays legacy when the experiment is unavailable")
  func rendererStaysLegacyOutsideExperimentAudience() throws {
    let defaults = try #require(UserDefaults(suiteName: "MessageView2FeatureTests.unavailable.\(UUID())"))
    defaults.set(true, forKey: MessageView2Feature.preferenceKey)

    #expect(
      MessageView2Feature.selectedImplementation(
        defaults: defaults,
        isExperimentAvailable: false
      ) == .legacy
    )
  }
}
