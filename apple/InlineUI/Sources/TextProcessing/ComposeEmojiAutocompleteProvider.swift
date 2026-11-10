import EmojiAutocomplete
import Foundation
import InlineKit

public enum ComposeEmojiAutocompleteProvider {
  public static func items(
    matching query: String,
    limit: Int,
    usage: EmojiUsageSnapshot = EmojiUsageStore.snapshot(),
    skinTone: EmojiSkinTone = EmojiSkinTonePreferenceStore.current()
  ) -> [ComposeAutocompleteItem] {
    EmojiAutocomplete.suggestions(matching: query, limit: limit, usage: usage).map { suggestion in
      let emoji = skinTone.applying(to: suggestion.emoji)
      return ComposeAutocompleteItem(
        id: "emoji-\(suggestion.emoji)",
        kind: .emoji,
        title: ":\(suggestion.shortcode):",
        subtitle: suggestion.label,
        symbol: nil,
        emoji: emoji,
        payload: .emoji(value: emoji, shortcode: suggestion.shortcode)
      )
    }
  }

  /// Feeds the frecency that ranks future suggestions.
  public static func recordSelection(_ emoji: String) {
    EmojiUsageStore.record(emoji)
  }
}
