import Foundation

public struct EmojiAutocompleteSuggestion: Hashable, Identifiable, Sendable {
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

// MARK: - Index

struct EmojiAutocompleteEntry: Sendable {
  let emoji: String
  let shortcode: String
  let label: String
  let isSkinToneVariant: Bool
  let usageKey: String
  let terms: [EmojiAutocompleteTerm]
  let words: [EmojiAutocompleteWord]
  let popularityBoost: Double
}

struct EmojiAutocompleteTerm: Sendable {
  enum Kind: Int, Sendable {
    case shortcode
    case alias
    case keyword
  }

  let value: [UInt8]
  /// `value` without underscores, so "face_palm" and "facepalm" meet.
  let compact: [UInt8]
  let kind: Kind
}

struct EmojiAutocompleteWord: Sendable {
  let value: [UInt8]
  /// The strongest term kind the word appears in; shortcode and alias words beat CLDR keyword words.
  let kind: EmojiAutocompleteTerm.Kind

  var isStrong: Bool { kind != .keyword }
}

enum EmojiAutocompleteData {}

extension EmojiAutocompleteData {
  static let entries: [EmojiAutocompleteEntry] = parseEntries()
  static let index = EmojiAutocompleteIndex(entries: entries)

  private static func parseEntries() -> [EmojiAutocompleteEntry] {
    let popularity = EmojiAutocompletePopularity.boostByUsageKey

    return rawEntries.split(separator: "\n").map { line in
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
      precondition(parts.count == 3 || parts.count == 4, "Invalid emoji autocomplete row: \(line)")
      let emoji = String(parts[0])
      let label = String(parts[2])
      let shortcode = EmojiAutocompleteAliases.shortcodeOverride(emoji: emoji, shortcode: String(parts[1]), label: label)
      let aliases = EmojiAutocompleteAliases.keywordsByShortcode[shortcode] ?? []
      let keywords = parts.count == 4 ? parts[3].split(separator: ",").map(String.init) : []
      let terms = makeTerms(shortcode: shortcode, aliases: aliases, keywords: keywords)
      let usageKey = EmojiUsageKey.make(emoji)

      return EmojiAutocompleteEntry(
        emoji: emoji,
        shortcode: shortcode,
        label: label,
        isSkinToneVariant: EmojiUsageKey.containsSkinToneModifier(emoji),
        usageKey: usageKey,
        terms: terms,
        words: makeWords(terms: terms),
        popularityBoost: popularity[usageKey] ?? 0
      )
    }
  }

  private static func makeTerms(shortcode: String, aliases: [String], keywords: [String]) -> [EmojiAutocompleteTerm] {
    var result: [EmojiAutocompleteTerm] = []
    var seen = Set<String>()

    func add(_ value: String, kind: EmojiAutocompleteTerm.Kind) {
      let normalized = EmojiAutocomplete.normalize(value)
      // A stronger kind wins when the same text appears twice.
      guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
      let bytes = Array(normalized.utf8)
      result.append(EmojiAutocompleteTerm(value: bytes, compact: bytes.filter { $0 != underscore }, kind: kind))
    }

    add(shortcode, kind: .shortcode)
    aliases.forEach { add($0, kind: .alias) }
    keywords.forEach { add($0, kind: .keyword) }

    return result
  }

  private static func makeWords(terms: [EmojiAutocompleteTerm]) -> [EmojiAutocompleteWord] {
    var kinds: [[UInt8]: EmojiAutocompleteTerm.Kind] = [:]
    var order: [[UInt8]] = []

    for term in terms {
      for word in term.value.split(separator: underscore).map(Array.init) where !word.isEmpty {
        if let existing = kinds[word] {
          if term.kind.rawValue < existing.rawValue { kinds[word] = term.kind }
        } else {
          kinds[word] = term.kind
          order.append(word)
        }
      }
    }

    return order.map { EmojiAutocompleteWord(value: $0, kind: kinds[$0] ?? .keyword) }
  }
}

private let underscore = UInt8(ascii: "_")

struct EmojiAutocompleteIndex: Sendable {
  /// Base entries (no skin tone variants) keyed by the first byte of any term or word.
  private let candidatesByFirstByte: [[Int]]
  let baseEntryIndexes: [Int]

  init(entries: [EmojiAutocompleteEntry]) {
    var buckets = Array(repeating: [Int](), count: 256)
    var base: [Int] = []

    for (index, entry) in entries.enumerated() where !entry.isSkinToneVariant {
      base.append(index)
      var seen = Set<UInt8>()
      for term in entry.terms {
        if let first = term.value.first, seen.insert(first).inserted { buckets[Int(first)].append(index) }
      }
      for word in entry.words {
        if let first = word.value.first, seen.insert(first).inserted { buckets[Int(first)].append(index) }
      }
    }

    candidatesByFirstByte = buckets
    baseEntryIndexes = base
  }

