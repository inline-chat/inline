import Foundation
import Testing

@testable import InlineIOSUI

@Suite("Message context menu feature")
struct MessageContextMenuFeatureTests {
  private func makeDefaults(_ name: String) throws -> UserDefaults {
    try #require(UserDefaults(suiteName: "MessageContextMenuFeatureTests.\(name).\(UUID())"))
  }

  @Test("the custom menu is the default")
  func defaultsToCustom() throws {
    let defaults = try makeDefaults("default")

    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults) == .custom)
  }

  @Test("turning the setting off brings back the system menu")
  func selectsSystemWhenTurnedOff() throws {
    let defaults = try makeDefaults("off")
    defaults.set(false, forKey: MessageContextMenuFeature.preferenceKey)

    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults) == .system)
  }

  @Test("the system menu stays where the custom one isn't available")
  func staysSystemWhenUnavailable() throws {
    let defaults = try makeDefaults("unavailable")
    defaults.set(true, forKey: MessageContextMenuFeature.preferenceKey)

    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults, isAvailable: false) == .system)
  }

  @Test("a run that closed its menus leaves nothing to count")
  func cleanRun() throws {
    let defaults = try makeDefaults("clean")
    MessageContextMenuFeature.markOpen(defaults: defaults)
    MessageContextMenuFeature.markClosed(defaults: defaults)

    #expect(MessageContextMenuFeature.checkLastRun(defaults: defaults) == .clean)
  }

  @Test("runs that end with the menu open turn it off at the limit")
  func crashGuardTurnsOff() throws {
    let defaults = try makeDefaults("guard")

    MessageContextMenuFeature.markOpen(defaults: defaults)
    #expect(MessageContextMenuFeature.checkLastRun(defaults: defaults) == .strike(count: 1))
    #expect(MessageContextMenuFeature.checkLastRun(defaults: defaults) == .clean)
    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults) == .custom)

    MessageContextMenuFeature.markOpen(defaults: defaults)
    #expect(MessageContextMenuFeature.checkLastRun(defaults: defaults) == .turnedOff(count: 2))
    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults) == .system)
  }

  @Test("the guard leaves a menu turned on by hand alone, and resets")
  func crashGuardRespectsExplicitChoice() throws {
    let defaults = try makeDefaults("explicit")
    defaults.set(true, forKey: MessageContextMenuFeature.preferenceKey)

    for count in 1...3 {
      MessageContextMenuFeature.markOpen(defaults: defaults)
      #expect(MessageContextMenuFeature.checkLastRun(defaults: defaults) == .strike(count: count))
    }
    #expect(MessageContextMenuFeature.selectedImplementation(defaults: defaults) == .custom)

    MessageContextMenuFeature.resetCrashGuard(defaults: defaults)
    MessageContextMenuFeature.markOpen(defaults: defaults)
    #expect(MessageContextMenuFeature.checkLastRun(defaults: defaults) == .strike(count: 1))
  }
}
