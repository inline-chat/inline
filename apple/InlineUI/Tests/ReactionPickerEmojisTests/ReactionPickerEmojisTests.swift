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

  @Test("legacy acknowledgement checks do not return as quick reactions")
  func legacyAcknowledgementChecksAreExcluded() {
    let suggestions = ReactionPickerEmojis.suggestions(
      from: ["✔️": 100, "✓": 99, "🚀": 1],
      limit: 3
    )

    #expect(suggestions == ["🚀", "🥹", "❤️"])
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

  @Test("message emojis come before learned suggestions and defaults")
  func messageEmojisComeFirst() {
    let usual = ReactionPickerEmojis.suggestions(from: ["🧠": 20])
    let result = ReactionPickerEmojis.prioritizingMessageEmojis(in: "great work 🎉", among: usual)
    #expect(Array(result.prefix(4)) == ["🎉", "🧠", "🥹", "❤️"])
    #expect(result.count == ReactionPickerEmojis.defaultLimit)
    #expect(result.filter { $0 == "🎉" }.count == 1)
  }

  @Test("multiple emojis keep first appearance order without duplicates")
  func multipleMessageEmojis() {
    let result = ReactionPickerEmojis.prioritizingMessageEmojis(
      in: "🔥 nice 🎉🔥\n❤️🎉",
      among: ["❤️", "👍", "🔥"]
    )
    #expect(result == ["🔥", "🎉", "❤️", "👍"])
  }

  @Test("message skin tones, flags, joined emojis and keycaps remain intact")
  func complexMessageEmojis() {
    let result = ReactionPickerEmojis.prioritizingMessageEmojis(
      in: "👍🏽 👨‍👩‍👧‍👦 🇮🇷 👩🏾‍💻 1️⃣ #️⃣ *️⃣ 🏳️‍🌈",
      among: ["👍🏻", "👍🏽", "🥹"]
    )
    #expect(result == ["👍🏽", "👨‍👩‍👧‍👦", "🇮🇷", "👩🏾‍💻", "1️⃣", "#️⃣", "*️⃣", "🏳️‍🌈", "👍🏻", "🥹"])
  }

  @Test("ordinary text, numbers and text presentation symbols do not add suggestions")
  func nonEmojiTextIsIgnored() {
    let usual = ["🎉", "🥹", "❤️"]
    for text: String? in [nil, "", "hello سلام 123 #tag * © ™", "text ❤︎ ☀︎", "\u{FE0F} \u{1F3FD}"] {
      #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: text, among: usual) == usual)
    }
  }

  @Test("emoji presentation symbols and bare hearts are recognized")
  func emojiSymbols() {
    #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: "©️ ™️ ❤ ❤️ ☀️", among: []) == ["©️", "™️", "❤", "❤️", "☀️"])
  }

  @Test("message suggestions obey the picker limit")
  func messageSuggestionLimits() {
    #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: "🎉🔥❤️", among: ["🥹"], limit: 2) == ["🎉", "🔥"])
    #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: "🎉", among: ["🥹"], limit: 0).isEmpty)
    #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: "🎉", among: ["🥹"], limit: -1).isEmpty)
  }

  @Test("showing contextual suggestions does not change learned usage")
  func messageSuggestionsDoNotRecordUsage() {
    let suiteName = "ReactionPickerEmojisTests.\(UUID().uuidString)"
    let defaults = makeUserDefaults(suiteName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ReactionPickerEmojiUsageStore.recordPick("🧠", userDefaults: defaults)
    let usual = ReactionPickerEmojiUsageStore.suggestedEmojis(userDefaults: defaults)
    let result = ReactionPickerEmojis.prioritizingMessageEmojis(in: "🎉", among: usual)
    #expect(result.first == "🎉")
    #expect(ReactionPickerEmojiUsageStore.usageCounts(userDefaults: defaults) == ["🧠": 1])
    #expect(ReactionPickerEmojiUsageStore.suggestedEmojis(userDefaults: defaults) == usual)
  }

  @Test("reopening after an edit recomputes suggestions without leaking the previous message")
  func editedAndDifferentMessages() {
    let usual = ["🧠", "🥹", "❤️"]
    for (text, expected) in [("first 🎉", ["🎉", "🧠", "🥹", "❤️"]),
                             ("edited 🔥", ["🔥", "🧠", "🥹", "❤️"]),
                             ("no emoji", usual), ("سلام ❤️ 🚀 ❤️", ["❤️", "🚀", "🧠", "🥹"])] {
      #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: text, among: usual) == expected)
    }
  }

  @Test("long messages and repeated emojis stay bounded")
  func longMessages() {
    let text = String(repeating: "سلام hello 123 ", count: 10_000) + String(repeating: "🎉", count: 10_000) + "🔥"
    #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: text, among: ["🥹"], limit: 3) == ["🎉", "🔥", "🥹"])
    let many = "😀😃😄😁😆😅😂🤣🥲🥹😊😇🙂🙃😉😌"
    #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: many, among: ["🔥"]) == many.prefix(15).map(String.init))
  }

  @Test("all orderings preserve first occurrence and deduplicate the fallback")
  func orderingCombinations() {
    let emojis = ["🎉", "🔥", "❤️", "👍🏽", "👩🏾‍💻", "🇮🇷", "1️⃣"]
    for first in emojis {
      for second in emojis {
        let text = "\(first) text \(second) \(first)"
        var expected = [first]
        if first != second { expected.append(second) }
        for emoji in emojis where !expected.contains(emoji) { expected.append(emoji) }
        for limit in [1, 3, 7, 15] {
          #expect(ReactionPickerEmojis.prioritizingMessageEmojis(in: text, among: emojis, limit: limit)
            == Array(expected.prefix(limit)))
        }
      }
    }
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
