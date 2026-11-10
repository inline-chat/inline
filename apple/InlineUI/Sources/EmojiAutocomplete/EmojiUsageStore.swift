import Foundation

/// Local emoji frecency shared by compose autocomplete, the emoji pickers, and reactions.
/// Keys drop skin tones so the preferred tone is applied at display time.
public enum EmojiUsageStore {
  public static let key = "chat.inline.emojiUsage.v1"
  /// Reaction picks recorded before this store existed seed it once.
  static let legacyReactionCountsKey = "chat.inline.reactionPicker.emojiUsageCounts.v1"
  static let maxEntries = 160
  private static let halfLifeDays = 10.0

  public static func record(_ emoji: String, date: Date = Date(), userDefaults: UserDefaults = .standard) {
    let usageKey = EmojiUsageKey.make(emoji.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !usageKey.isEmpty else { return }

    var entries = load(userDefaults: userDefaults, now: date)
    let previous = entries[usageKey] ?? Entry(count: 0, lastUsed: date.timeIntervalSince1970)
    entries[usageKey] = Entry(count: previous.count + 1, lastUsed: date.timeIntervalSince1970)

    if entries.count > maxEntries {
      let now = date.timeIntervalSince1970
      let kept = entries
        .sorted { $0.value.score(now: now, halfLifeDays: halfLifeDays) > $1.value.score(now: now, halfLifeDays: halfLifeDays) }
        .prefix(maxEntries)
      entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    save(entries, userDefaults: userDefaults)
  }

  public static func snapshot(now: Date = Date(), userDefaults: UserDefaults = .standard) -> EmojiUsageSnapshot {
    let timestamp = now.timeIntervalSince1970
    let scores = load(userDefaults: userDefaults, now: now).mapValues { $0.score(now: timestamp, halfLifeDays: halfLifeDays) }
    return EmojiUsageSnapshot(scores: scores)
  }

  /// Most-used first. Returned emoji have no skin tone; apply the preferred one before display.
  public static func frequentlyUsed(
    limit: Int,
    now: Date = Date(),
    userDefaults: UserDefaults = .standard
  ) -> [String] {
    guard limit > 0 else { return [] }
    let timestamp = now.timeIntervalSince1970
    return load(userDefaults: userDefaults, now: now)
      .map { (emoji: $0.key, score: $0.value.score(now: timestamp, halfLifeDays: halfLifeDays)) }
      .sorted { $0.score != $1.score ? $0.score > $1.score : $0.emoji < $1.emoji }
      .prefix(limit)
      .map { EmojiAutocomplete.suggestion(forEmoji: $0.emoji)?.emoji ?? $0.emoji }
  }

  public static func remove(_ emoji: String, userDefaults: UserDefaults = .standard) {
    var entries = load(userDefaults: userDefaults, now: Date())
    entries[EmojiUsageKey.make(emoji)] = nil
    save(entries, userDefaults: userDefaults)
  }

  // MARK: Storage

  struct Entry: Equatable {
    var count: Double
    var lastUsed: TimeInterval

    /// Count decayed by age so a burst last month yields to steady use this week.
    func score(now: TimeInterval, halfLifeDays: Double) -> Double {
      let ageDays = max(0, now - lastUsed) / 86_400
      return count * pow(0.5, ageDays / halfLifeDays) + min(count, 20) * 0.05
    }
  }

  private static func load(userDefaults: UserDefaults, now: Date) -> [String: Entry] {
    guard let raw = userDefaults.dictionary(forKey: key) else {
      let seeded = seedFromReactionCounts(userDefaults: userDefaults, now: now)
      save(seeded, userDefaults: userDefaults)
      return seeded
    }

    var entries: [String: Entry] = [:]
    for (emoji, value) in raw {
      guard let pair = value as? [NSNumber], pair.count == 2, pair[0].doubleValue > 0 else { continue }
      entries[emoji] = Entry(count: pair[0].doubleValue, lastUsed: pair[1].doubleValue)
    }
    return entries
  }

  private static func save(_ entries: [String: Entry], userDefaults: UserDefaults) {
    userDefaults.set(entries.mapValues { [$0.count, $0.lastUsed] }, forKey: key)
  }

  private static func seedFromReactionCounts(userDefaults: UserDefaults, now: Date) -> [String: Entry] {
    guard let raw = userDefaults.dictionary(forKey: legacyReactionCountsKey) else { return [:] }
    let lastUsed = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
    var entries: [String: Entry] = [:]
    for (emoji, value) in raw {
      guard let count = (value as? NSNumber)?.doubleValue, count > 0 else { continue }
      let usageKey = EmojiUsageKey.make(emoji)
      guard !usageKey.isEmpty else { continue }
      entries[usageKey, default: Entry(count: 0, lastUsed: lastUsed)].count += count
    }
    return entries
  }
}
