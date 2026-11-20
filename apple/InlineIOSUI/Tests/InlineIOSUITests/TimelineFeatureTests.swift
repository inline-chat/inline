import Foundation
@testable import InlineIOSUI
import Testing

@Suite("Timeline list default")
struct TimelineFeatureTests {
  private func defaults() -> UserDefaults {
    let name = "timeline-feature-\(UUID())"
    return UserDefaults(suiteName: name)!
  }

  @Test("the timeline is the default list, with or without the developer switch")
  func onByDefault() {
    let defaults = defaults()
    #expect(TimelineFeature.isEnabled(defaults: defaults, allowsOverride: true))
    #expect(TimelineFeature.isEnabled(defaults: defaults, allowsOverride: false))
  }

  @Test("the developer switch turned off brings the collection view back, only where it shows")
  func switchOff() {
    let defaults = defaults()
    defaults.set(false, forKey: TimelineFeature.preferenceKey)
    #expect(!TimelineFeature.isEnabled(defaults: defaults, allowsOverride: true))
    #expect(TimelineFeature.isEnabled(defaults: defaults, allowsOverride: false))
    defaults.set(true, forKey: TimelineFeature.preferenceKey)
    #expect(TimelineFeature.isEnabled(defaults: defaults, allowsOverride: true))
  }
}
