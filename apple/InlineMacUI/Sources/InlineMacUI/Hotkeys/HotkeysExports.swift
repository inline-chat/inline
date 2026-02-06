import Foundation
import InlineMacHotkeys

// Expose hotkey persistence/models via InlineMacUI so the app doesn't need a separate
// product dependency in Xcode just to use hotkeys.
public typealias HotkeySettingsStore = InlineMacHotkeys.HotkeySettingsStore
public typealias InlineHotkey = InlineMacHotkeys.InlineHotkey