  func candidates(firstByte: UInt8) -> [Int] {
    candidatesByFirstByte[Int(firstByte)]
  }
}

// MARK: - Search

/// Personal usage, keyed by `EmojiUsageKey`. Higher scores rank earlier.
public struct EmojiUsageSnapshot: Sendable {
  public static let empty = EmojiUsageSnapshot(scores: [:])

  let scores: [String: Double]

  public init(scores: [String: Double]) {
    self.scores = scores
  }

  public func score(for emoji: String) -> Double {
    scores[EmojiUsageKey.make(emoji)] ?? 0
  }

  func boost(forKey key: String) -> Double {
    guard let score = scores[key], score > 0 else { return 0 }
    return min(Scoring.maxUsageBoost, 3 * log2(1 + score))
  }
}

private enum Scoring {
  static let exactShortcode = 0.0
  static let exactAlias = 3.0
  static let exactStrongWord = 10.0
  static let exactKeyword = 14.0
  static let shortcodePrefix = 18.0
  static let aliasPrefix = 20.0
  static let strongWordPrefix = 23.0
  static let multiWord = 24.0
  static let keywordPrefix = 27.0
  static let compactPrefix = 28.0
  static let fuzzy = 38.0
  static let substring = 40.0

  static let maxUsageBoost = 7.0

  /// Prefers the tighter completion: "hea" ranks "heart" above "headphone".
  static func tightness(extra: Int) -> Double {
    min(6, Double(max(0, extra)) * 0.35)
  }

  static func exact(_ kind: EmojiAutocompleteTerm.Kind) -> Double {
    switch kind {
    case .shortcode: exactShortcode
    case .alias: exactAlias
    case .keyword: exactKeyword
    }
  }

  static func prefix(_ kind: EmojiAutocompleteTerm.Kind) -> Double {
    switch kind {
    case .shortcode: shortcodePrefix
    case .alias: aliasPrefix
    case .keyword: keywordPrefix
    }
  }
}

private struct EmojiAutocompleteQuery {
  let bytes: [UInt8]
  let compact: [UInt8]
  let tokens: [[UInt8]]

  init?(_ raw: String) {
    let normalized = EmojiAutocomplete.normalize(raw)
    guard !normalized.isEmpty else { return nil }
    bytes = Array(normalized.utf8)
    compact = bytes.filter { $0 != underscore }
    tokens = bytes.split(separator: underscore).map(Array.init).filter { !$0.isEmpty }
  }

  var length: Int { compact.count }
  var isMultiWord: Bool { tokens.count > 1 }
}

public enum EmojiAutocomplete {
  /// Every row in the dataset, including skin tone variants, in Unicode order.
  public static let allSuggestions: [EmojiAutocompleteSuggestion] = EmojiAutocompleteData.entries.map { entry in
    EmojiAutocompleteSuggestion(emoji: entry.emoji, shortcode: entry.shortcode, label: entry.label)
  }

  /// Dataset metadata for an emoji, ignoring skin tone and presentation selectors.
  public static func suggestion(forEmoji emoji: String) -> EmojiAutocompleteSuggestion? {
    guard let index = entryIndexByUsageKey[EmojiUsageKey.make(emoji)] else { return nil }
    let entry = EmojiAutocompleteData.entries[index]
    return EmojiAutocompleteSuggestion(emoji: entry.emoji, shortcode: entry.shortcode, label: entry.label)
  }

  private static let entryIndexByUsageKey: [String: Int] = {
    var result: [String: Int] = [:]
    for index in EmojiAutocompleteData.index.baseEntryIndexes {
      let key = EmojiAutocompleteData.entries[index].usageKey
      if result[key] == nil { result[key] = index }
    }
    return result
  }()

