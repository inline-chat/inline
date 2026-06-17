import EmojiAutocomplete
import InlineKit
import Testing
import TextProcessing

@Suite("Emoji Autocomplete")
struct EmojiAutocompleteTests {
  @Test("hides short prefix matches before three characters")
  func hidesShortPrefixMatchesBeforeThreeCharacters() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "sm", limit: 20)

    #expect(suggestions.contains { $0.shortcode == "flag_san_marino" })
    #expect(!suggestions.contains { $0.shortcode == "smile" })
  }

  @Test("allows one-character exact matches")
  func allowsOneCharacterExactMatches() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "o", limit: 5)

    #expect(suggestions.first?.emoji == "😮")
    #expect(suggestions.first?.shortcode == "face_with_open_mouth")
    #expect(!suggestions.contains { $0.shortcode == "hollow_red_circle" })
  }

  @Test("allows two-character exact matches")
  func allowsTwoCharacterExactMatches() {
    let emojis = EmojiAutocomplete.suggestions(matching: "no", limit: 10).map(\.emoji)

    #expect(emojis.contains("🙅‍♂️"))
    #expect(emojis.contains("🙅‍♀️"))
    #expect(emojis.contains("🚫"))
    #expect(emojis.contains("🇳🇴"))
    #expect(emojis.contains("👎"))
  }

  @Test("allows exact x shortcode")
  func allowsExactXShortcode() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "x", limit: 5)

    #expect(suggestions.first?.emoji == "❌")
    #expect(suggestions.first?.shortcode == "x")
  }

  @Test("prioritizes common shortcode aliases")
  func prioritizesCommonShortcodeAliases() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "smile", limit: 5)

    #expect(suggestions.first?.emoji == "😄")
    #expect(suggestions.first?.shortcode == "smile")
  }

  @Test("shows two-letter flag aliases")
  func showsTwoLetterFlagAliases() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "us", limit: 5)

    #expect(suggestions.first?.emoji == "🇺🇸")
    #expect(suggestions.allSatisfy { $0.shortcode.hasPrefix("flag_") })
  }

  @Test("matches common slang aliases")
  func matchesCommonSlangAliases() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "lol", limit: 5)

    #expect(suggestions.first?.emoji == "😂")
  }

  @Test("matches stronger chat slang aliases")
  func matchesStrongerChatSlangAliases() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "lmfao", limit: 5)

    #expect(suggestions.first?.emoji == "😂")
  }

  @Test("matches compact underscore-free aliases")
  func matchesCompactUnderscoreFreeAliases() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "mindblown", limit: 5)

    #expect(suggestions.first?.emoji == "🤯")
  }

  @Test("matches query across keyword words")
  func matchesQueryAcrossKeywordWords() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "fjoy", limit: 8)

    #expect(suggestions.contains { $0.emoji == "😂" })
  }

  @Test("finds CLDR keyword matches")
  func findsCLDRKeywordMatches() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "rocket", limit: 5)

    #expect(suggestions.contains { $0.emoji == "🚀" })
  }

  @Test("supports plus and minus aliases")
  func supportsPlusAndMinusAliases() {
    let plus = EmojiAutocomplete.suggestions(matching: "+1", limit: 3)
    let minus = EmojiAutocomplete.suggestions(matching: "-1", limit: 3)

    #expect(plus.first?.emoji == "👍")
    #expect(minus.first?.emoji == "👎")
  }

  @Test("text processing provider maps suggestions to compose items")
  func providerMapsSuggestionsToComposeItems() {
    let items = ComposeEmojiAutocompleteProvider.items(matching: "tada", limit: 3)

    #expect(items.first?.kind == .emoji)
    #expect(items.first?.title == ":tada:")
    #expect(items.first?.emoji == "🎉")

    if case let .emoji(value, shortcode) = items.first?.payload {
      #expect(value == "🎉")
      #expect(shortcode == "tada")
    } else {
      Issue.record("Expected emoji payload")
    }
  }

  @Test("picker data uses autocomplete search")
  func pickerDataUsesAutocompleteSearch() {
    let items = EmojiPickerData.suggestions(matching: ":tada", limit: 3)

    #expect(items.first?.emoji == "🎉")
    #expect(items.first?.shortcode == "tada")
  }

  @Test("picker data exposes non-empty default sections")
  func pickerDataExposesDefaultSections() {
    let sections = EmojiPickerData.defaultSections

    #expect(!sections.isEmpty)
    #expect(sections.allSatisfy { !$0.items.isEmpty })
    #expect(sections.flatMap(\.items).contains { $0.shortcode == "thumbsup" })
  }

  @Test("picker data browse sections include all generated emoji")
  func pickerDataBrowseSectionsIncludeAllGeneratedEmoji() {
    let sectionItems = EmojiPickerData.defaultSections.flatMap(\.items)
    let sectionIDs = Set(sectionItems.map(\.id))
    let generatedIDs = Set(EmojiAutocomplete.allSuggestions.map(\.id))

    #expect(sectionItems.count == EmojiAutocomplete.allSuggestions.count)
    #expect(sectionIDs == generatedIDs)
  }
}
