import Foundation
import Testing

@testable import ReactionPickerEmojis

@Suite("Reaction picker emojis")
struct ReactionPickerEmojisTests {
  @Test("unranked suggestions use default reactions")
  func unrankedSuggestionsUseDefaultReactions() {
    #expect(ReactionPickerEmojis.suggestions(from: [:]) == ReactionPickerEmojis.defaultEmojis)
  }

  @Test("counted emojis replace defaults from the beginning")
  func countedEmojisReplaceDefaultsFromBeginning() {
    let suggestions = ReactionPickerEmojis.suggestions(
      from: [
        "🚀": 3,
        "🧠": 2,
      ]
    )

    #expect(Array(suggestions.prefix(4)) == ["🚀", "🧠", "🥹", "❤️"])
    #expect(suggestions.count == ReactionPickerEmojis.defaultEmojis.count)
  }

  @Test("default emojis are ranked by usage counts")
  func defaultEmojisAreRankedByUsageCounts() {
    let suggestions = ReactionPickerEmojis.suggestions(
      from: [
        "🎉": 5,
        "🚀": 4,
        "👍": 3,
      ],
      limit: 5
    )

    #expect(suggestions == ["🎉", "🚀", "👍", "🥹", "❤️"])
  }

  @Test("normalization keeps the first emoji cluster")
  func normalizationKeepsFirstEmojiCluster() {
    #expect(ReactionPickerEmojis.normalizedEmoji(from: " 🚀🔥 ") == "🚀")
    #expect(ReactionPickerEmojis.normalizedEmoji(from: "👨‍👩‍👧‍👦x") == "👨‍👩‍👧‍👦")
    #expect(ReactionPickerEmojis.normalizedEmoji(from: " \n ") == nil)
  }

  @Test("usage store records, ranks, and removes picks")
  func usageStoreRecordsRanksAndRemovesPicks() {
    let suiteName = "ReactionPickerEmojisTests.\(UUID().uuidString)"
    let defaults = makeUserDefaults(suiteName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    ReactionPickerEmojiUsageStore.recordPick("🚀", userDefaults: defaults)
    ReactionPickerEmojiUsageStore.recordPick("🎉", userDefaults: defaults)
    ReactionPickerEmojiUsageStore.recordPick("🚀", userDefaults: defaults)

    #expect(ReactionPickerEmojiUsageStore.usageCount(for: "🚀", userDefaults: defaults) == 2)
    #expect(ReactionPickerEmojiUsageStore.suggestedEmojis(limit: 3, userDefaults: defaults) == ["🚀", "🎉", "🥹"])

    ReactionPickerEmojiUsageStore.removeSuggestion("🚀", userDefaults: defaults)

    #expect(ReactionPickerEmojiUsageStore.usageCount(for: "🚀", userDefaults: defaults) == 0)
    #expect(ReactionPickerEmojiUsageStore.suggestedEmojis(limit: 3, userDefaults: defaults) == ["🎉", "🥹", "❤️"])
  }

  private func makeUserDefaults(suiteName: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create UserDefaults suite")
      return .standard
    }

    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
