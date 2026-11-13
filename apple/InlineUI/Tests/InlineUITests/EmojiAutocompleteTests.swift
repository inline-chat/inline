import EmojiAutocomplete
import Foundation
import InlineKit
import Testing
import TextProcessing

@Suite("Emoji Autocomplete")
struct EmojiAutocompleteTests {
  @Test("two-character queries complete shortcodes, popular first")
  func twoCharacterQueriesCompleteShortcodes() {
    let sm = EmojiAutocomplete.suggestions(matching: "sm", limit: 20)
    #expect(sm.first?.shortcode == "smile")
    #expect(sm.contains { $0.shortcode == "flag_san_marino" })

    #expect(EmojiAutocomplete.suggestions(matching: "he", limit: 5).first?.emoji == "❤️")
    #expect(EmojiAutocomplete.suggestions(matching: "th", limit: 5).first?.emoji == "👍")
  }

  @Test("two-character queries skip alias and keyword prefixes")
  func twoCharacterQueriesSkipAliasPrefixes() {
    // "he" prefixes the "hehe" alias of 😂; only shortcodes complete at two letters.
    let emojis = EmojiAutocomplete.suggestions(matching: "he", limit: 24).map(\.emoji)
    #expect(!emojis.contains("😂"))
  }

  @Test("popular emoji lead prefix matches")
  func popularEmojiLeadPrefixMatches() {
    #expect(EmojiAutocomplete.suggestions(matching: "hea", limit: 3).first?.emoji == "❤️")
    #expect(EmojiAutocomplete.suggestions(matching: "lau", limit: 3).first?.emoji == "😂")
  }

  @Test("search excludes skin tone variants")
  func searchExcludesSkinToneVariants() {
    for query in ["wave", "thumbs", "ok_hand", "shrug", "facepalm"] {
      let suggestions = EmojiAutocomplete.suggestions(matching: query, limit: 24)
      #expect(!suggestions.isEmpty)
      #expect(suggestions.allSatisfy { !containsSkinToneModifier($0.emoji) }, "\(query)")
    }
  }