  /// Searches base emoji (no skin tone variants); apply the preferred tone when displaying.
  ///
  /// Ranking: exact shortcode, alias, then word and prefix matches, multi-word, substring,
  /// and finally one-typo matches. Popular emoji and the user's own usage lift results
  /// within and across neighboring tiers, never above an exact shortcode match of another emoji.
  public static func suggestions(
    matching query: String,
    limit: Int = 8,
    usage: EmojiUsageSnapshot = .empty
  ) -> [EmojiAutocompleteSuggestion] {
    guard limit > 0, let query = EmojiAutocompleteQuery(query) else { return [] }

    let entries = EmojiAutocompleteData.entries
    let index = EmojiAutocompleteData.index
    var scored: [(score: Double, entry: Int)] = []
    var matched = Set<Int>()

    func append(_ entryIndex: Int, _ tier: Double) {
      let entry = entries[entryIndex]
      let score = tier - entry.popularityBoost - usage.boost(forKey: entry.usageKey)
      scored.append((score, entryIndex))
      matched.insert(entryIndex)
    }

    let firstByte = query.compact.first ?? query.bytes[0]
    let candidates = index.candidates(firstByte: firstByte)

    for entryIndex in candidates {
      if let tier = strictTier(entries[entryIndex], query: query) {
        append(entryIndex, tier)
      }
    }

    // Weak tiers only fill in when the strict ones come up thin; otherwise they add noise
    // ("clap" → "crap", "done" → "indonesia"). They never depend on `limit`, so a short
    // list and a long list rank the same way.
    let strictCount = matched.count

    if query.length >= 4, strictCount < 3 {
      for entryIndex in candidates where !matched.contains(entryIndex) {
        if let tier = fuzzyTier(entries[entryIndex], query: query) {
          append(entryIndex, tier)
        }
      }
    }

    if query.length >= 4, strictCount < 5 {
      for entryIndex in index.baseEntryIndexes where !matched.contains(entryIndex) {
        if containsSubstring(entries[entryIndex], query: query) {
          append(entryIndex, Scoring.substring)
        }
      }
    }

    return scored
      .sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        let lhsLength = entries[lhs.entry].shortcode.utf8.count
        let rhsLength = entries[rhs.entry].shortcode.utf8.count
        if lhsLength != rhsLength { return lhsLength < rhsLength }
        return lhs.entry < rhs.entry
      }
      .prefix(limit)
      .map { item in
        let entry = entries[item.entry]
        return EmojiAutocompleteSuggestion(emoji: entry.emoji, shortcode: entry.shortcode, label: entry.label)
      }
  }

  static func normalize(_ value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    var result = ""
    var previousWasSeparator = false

    let scalars = Array(folded.lowercased().unicodeScalars)
    for (index, scalar) in scalars.enumerated() {
      let isSignedNumber = (scalar == "+" || scalar == "-")
        && (result.isEmpty || previousWasSeparator)
        && (index + 1 == scalars.count || CharacterSet.decimalDigits.contains(scalars[index + 1]))
      if CharacterSet.alphanumerics.contains(scalar) || isSignedNumber {
        result.unicodeScalars.append(scalar)
        previousWasSeparator = false
      } else if scalar == "_" || scalar == " " || scalar == "-" || scalar == ":" || scalar == "." {
        guard !result.isEmpty, !previousWasSeparator else { continue }
        result.append("_")
        previousWasSeparator = true
      }
    }

    return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
  }

  // MARK: Tiers

  private static func strictTier(_ entry: EmojiAutocompleteEntry, query: EmojiAutocompleteQuery) -> Double? {
    let q = query.bytes
    let length = query.length
    var best = Double.infinity

    for term in entry.terms {
      if term.value == q {
        // Single characters are too noisy to match CLDR keywords ("o", "x").
        if length == 1, term.kind == .keyword { continue }
        best = min(best, Scoring.exact(term.kind))
        continue
      }
      guard length >= 2 else { continue }

      if term.value.starts(with: q) {
        // Two letters are ambiguous; only complete shortcodes ("he" → heart, not "hehe" → joy).
        if length == 2, term.kind != .shortcode { continue }
        best = min(best, Scoring.prefix(term.kind) + Scoring.tightness(extra: term.value.count - q.count))
      } else if length >= 3, term.compact.starts(with: query.compact) {
        let tier = term.compact.count == query.compact.count ? Scoring.exact(term.kind) + 1 : Scoring.compactPrefix
        best = min(best, tier + Scoring.tightness(extra: term.compact.count - query.compact.count))
      }
    }

    if length >= 2, !query.isMultiWord {
      for word in entry.words {
        if word.value == q {
          best = min(best, word.isStrong ? Scoring.exactStrongWord : Scoring.exactKeyword)
        } else if word.value.starts(with: q), length >= 3 || word.kind == .shortcode {
          let tier = word.isStrong ? Scoring.strongWordPrefix : Scoring.keywordPrefix
          best = min(best, tier + Scoring.tightness(extra: word.value.count - q.count))
        }
      }
    }

    if query.isMultiWord, let tier = multiWordTier(entry, tokens: query.tokens) {
      best = min(best, tier)
    }

    return best.isFinite ? best : nil
  }

