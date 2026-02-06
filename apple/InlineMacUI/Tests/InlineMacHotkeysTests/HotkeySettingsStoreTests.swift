import Foundation
import Testing
@testable import InlineMacHotkeys

@Test @MainActor func hotkeySettingsStore_defaultIsDisabled() {
  let suiteName = "inline.tests.hotkeys.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    Issue.record("Failed to create UserDefaults suite")
    return
  }
  defaults.removePersistentDomain(forName: suiteName)

  let store = HotkeySettingsStore(userDefaults: defaults)
  #expect(store.globalFocusHotkey.enabled == false)
  #expect(store.globalFocusHotkey.hotkey == nil)
}

@Test @MainActor func hotkeySettingsStore_persistsAndLoads() {
  let suiteName = "inline.tests.hotkeys.\(UUID().uuidString)"
  guard let defaults = UserDefaults(suiteName: suiteName) else {
    Issue.record("Failed to create UserDefaults suite")
    return
  }
  defaults.removePersistentDomain(forName: suiteName)

  let store = HotkeySettingsStore(userDefaults: defaults)
  let hk = InlineHotkey(keyCode: 40, modifiers: 1 /* cmd */ | 8 /* shift */)
  store.globalFocusHotkey = .init(enabled: true, hotkey: hk)

  let store2 = HotkeySettingsStore(userDefaults: defaults)
  #expect(store2.globalFocusHotkey == store.globalFocusHotkey)
}