  @Test("base entries have unique shortcodes")
  func baseEntriesHaveUniqueShortcodes() {
    let shortcodes = EmojiAutocomplete.allSuggestions
      .filter { !containsSkinToneModifier($0.emoji) }
      .map(\.shortcode)
    #expect(Set(shortcodes).count == shortcodes.count)
    #expect(EmojiAutocomplete.suggestions(matching: "hash", limit: 1).first?.emoji == "#️⃣")
    #expect(EmojiAutocomplete.suggestions(matching: "dark_sunglasses", limit: 1).first?.emoji == "🕶️")
    #expect(EmojiAutocomplete.suggestions(matching: "pinata", limit: 1).first?.shortcode == "pinata")
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

  @Test("prioritizes trademark alias over flag keyword")
  func prioritizesTrademarkAliasOverFlagKeyword() {
    let suggestions = EmojiAutocomplete.suggestions(matching: "tm", limit: 5)

    #expect(suggestions.first?.emoji == "™️")
    #expect(suggestions.first?.shortcode == "trade_mark")
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

  @Test("matches multi-word queries in any order")
  func matchesMultiWordQueriesInAnyOrder() {
    #expect(EmojiAutocomplete.suggestions(matching: "red heart", limit: 3).first?.emoji == "❤️")
    #expect(EmojiAutocomplete.suggestions(matching: "heart red", limit: 3).first?.emoji == "❤️")
    #expect(EmojiAutocomplete.suggestions(matching: "cat smile", limit: 8).contains { $0.emoji == "😼" })
  }

  @Test("treats spaces, dashes, and underscores alike")
  func treatsSeparatorsAlike() {
    for query in ["face_palm", "face palm", "face-palm", "facepalm"] {
      #expect(EmojiAutocomplete.suggestions(matching: query, limit: 3).first?.emoji == "🤦", "\(query)")
    }
  }

  @Test("tolerates one typo when nothing matches exactly")
  func toleratesOneTypo() {
    #expect(EmojiAutocomplete.suggestions(matching: "thumsup", limit: 3).first?.emoji == "👍")
    #expect(EmojiAutocomplete.suggestions(matching: "hart", limit: 3).first?.emoji == "❤️")
    #expect(EmojiAutocomplete.suggestions(matching: "rocekt", limit: 3).first?.emoji == "🚀")
    #expect(EmojiAutocomplete.suggestions(matching: "celebrte", limit: 3).first?.emoji == "🎉")
  }

  @Test("keeps short typo matches out of strong results")
  func keepsShortTypoMatchesOut() {
    let pray = EmojiAutocomplete.suggestions(matching: "pray", limit: 24).map(\.emoji)
    #expect(pray.first == "🙏")
    #expect(!pray.contains("▶️"))

    let lgtm = Set(EmojiAutocomplete.suggestions(matching: "lgtm", limit: 24).map(\.emoji))
    #expect(lgtm == ["👍", "✅"])
  }

  @Test("matches common Slack shortcodes")
  func matchesCommonSlackShortcodes() {
    #expect(EmojiAutocomplete.suggestions(matching: "point_right", limit: 1).first?.emoji == "👉")
    #expect(EmojiAutocomplete.suggestions(matching: "zap", limit: 1).first?.emoji == "⚡")
    #expect(EmojiAutocomplete.suggestions(matching: "heavy_check_mark", limit: 1).first?.emoji == "✔️")
  }

  @Test("personal usage lifts matches but not over another exact shortcode")
  func personalUsageLiftsMatches() {
    let usage = EmojiUsageSnapshot(scores: [EmojiUsageKey.make("🥳"): 40])

    #expect(EmojiAutocomplete.suggestions(matching: "party", limit: 3).first?.emoji == "🎉")
    #expect(EmojiAutocomplete.suggestions(matching: "party", limit: 3, usage: usage).first?.emoji == "🥳")
    #expect(EmojiAutocomplete.suggestions(matching: "tada", limit: 3, usage: usage).first?.emoji == "🎉")
  }

  @Test("usage store ranks frecency and ignores skin tone")
  func usageStoreRanksFrecency() throws {
    let suiteName = "EmojiUsageStoreTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let now = Date()
    EmojiUsageStore.record("🚀", date: now.addingTimeInterval(-60 * 86_400), userDefaults: defaults)
    EmojiUsageStore.record("🚀", date: now.addingTimeInterval(-60 * 86_400), userDefaults: defaults)
    EmojiUsageStore.record("👋🏽", date: now, userDefaults: defaults)
    EmojiUsageStore.record("❤", date: now, userDefaults: defaults)
    EmojiUsageStore.record("❤️", date: now, userDefaults: defaults)

    let frequent = EmojiUsageStore.frequentlyUsed(limit: 3, now: now, userDefaults: defaults)
    #expect(frequent == ["❤️", "👋", "🚀"])
    #expect(EmojiUsageStore.snapshot(now: now, userDefaults: defaults).score(for: "👋🏿") > 0)
  }

  @Test("usage store seeds from reaction history once")
  func usageStoreSeedsFromReactionHistory() throws {
    let suiteName = "EmojiUsageStoreSeedTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(["🔥": 5, "👍🏻": 2], forKey: "chat.inline.reactionPicker.emojiUsageCounts.v1")
    #expect(EmojiUsageStore.frequentlyUsed(limit: 5, userDefaults: defaults) == ["🔥", "👍"])

    defaults.set(["🎉": 50], forKey: "chat.inline.reactionPicker.emojiUsageCounts.v1")
    #expect(EmojiUsageStore.frequentlyUsed(limit: 5, userDefaults: defaults) == ["🔥", "👍"])
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
    let items = ComposeEmojiAutocompleteProvider.items(matching: "tada", limit: 3, usage: .empty, skinTone: .standard)

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

  @Test("text processing provider applies the preferred skin tone")
  func providerAppliesPreferredSkinTone() {
    let items = ComposeEmojiAutocompleteProvider.items(matching: "wave", limit: 24, usage: .empty, skinTone: .medium)

    #expect(items.first?.emoji == "👋🏽")
    #expect(items.first?.title == ":wave:")
    #expect(Set(items.map(\.id)).count == items.count)
  }

  @Test("picker data uses autocomplete search")
  func pickerDataUsesAutocompleteSearch() {
    let items = EmojiPickerData.suggestions(matching: ":tada", limit: 3, usage: .empty)

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

  @Test("picker data browse sections include one base entry instead of skin tone variants")
  func pickerDataBrowseSectionsExcludeSkinToneVariants() {
    let sectionItems = EmojiPickerData.defaultSections.flatMap(\.items)
    let sectionIDs = Set(sectionItems.map(\.id))
    let generatedBaseItems = EmojiAutocomplete.allSuggestions.filter { !containsSkinToneModifier($0.emoji) }
    let generatedBaseIDs = Set(generatedBaseItems.map(\.id))

    #expect(sectionItems.count == generatedBaseItems.count)
    #expect(sectionIDs == generatedBaseIDs)
    #expect(sectionItems.allSatisfy { !containsSkinToneModifier($0.emoji) })
  }

  @Test("picker search excludes skin tone variants")
  func pickerSearchExcludesSkinToneVariants() {
    let items = EmojiPickerData.suggestions(matching: "wave", limit: 64, usage: .empty)

    #expect(items.contains { $0.shortcode == "wave" })
    #expect(items.allSatisfy { !containsSkinToneModifier($0.emoji) })
  }

  @Test("preferred skin tone resolves supported emoji variants")
  func preferredSkinToneResolvesSupportedEmojiVariants() {
    #expect(EmojiSkinTone.light.applying(to: "👋") == "👋🏻")
    #expect(EmojiSkinTone.dark.applying(to: "🧑‍💻") == "🧑🏿‍💻")

    let wave = EmojiPickerItem(emoji: "👋", shortcode: "wave", label: "waving hand")
    #expect(wave.applying(skinTone: .medium).emoji == "👋🏽")
  }

  @Test("preferred skin tone preserves explicit variants, unsupported emoji, and standard mode")
  func preferredSkinTonePreservesExplicitUnsupportedAndStandardEmoji() {
    #expect(EmojiSkinTone.medium.applying(to: "👋🏻") == "👋🏻")
    #expect(EmojiSkinTone.dark.applying(to: "🚀") == "🚀")
    #expect(EmojiSkinTone.standard.applying(to: "👋🏽") == "👋🏽")
  }

  @Test("preferred skin tone store defaults and persists")
  func preferredSkinToneStoreDefaultsAndPersists() throws {
    let suiteName = "EmojiSkinTonePreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(EmojiSkinTonePreferenceStore.current(userDefaults: defaults) == .standard)
    EmojiSkinTonePreferenceStore.set(.mediumDark, userDefaults: defaults)
    #expect(EmojiSkinTonePreferenceStore.current(userDefaults: defaults) == .mediumDark)
  }

  private func containsSkinToneModifier(_ emoji: String) -> Bool {
    emoji.unicodeScalars.contains { (0x1F3FB ... 0x1F3FF).contains($0.value) }
  }
}
