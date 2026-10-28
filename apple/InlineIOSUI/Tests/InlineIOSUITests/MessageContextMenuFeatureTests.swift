import Foundation
import Testing

@testable import InlineIOSUI

@Suite("Message context menu feature")
struct MessageContextMenuFeatureTests {
  @Test("the system menu stays when the preference is absent")
  func defaultsToSystem() throws {
    let defaults = try #require(UserDefaults(suiteName: "MessageContextMenuFeatureTests.system.\(UUID())"))

    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults) == .system)
  }

  @Test("the custom menu is used only when explicitly enabled")
  func selectsCustomWhenEnabled() throws {
    let defaults = try #require(UserDefaults(suiteName: "MessageContextMenuFeatureTests.custom.\(UUID())"))
    defaults.set(true, forKey: MessageContextMenuFeature.preferenceKey)

    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults) == .custom)
  }

  @Test("the system menu stays outside the experiment audience")
  func staysSystemWhenUnavailable() throws {
    let defaults = try #require(UserDefaults(suiteName: "MessageContextMenuFeatureTests.unavailable.\(UUID())"))
    defaults.set(true, forKey: MessageContextMenuFeature.preferenceKey)

    #expect(
      MessageContextMenuFeature.selectedImplementation(defaults: defaults, isExperimentAvailable: false) == .system
    )
  }
}
