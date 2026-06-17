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

public enum EmojiPickerData {
  public static func suggestions(matching query: String, limit: Int = 64) -> [EmojiPickerItem] {
    EmojiAutocomplete.suggestions(matching: query, limit: limit).map(EmojiPickerItem.init)
  }

  public static let defaultSections: [EmojiPickerSection] = makeDefaultSections()

  private static func makeDefaultSections() -> [EmojiPickerSection] {
    let items = EmojiAutocomplete.allSuggestions.map(EmojiPickerItem.init)
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
