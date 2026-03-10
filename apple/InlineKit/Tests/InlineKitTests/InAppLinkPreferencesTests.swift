import Foundation
import Testing

@testable import InlineKit

@Suite("In-App Link Preferences")
struct InAppLinkPreferencesTests {
  @Test("defaults to opening links in app")
  func defaultsToOpeningLinksInApp() {
    let storage = makeUserDefaults()
    defer { reset(suiteName: storage.suiteName) }

    #expect(InAppLinkPreferences.opensLinksInApp(userDefaults: storage.userDefaults))
  }

  @Test("persists explicit preference changes")
  func persistsExplicitPreferenceChanges() {
    let storage = makeUserDefaults()
    defer { reset(suiteName: storage.suiteName) }

    InAppLinkPreferences.setOpensLinksInApp(false, userDefaults: storage.userDefaults)
    #expect(!InAppLinkPreferences.opensLinksInApp(userDefaults: storage.userDefaults))

    InAppLinkPreferences.setOpensLinksInApp(true, userDefaults: storage.userDefaults)
    #expect(InAppLinkPreferences.opensLinksInApp(userDefaults: storage.userDefaults))
  }

  private func makeUserDefaults() -> (userDefaults: UserDefaults, suiteName: String) {
    let suiteName = "InAppLinkPreferencesTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    return (userDefaults, suiteName)
  }

  private func reset(suiteName: String) {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}
