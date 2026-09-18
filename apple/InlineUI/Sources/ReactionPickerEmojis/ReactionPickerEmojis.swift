import Foundation

public enum ReactionPickerEmojis {
  public static let defaultEmojis: [String] = [
    "🥹",
    "❤️",
    "🫡",
    "👍",
    "👎",
    "💯",
    "😂",
    "🎉",
    "🔥",
    "👏",
    "🙏",
    "🤔",
    "😮",
    "😢",
    "😡",
  ]

  public static var defaultLimit: Int {
    defaultEmojis.count
  }

  /// Message emojis retain their original grapheme (including skin tone).
  /// Pass the usual suggestions after applying the user's skin tone preference.
  public static func prioritizingMessageEmojis(
    in messageText: String?,
    among suggestions: [String],
    limit: Int = defaultLimit
  ) -> [String] {
    guard limit > 0 else { return [] }
    var result: [String] = []

    for character in messageText ?? "" where isMessageEmoji(character) {
      append(String(character), to: &result, limit: limit)
      if result.count == limit { return result }
    }

    for emoji in suggestions {
      append(emoji, to: &result, limit: limit)
      if result.count == limit { break }
    }
    return result
  }

  private static func isMessageEmoji(_ character: Character) -> Bool {
    let scalars = character.unicodeScalars
    guard let first = scalars.first,
          first.properties.isEmoji,
          !first.properties.isEmojiModifier,
          !scalars.contains(where: { $0.value == 0xFE0E }) else { return false }

    // Digits, # and * have the Unicode emoji property, but are only emojis
    // when combined with the enclosing keycap. Keep joined sequences intact.
    if first.value < 0x80 {
      return scalars.contains { $0.value == 0x20E3 }
    }
    return first.properties.isEmojiPresentation || first.value > 0x238C
      || scalars.contains { $0.value == 0xFE0F }
  }

  public static func normalizedEmoji(from value: String?) -> String? {
    guard let value else { return nil }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let firstCharacter = trimmed.first else { return nil }

    return String(firstCharacter)
  }

  public static func suggestions(from counts: [String: Int], limit: Int? = nil) -> [String] {
    let limit = max(0, limit ?? defaultLimit)
    guard limit > 0 else { return [] }

    let normalizedCounts = normalizedPositiveCounts(from: counts)
    let rankedEmojis = normalizedCounts
      .map { emoji, count in
        RankedEmoji(
          emoji: emoji,
          count: count,
          defaultIndex: defaultIndexByEmoji[emoji]
        )
      }
      .sorted(by: rankedEmojiSort)
      .map(\.emoji)

    var result: [String] = []
    result.reserveCapacity(min(limit, defaultLimit))

    for emoji in rankedEmojis {
      append(emoji, to: &result, limit: limit)
    }

    for emoji in defaultEmojis {
      append(emoji, to: &result, limit: limit)
    }

    return result
  }

  private static let legacyAcknowledgementEmojis: Set<String> = ["✓", "✔", "✔️"]

  private static let defaultIndexByEmoji: [String: Int] = Dictionary(
    uniqueKeysWithValues: defaultEmojis.enumerated().map { index, emoji in
      (emoji, index)
    }
  )

  private static func normalizedPositiveCounts(from counts: [String: Int]) -> [String: Int] {
    var normalizedCounts: [String: Int] = [:]

    for (emoji, count) in counts where count > 0 {
      guard let normalizedEmoji = normalizedEmoji(from: emoji),
            !legacyAcknowledgementEmojis.contains(normalizedEmoji) else { continue }
      normalizedCounts[normalizedEmoji, default: 0] += count
    }

    return normalizedCounts
  }

  private static func append(_ emoji: String, to result: inout [String], limit: Int) {
    guard result.count < limit, !result.contains(emoji) else { return }
    result.append(emoji)
  }

  private static func rankedEmojiSort(lhs: RankedEmoji, rhs: RankedEmoji) -> Bool {
    if lhs.count != rhs.count {
      return lhs.count > rhs.count
    }

    switch (lhs.defaultIndex, rhs.defaultIndex) {
    case let (lhsIndex?, rhsIndex?):
      return lhsIndex < rhsIndex
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    case (nil, nil):
      return lhs.emoji < rhs.emoji
    }
  }

  private struct RankedEmoji {
    let emoji: String
    let count: Int
    let defaultIndex: Int?
  }
}

public enum ReactionPickerEmojiUsageStore {
  private static let countsKey = "chat.inline.reactionPicker.emojiUsageCounts.v1"

  public static func suggestedEmojis(
    limit: Int? = nil,
    userDefaults: UserDefaults = .standard
  ) -> [String] {
    ReactionPickerEmojis.suggestions(
      from: usageCounts(userDefaults: userDefaults),
      limit: limit
    )
  }

  public static func usageCounts(userDefaults: UserDefaults = .standard) -> [String: Int] {
    guard let rawCounts = userDefaults.dictionary(forKey: countsKey) else { return [:] }

    var counts: [String: Int] = [:]
    for (emoji, rawCount) in rawCounts {
      let count: Int?
      switch rawCount {
      case let value as Int:
        count = value
      case let value as NSNumber:
        count = value.intValue
      default:
        count = nil
      }

      guard let count, count > 0, let normalizedEmoji = ReactionPickerEmojis.normalizedEmoji(from: emoji) else {
        continue
      }

      counts[normalizedEmoji, default: 0] += count
    }

    return counts
  }

  public static func usageCount(for emoji: String, userDefaults: UserDefaults = .standard) -> Int {
    guard let normalizedEmoji = ReactionPickerEmojis.normalizedEmoji(from: emoji) else { return 0 }
    return usageCounts(userDefaults: userDefaults)[normalizedEmoji, default: 0]
  }

  public static func recordPick(_ emoji: String, userDefaults: UserDefaults = .standard) {
    guard let normalizedEmoji = ReactionPickerEmojis.normalizedEmoji(from: emoji) else { return }

    var counts = usageCounts(userDefaults: userDefaults)
    counts[normalizedEmoji, default: 0] += 1
    save(counts, userDefaults: userDefaults)
  }

  public static func removeSuggestion(_ emoji: String, userDefaults: UserDefaults = .standard) {
    guard let normalizedEmoji = ReactionPickerEmojis.normalizedEmoji(from: emoji) else { return }

    var counts = usageCounts(userDefaults: userDefaults)
    counts[normalizedEmoji] = nil
    save(counts, userDefaults: userDefaults)
  }

  private static func save(_ counts: [String: Int], userDefaults: UserDefaults) {
    let positiveCounts = counts.filter { _, count in count > 0 }
    userDefaults.set(positiveCounts, forKey: countsKey)
  }
}
