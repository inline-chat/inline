import EmojiAutocomplete
import Foundation

public struct EmojiPickerItem: Hashable, Identifiable, Sendable {
  public let emoji: String
  public let shortcode: String
  public let label: String

  public var id: String {
    "\(emoji)-\(shortcode)"
  }

  public init(emoji: String, shortcode: String, label: String) {
    self.emoji = emoji
    self.shortcode = shortcode
    self.label = label
  }

  public func applying(skinTone: EmojiSkinTone) -> EmojiPickerItem {
    EmojiPickerItem(
      emoji: skinTone.applying(to: emoji),
      shortcode: shortcode,
      label: label
    )
  }
}

public struct EmojiPickerSection: Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let items: [EmojiPickerItem]

  public init(id: String, title: String, items: [EmojiPickerItem]) {
    self.id = id
    self.title = title
    self.items = items
  }
}

public enum EmojiSkinTone: String, CaseIterable, Identifiable, Sendable {
  case standard
  case light
  case mediumLight
  case medium
  case mediumDark
  case dark

  public var id: String { rawValue }

  public func applying(to emoji: String) -> String {
    guard let modifierValue, !EmojiPickerData.containsSkinToneModifier(in: emoji) else { return emoji }
    return EmojiPickerData.skinToneVariant(of: emoji, modifierValue: modifierValue) ?? emoji
  }

  private var modifierValue: UInt32? {
    switch self {
    case .standard:
      nil
    case .light:
      0x1F3FB
    case .mediumLight:
      0x1F3FC
    case .medium:
      0x1F3FD
    case .mediumDark:
      0x1F3FE
    case .dark:
      0x1F3FF
    }
  }
}

public enum EmojiSkinTonePreferenceStore {
  public static let key = "chat.inline.preferredEmojiSkinTone.v1"

  public static func current(userDefaults: UserDefaults = .standard) -> EmojiSkinTone {
    guard let rawValue = userDefaults.string(forKey: key),
          let tone = EmojiSkinTone(rawValue: rawValue)
    else {
      return .standard
    }
    return tone
  }

  public static func set(_ tone: EmojiSkinTone, userDefaults: UserDefaults = .standard) {
    userDefaults.set(tone.rawValue, forKey: key)
  }
}

public enum EmojiPickerData {
  public static func suggestions(matching query: String, limit: Int = 64) -> [EmojiPickerItem] {
    guard limit > 0 else { return [] }

    return Array(EmojiAutocomplete.suggestions(matching: query, limit: .max)
      .lazy
      .filter { !containsSkinToneModifier(in: $0.emoji) }
      .prefix(limit)
      .map(EmojiPickerItem.init))
  }

  public static let defaultSections: [EmojiPickerSection] = makeDefaultSections()

  fileprivate static func skinToneVariant(of emoji: String, modifierValue: UInt32) -> String? {
    let base = removingSkinToneModifiers(from: emoji)
    return skinToneVariantsByBase[base]?[modifierValue]
  }

  fileprivate static func containsSkinToneModifier(in emoji: String) -> Bool {
    emoji.unicodeScalars.contains { isSkinToneModifier($0.value) }
  }

  private static func makeDefaultSections() -> [EmojiPickerSection] {
    let items = Array(EmojiAutocomplete.allSuggestions
      .lazy
      .filter { !containsSkinToneModifier(in: $0.emoji) }
      .map(EmojiPickerItem.init))
    let starts = sectionStarts(in: items)
    guard starts.count == sectionBoundaries.count else {
      return [EmojiPickerSection(id: "emoji", title: "Emoji", items: items)]
    }

    return starts.enumerated().compactMap { index, start -> EmojiPickerSection? in
      let nextIndex = starts.indices.contains(index + 1) ? starts[index + 1].index : items.endIndex
      let sectionItems = Array(items[start.index..<nextIndex])
      guard !sectionItems.isEmpty else { return nil }
      return EmojiPickerSection(id: start.boundary.id, title: start.boundary.title, items: sectionItems)
    }
  }

  private static func sectionStarts(in items: [EmojiPickerItem]) -> [(boundary: SectionBoundary, index: Int)] {
    sectionBoundaries.compactMap { boundary in
      guard let index = items.firstIndex(where: { $0.shortcode == boundary.firstShortcode }) else {
        return nil
      }
      return (boundary, index)
    }
    .sorted { $0.index < $1.index }
  }

  private static let sectionBoundaries: [SectionBoundary] = [
    SectionBoundary(id: "smileys", title: "Smileys & Emotion", firstShortcode: "grinning"),
    SectionBoundary(id: "people", title: "People & Body", firstShortcode: "wave"),
    SectionBoundary(id: "animals", title: "Animals & Nature", firstShortcode: "monkey_face"),
    SectionBoundary(id: "food", title: "Food & Drink", firstShortcode: "grapes"),
    SectionBoundary(id: "travel", title: "Travel & Places", firstShortcode: "globe_showing_europe_africa"),
    SectionBoundary(id: "activities", title: "Activities", firstShortcode: "jack_o_lantern"),
    SectionBoundary(id: "objects", title: "Objects", firstShortcode: "glasses"),
    SectionBoundary(id: "symbols", title: "Symbols", firstShortcode: "atm_sign"),
    SectionBoundary(id: "flags", title: "Flags", firstShortcode: "chequered_flag"),
  ]

  private static let skinToneVariantsByBase: [String: [UInt32: String]] = {
    var variants: [String: [UInt32: String]] = [:]

    for suggestion in EmojiAutocomplete.allSuggestions {
      let modifierValues = suggestion.emoji.unicodeScalars
        .map(\.value)
        .filter(isSkinToneModifier)
      guard let modifierValue = modifierValues.first,
            modifierValues.allSatisfy({ $0 == modifierValue })
      else {
        continue
      }

      let base = removingSkinToneModifiers(from: suggestion.emoji)
      variants[base, default: [:]][modifierValue] = suggestion.emoji
    }

    return variants
  }()

  private static func removingSkinToneModifiers(from emoji: String) -> String {
    let scalars = emoji.unicodeScalars.filter { !isSkinToneModifier($0.value) }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func isSkinToneModifier(_ value: UInt32) -> Bool {
    (0x1F3FB ... 0x1F3FF).contains(value)
  }
}

private struct SectionBoundary: Sendable {
  let id: String
  let title: String
  let firstShortcode: String
}

private extension EmojiPickerItem {
  init(_ suggestion: EmojiAutocompleteSuggestion) {
    self.init(
      emoji: suggestion.emoji,
      shortcode: suggestion.shortcode,
      label: suggestion.label
    )
  }
}
