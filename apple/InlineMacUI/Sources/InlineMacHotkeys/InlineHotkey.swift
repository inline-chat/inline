import AppKit
import Carbon
import Foundation

/// Serializable hotkey representation used for user-configurable shortcuts.
/// Stored as a physical keycode + a simple modifier bitmask for stability.
public struct InlineHotkey: Codable, Equatable {
  public var keyCode: UInt16
  /// Bitmask: 1=command, 2=option, 4=control, 8=shift
  public var modifiers: Int

  public init(keyCode: UInt16, modifiers: Int) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }
}

extension InlineHotkey {
  static let commandBit = 1 << 0
  static let optionBit = 1 << 1
  static let controlBit = 1 << 2
  static let shiftBit = 1 << 3

  public static func fromKeyDownEvent(_ event: NSEvent) -> InlineHotkey? {
    // Ignore pure modifier taps or non-keyDown events.
    guard event.type == .keyDown else { return nil }

    let flags = event.modifierFlags
    var bits = 0
    if flags.contains(.command) { bits |= commandBit }
    if flags.contains(.option) { bits |= optionBit }
    if flags.contains(.control) { bits |= controlBit }
    if flags.contains(.shift) { bits |= shiftBit }

    // Global shortcuts without a modifier are almost always accidental and conflict-prone.
    guard bits != 0 else { return nil }

    return InlineHotkey(keyCode: event.keyCode, modifiers: bits)
  }

  public var isEmpty: Bool { modifiers == 0 }

  public var displayString: String {
    modifierSymbols + keySymbol(for: keyCode)
  }

  public var carbonModifiers: UInt32 {
    var m: UInt32 = 0
    if (modifiers & InlineHotkey.commandBit) != 0 { m |= UInt32(cmdKey) }
    if (modifiers & InlineHotkey.optionBit) != 0 { m |= UInt32(optionKey) }
    if (modifiers & InlineHotkey.controlBit) != 0 { m |= UInt32(controlKey) }
    if (modifiers & InlineHotkey.shiftBit) != 0 { m |= UInt32(shiftKey) }
    return m
  }

  private var modifierSymbols: String {
    var s = ""
    if (modifiers & InlineHotkey.controlBit) != 0 { s += "⌃" }
    if (modifiers & InlineHotkey.optionBit) != 0 { s += "⌥" }
    if (modifiers & InlineHotkey.shiftBit) != 0 { s += "⇧" }
    if (modifiers & InlineHotkey.commandBit) != 0 { s += "⌘" }
    return s
  }

  private func keySymbol(for keyCode: UInt16) -> String {
    // Common special keys first.
    switch Int(keyCode) {
    case 49: return "Space"
    case 36: return "Return"
    case 48: return "Tab"
    case 51: return "Delete"
    case 53: return "Esc"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default:
      break
    }

    // Translate using the active keyboard layout.
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
      return "Key \(keyCode)"
    }

    let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self) as Data
    return layoutData.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return "Key \(keyCode)" }
      let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)

      var deadKeyState: UInt32 = 0
      let maxLength = 8
      var chars = Array<UniChar>(repeating: 0, count: maxLength)
      var actualLength: Int = 0

      let status = UCKeyTranslate(
        layout,
        UInt16(keyCode),
        UInt16(kUCKeyActionDisplay),
        0,
        UInt32(LMGetKbdType()),
        OptionBits(UInt32(kUCKeyTranslateNoDeadKeysBit)),
        &deadKeyState,
        maxLength,
        &actualLength,
        &chars
      )

      guard status == noErr, actualLength > 0 else {
        return "Key \(keyCode)"
      }

      let str = String(utf16CodeUnits: chars, count: actualLength)
      // Make typical letter hotkeys read like "K" instead of "k".
      if str.count == 1 {
        return str.uppercased()
      }
      return str
    }
  }
}