  /// Every token must start a distinct word, in any order: "heart red", "cat smile".
  private static func multiWordTier(_ entry: EmojiAutocompleteEntry, tokens: [[UInt8]]) -> Double? {
    var used = Set<Int>()
    var penalty = 0.0

    for token in tokens {
      var bestWord: (index: Int, penalty: Double)?
      for (index, word) in entry.words.enumerated() where !used.contains(index) {
        guard word.value.starts(with: token) else { continue }
        var wordPenalty = word.value.count == token.count ? 0 : 1.5
        if !word.isStrong { wordPenalty += 1 }
        if bestWord == nil || wordPenalty < bestWord!.penalty {
          bestWord = (index, wordPenalty)
        }
      }
      guard let bestWord else { return nil }
      used.insert(bestWord.index)
      penalty += bestWord.penalty
    }

    return Scoring.multiWord + penalty
  }

  private static func containsSubstring(_ entry: EmojiAutocompleteEntry, query: EmojiAutocompleteQuery) -> Bool {
    guard let shortcode = entry.terms.first, shortcode.kind == .shortcode else { return false }
    return contains(shortcode.compact, query.compact)
  }

  private static func fuzzyTier(_ entry: EmojiAutocompleteEntry, query: EmojiAutocompleteQuery) -> Double? {
    let q = query.compact
    // In four-letter words a changed or extra letter is usually a different word
    // ("pray" → "play", "hash" → "haha"); only a missing or swapped letter counts.
    let allowsSubstitution = q.count >= 5
    var best = Double.infinity

    func consider(_ value: [UInt8]) {
      guard value.first == q.first,
            prefixWithinOneEdit(query: q, of: value, allowsSubstitution: allowsSubstitution)
      else { return }
      best = min(best, Scoring.fuzzy + Scoring.tightness(extra: value.count - q.count))
    }

    for term in entry.terms where term.kind != .keyword {
      consider(term.compact)
    }
    for word in entry.words where word.isStrong {
      consider(word.value)
    }

    return best.isFinite ? best : nil
  }

  /// True when `query` is one insertion, deletion, substitution, or adjacent swap away
  /// from some prefix of `value`.
  private static func prefixWithinOneEdit(query: [UInt8], of value: [UInt8], allowsSubstitution: Bool) -> Bool {
    let lengths = allowsSubstitution ? [query.count, query.count + 1, query.count - 1] : [query.count, query.count + 1]
    for length in lengths where length > 0 && length <= value.count {
      if withinOneEdit(query, value[0 ..< length], allowsSubstitution: allowsSubstitution) { return true }
    }
    return false
  }

  private static func withinOneEdit(_ a: [UInt8], _ b: ArraySlice<UInt8>, allowsSubstitution: Bool) -> Bool {
    let b = Array(b)
    if a.count == b.count {
      var mismatches: [Int] = []
      for i in 0 ..< a.count where a[i] != b[i] {
        mismatches.append(i)
        if mismatches.count > 2 { return false }
      }
      if mismatches.isEmpty { return true }
      if mismatches.count == 1 { return allowsSubstitution }
      let (i, j) = (mismatches[0], mismatches[1])
      return j == i + 1 && a[i] == b[j] && a[j] == b[i]
    }

    let (longer, shorter) = a.count > b.count ? (a, b) : (b, a)
    guard longer.count - shorter.count == 1 else { return false }
    var i = 0
    var j = 0
    var skipped = false
    while i < longer.count, j < shorter.count {
      if longer[i] == shorter[j] {
        i += 1
        j += 1
      } else {
        if skipped { return false }
        skipped = true
        i += 1
      }
    }
    return true
  }

  private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let first = needle[0]
    for start in 0 ... haystack.count - needle.count where haystack[start] == first {
      if haystack[start ..< start + needle.count].elementsEqual(needle) { return true }
    }
    return false
  }
}

// MARK: - Usage keys

public enum EmojiUsageKey {
  /// Strips skin tone modifiers and presentation selectors so 👍🏽 and 👍 share one key.
  public static func make(_ emoji: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in emoji.unicodeScalars where !isSkinToneModifier(scalar.value) && scalar.value != 0xFE0F {
      scalars.append(scalar)
    }
    return String(scalars)
  }

  public static func containsSkinToneModifier(_ emoji: String) -> Bool {
    emoji.unicodeScalars.contains { isSkinToneModifier($0.value) }
  }

  static func isSkinToneModifier(_ value: UInt32) -> Bool {
    (0x1F3FB ... 0x1F3FF).contains(value)
  }
}
