import EmojiAutocomplete
import InlineKit

public enum ComposeEmojiAutocompleteProvider {
  public static func items(matching query: String, limit: Int) -> [ComposeAutocompleteItem] {
    EmojiAutocomplete.suggestions(matching: query, limit: limit).map { suggestion in
      ComposeAutocompleteItem(
        id: "emoji-\(suggestion.shortcode)",
        kind: .emoji,
        title: ":\(suggestion.shortcode):",
        subtitle: suggestion.label,
        symbol: nil,
        emoji: suggestion.emoji,
        payload: .emoji(value: suggestion.emoji, shortcode: suggestion.shortcode)
      )
    }
  }
}
