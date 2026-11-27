import AppKit

/// One visible row of a menu, resolved for the modifier keys held right now.
struct MenuRow {
  enum Kind {
    case item
    case separator
    case header
    case view
  }

  let item: NSMenuItem
  let kind: Kind

  var isSelectable: Bool {
    kind == .item && item.isEnabled && item.contextMenuStyle != .footnote
  }
}

enum MenuModel {
  static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

  /// The rows a menu shows: hidden items dropped, alternates folded into their base item, and
  /// separators trimmed at the edges and collapsed where two meet (empty sections leave no gap).
  static func rows(for menu: NSMenu, modifiers: NSEvent.ModifierFlags) -> [MenuRow] {
    let held = modifiers.intersection(relevantModifiers)
    let items = menu.items
    var rows: [MenuRow] = []
    var index = 0
    while index < items.count {
      let base = items[index]
      var group = [base]
      var next = index + 1
      while next < items.count, items[next].isAlternate, items[next].keyEquivalent == base.keyEquivalent {
        group.append(items[next])
        next += 1
      }
      index = next

      let chosen = alternate(in: group, held: held)
      guard !chosen.isHidden else { continue }

      if chosen.isSeparatorItem {
        rows.append(MenuRow(item: chosen, kind: .separator))
      } else if chosen.isSectionHeader {
        rows.append(MenuRow(item: chosen, kind: .header))
      } else if chosen.view != nil {
        rows.append(MenuRow(item: chosen, kind: .view))
      } else {
        rows.append(MenuRow(item: chosen, kind: .item))
      }
    }
    return trimSeparators(rows)
  }

  /// AppKit folds items that share a key equivalent: the alternate shows while the keys it adds over
  /// the base item are held.
  private static func alternate(in group: [NSMenuItem], held: NSEvent.ModifierFlags) -> NSMenuItem {
    guard group.count > 1 else { return group[0] }
    let base = group[0]
    let baseMask = base.keyEquivalentModifierMask.intersection(relevantModifiers)
    var best = base
    var bestExtra = 0
    for candidate in group.dropFirst() where !candidate.isHidden {
      let mask = candidate.keyEquivalentModifierMask.intersection(relevantModifiers)
      let extra = mask.subtracting(baseMask)
      guard !extra.isEmpty, held.isSuperset(of: extra), mask.isSuperset(of: held) else { continue }
      let count = extra.rawValue.nonzeroBitCount
      if count > bestExtra {
        best = candidate
        bestExtra = count
      }
    }
    return best
  }

  private static func trimSeparators(_ rows: [MenuRow]) -> [MenuRow] {
    var result: [MenuRow] = []
    for row in rows {
      if row.kind == .separator {
        if result.isEmpty || result.last?.kind == .separator { continue }
      }
      result.append(row)
    }
    while result.last?.kind == .separator {
      result.removeLast()
    }
    return result
  }

  // MARK: - Key equivalents

  /// Modifier glyphs and key glyph, drawn in separate columns.
  static func keyEquivalentParts(for item: NSMenuItem) -> (String, String) {
    let text = keyEquivalentText(for: item)
    guard !text.isEmpty else { return ("", "") }
    let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
    let modifiers = String(text.prefix { modifierGlyphs.contains($0) })
    return (modifiers, String(text.dropFirst(modifiers.count)))
  }

  /// The shortcut text AppKit draws on the right of an item, such as ⇧⌘R.
  static func keyEquivalentText(for item: NSMenuItem) -> String {
    let key = item.keyEquivalent
    guard !key.isEmpty else { return "" }
    var modifiers = item.keyEquivalentModifierMask.intersection(relevantModifiers)
    let keyText: String
    if let special = specialKeyText(key) {
      keyText = special
    } else {
      if key.count == 1, key != key.lowercased() {
        modifiers.insert(.shift)
      }
      keyText = key.count == 1 ? key.uppercased() : key.capitalized
    }
    var text = ""
    if modifiers.contains(.control) { text += "⌃" }
    if modifiers.contains(.option) { text += "⌥" }
    if modifiers.contains(.shift) { text += "⇧" }
    if modifiers.contains(.command) { text += "⌘" }
    return text + keyText
  }

  private static func specialKeyText(_ key: String) -> String? {
    guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return nil }
    switch Int(scalar.value) {
    case 0x0D, 0x03: return "↩"
    case 0x08, 0x7F: return "⌫"
    case 0x1B: return "⎋"
    case 0x09: return "⇥"
    case 0x20: return "Space"
    case NSUpArrowFunctionKey: return "↑"
    case NSDownArrowFunctionKey: return "↓"
    case NSLeftArrowFunctionKey: return "←"
    case NSRightArrowFunctionKey: return "→"
    case NSDeleteFunctionKey: return "⌦"
    case NSHomeFunctionKey: return "↖"
    case NSEndFunctionKey: return "↘"
    case NSPageUpFunctionKey: return "⇞"
    case NSPageDownFunctionKey: return "⇟"
    default: return nil
    }
  }

  // MARK: - Type select

  /// The first selectable row whose title starts with the typed text, ignoring case and leading emoji.
  static func typeSelectMatch(_ query: String, in rows: [MenuRow]) -> Int? {
    let query = query.lowercased()
    guard !query.isEmpty else { return nil }
    return rows.firstIndex { row in
      guard row.isSelectable else { return false }
      return searchableTitle(row.item).hasPrefix(query)
    }
  }

  static func searchableTitle(_ item: NSMenuItem) -> String {
    let title = item.attributedTitle?.string ?? item.title
    let scalars = title.unicodeScalars.filter { !$0.properties.isEmojiPresentation }
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces).lowercased()
  }
}
